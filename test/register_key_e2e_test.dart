import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ubuntu_core_model_builder/services/ffi/snapstore_auth_client.dart';
import 'package:ubuntu_core_model_builder/services/rust_key_service.dart';
import 'package:ubuntu_core_model_builder/services/rust_store_service.dart';
import 'support/mock_store_path.dart';

/// End-to-end tests for the signing-key registration path against the REAL
/// host toolchain: a real GPG key in the snap keyring (~/.snap/gnupg), the
/// real `snap export-key` (snapd), and the real Rust FFI client
/// (libsnapstore_auth) talking to a local mock store on port 8474.
///
/// Covers the "recover from expired macaroon on key registration" fix:
///   * a healthy store accepts the exported assertion (registerKey succeeds
///     and the store records it);
///   * a store that no longer honours the session's macaroon (401 on the
///     authenticated endpoints) makes `registerKey` throw
///     [KeyAuthExpiredException] — NOT a raw `SnapstoreAuthError` and NOT
///     a generic `KeyException` — at whichever call hits the 401 first.
///
/// Follows the house pattern of the other Rust-backed tests: skips when the
/// native library or the host toolchain (gpg/snapd) is unavailable.
///
/// Isolation: mock port 8474 (8471 = rust_backend_e2e, 8472 =
/// rust_login_ui, 8473 = rust_login_ui_no2fa); this file runs in its own
/// process, so the Rust session singleton is private to it. One throwaway
/// key is generated for the whole file and deleted afterwards.
const _mockStore = 'http://127.0.0.1:8474';
const _password = 's3cret';
const _code = '654321';

/// 0 when a working `gpg` is on PATH, non-zero otherwise.
Future<int> _gpgAvailable() async {
  try {
    return (await Process.run('gpg', ['--version'])).exitCode;
  } on ProcessException {
    return 127;
  }
}

void main() {
  late Process mock;
  late SnapstoreAuthSession session;
  late RustKeyService svc;

  String keyName = '';
  String keyFpr = '';

  /// Creates a throwaway passphrase-less key in the snap keyring
  /// (`gpg --gen-key` in `~/.snap/gnupg` — the same invocation
  /// GpgKeyGenerator uses, minus the pinentry prompt) and records its
  /// fingerprint.
  Future<void> generateKey() async {
    final home = Platform.environment['HOME'];
    if (home == null) throw StateError('HOME not set');
    keyName =
        'mbtest-reg-${DateTime.now().millisecondsSinceEpoch}';
    final params = '%no-protection\n'
        'Key-Type: RSA\n'
        'Key-Length: 4096\n'
        'Name-Real: $keyName\n'
        'Preferences: SHA512\n';
    final gpg = await Process.start('gpg', [
      '--homedir',
      '$home/.snap/gnupg',
      '-q',
      '--no-auto-check-trustdb',
      '--batch',
      '--gen-key',
    ]);
    gpg.stdout.drain<void>();
    final errFut =
        gpg.stderr.transform(const Utf8Decoder(allowMalformed: true)).join();
    gpg.stdin.add(utf8.encode(params));
    await gpg.stdin.close();
    final rc = await gpg.exitCode.timeout(const Duration(seconds: 120));
    if (rc != 0) {
      // Surface gpg's own diagnostic — without it a builder-environment
      // failure (gpg-agent, /run/user, stale keyring) is undiagnosable.
      throw StateError('gpg --gen-key failed (rc=$rc) — '
          'stderr: ${(await errFut).trim()}; is gpg available?');
    }

    // `gpg --list-secret-keys --with-colons --fixed-list-mode` emits, per
    // key: `sec`, then `fpr`/`grp`, then `uid` lines. Find the fpr that
    // precedes the uid matching the freshly created key name.
    final list = await Process.run(
      'gpg',
      [
        '--homedir',
        '$home/.snap/gnupg',
        '--batch',
        '--list-secret-keys',
        '--fingerprint',
        '--with-colons',
        '--fixed-list-mode',
      ],
    );
    String? fpr;
    for (final line in (list.stdout as String).split('\n')) {
      final c = line.indexOf(':');
      if (c < 0) continue;
      final type = line.substring(0, c);
      final f = line.substring(c + 1).split(':');
      if (type == 'sec') {
        fpr = null; // a new key block starts
      } else if (type == 'fpr' && fpr == null) {
        fpr = f.firstWhere((x) => x.isNotEmpty, orElse: () => '');
      } else if (type == 'uid' && f.length > 8 && f[8] == keyName) {
        if (fpr == null || fpr.isEmpty) {
          throw StateError(
              'key $keyName has no fingerprint in the keyring');
        }
        keyFpr = fpr;
        return;
      }
    }
    throw StateError('key $keyName not found in the keyring after gen-key');
  }

  Future<void> deleteKey() async {
    if (keyFpr.isEmpty) return;
    final home = Platform.environment['HOME']!;
    await Process.run('gpg', [
      '--homedir',
      '$home/.snap/gnupg',
      '--batch',
      '--yes',
      '--pinentry-mode',
      'loopback',
      '--delete-secret-and-public-key',
      '0x$keyFpr',
    ]);
  }

  Future<AuthState> login() => session.login(
        promptCredentials: () async {
          session.auth.submitCredentials('user@example.com', _password);
          await _waitStates(session,
              const {AuthState.needs2faCode, AuthState.idle},
              const Duration(seconds: 15));
          return session.auth.state != AuthState.idle;
        },
        promptTwoFactor: () async {
          session.auth.submit2faCode(_code);
          await _waitStates(session,
              const {AuthState.succeeded, AuthState.idle},
              const Duration(seconds: 15));
          return session.auth.state == AuthState.succeeded;
        },
      );

  /// Flips the mock's "macaroon no longer honoured" mode.
  Future<void> setRejectMacaroon(bool on) async {
    final client = HttpClient();
    try {
      final req = await client.postUrl(Uri.parse('$_mockStore/__reject'));
      final res = await req.close();
      final status = res.statusCode;
      await res.drain<void>();
      if (status != 200) {
        throw StateError('mock /__reject returned $status');
      }
    } finally {
      client.close(force: true);
    }
  }

  /// The account-key assertions the mock has recorded so far.
  Future<List<String>> registeredAssertions() async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse('$_mockStore/__registered'));
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      final m = jsonDecode(body) as Map<String, Object?>;
      return ((m['keys'] as List?) ?? const []).cast<String>();
    } finally {
      client.close(force: true);
    }
  }

  setUpAll(() async {
    if (!SnapstoreAuthSession.isAvailable()) {
      print('SKIP: libsnapstore_auth not found '
          '(set SNAPSTORE_AUTH_LIB or run scripts/build_rust_backend.sh)');
      return;
    }
    if (await _gpgAvailable() != 0) {
      print('SKIP: gpg not available in this build environment');
      return;
    }
    mock = await Process.start('python3', [
      mockStorePath(),
      '--port',
      '8474',
      '--two-factor',
      '--password',
      _password,
      '--good-code',
      _code,
    ], workingDirectory: Directory.current.path);
    for (var i = 0; i < 50; i++) {
      try {
        final s = await Socket.connect('127.0.0.1', 8474,
            timeout: const Duration(milliseconds: 200));
        await s.close();
        break;
      } on SocketException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    session = await SnapstoreAuthSession.init(
      storeUrl: _mockStore,
      loginUrl: _mockStore,
      permissions: RustStoreService.loginAcls.join(','),
    );
    svc = RustKeyService();
    await generateKey();
  });

  tearDownAll(() async {
    await deleteKey();
    if (mock.pid != -1) mock.kill();
  });

  test('registerKey succeeds against a healthy store (real key, real '
      'snap export-key, Rust FFI upload)', () async {
    if (!SnapstoreAuthSession.isAvailable() || keyName.isEmpty) return;
    expect(await login(), AuthState.succeeded);
    try {
      await svc.registerKey(keyName);
      final registered = await registeredAssertions();
      expect(registered, isNotEmpty,
          reason: 'the mock store must have recorded the uploaded '
              'account-key assertion');
      expect(registered.last, contains('name: $keyName'));
      expect(registered.last, startsWith('type: account-key-request'));
    } finally {
      // Leave the session logged out so the next test starts from idle.
      await session.logout();
    }
  });

  test('registerKey throws KeyAuthExpiredException when the store rejects '
      'the session (expired macaroon)', () async {
    if (!SnapstoreAuthSession.isAvailable() || keyName.isEmpty) return;
    expect(await login(), AuthState.succeeded);
    // The session is healthy so far — now make the store stop honouring
    // its macaroon (401 "macaroon is expired" on every authenticated
    // call). The in-process state machine still reads `succeeded`.
    await setRejectMacaroon(true);
    addTearDown(() async {
      await setRejectMacaroon(false);
      final cur = SnapstoreAuthSession.current;
      if (cur != null && cur.auth.state == AuthState.succeeded) {
        await cur.logout();
      }
    });

    // The recovery path (KeysPage._runKeyOp) relies on this being the
    // typed exception — a raw SnapstoreAuthError or a generic
    // KeyException would surface as a dead-end error to the user.
    await expectLater(
      svc.registerKey(keyName),
      throwsA(isA<KeyAuthExpiredException>()),
    );
  });
}

Future<AuthState> _waitStates(
    SnapstoreAuthSession session, Set<AuthState> targets,
    Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final s = session.auth.state;
    if (targets.contains(s)) return s;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return session.auth.state;
}
