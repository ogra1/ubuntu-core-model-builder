// Rust-backed implementation of the KeyService interface.
//
// Drop-in replacement for `KeyService` (the `snap keys` / `snapcraft keys`
// / `snapcraft register-key` shell-out version):
//
//   * `listKeys()` — local GPG keyring (`snap keys`, unchanged: the
//     keyring is host-side) + registered fingerprints from the Rust store
//     client (`GET /dev/api/account` → `account_keys[]`), replacing
//     `snapcraft keys`;
//   * `registerKey()` / `createAndRegister()` — `snap export-key`
//     (host GPG keyring, unchanged) uploaded through the Rust `registerKey`
//     FFI (`POST /dev/api/account/account-key`), replacing
//     `snapcraft register-key` and its terminal;
//   * `createKey()` — drives `gpg --gen-key` directly (see
//     [GpgKeyGenerator]) instead of `snap create-key` (which reads the
//     passphrase from a terminal, hence its terminal window): the passphrase
//     is entered in the system pinentry dialog — the same popup `snap sign`
//     uses — and the key lands in the very keyring (~/.snap/gnupg) that
//     `snap keys` / `export-key` / `sign` use.
import 'dart:io';
import 'dart:isolate';

import 'package:process_run/process_run.dart';

import 'ffi/snapstore_auth_client.dart';
import 'gpg_key_generator.dart';
import '../models/signing_key.dart';
import 'host_env.dart';

class RustKeyService {
  /// Backs [createKey]/[createAndRegister]. Defaults to the real
  /// generator; injectable in tests.
  final GpgKeyGenerator keyGenerator;

  RustKeyService({GpgKeyGenerator? keyGenerator})
      : keyGenerator = keyGenerator ?? GpgKeyGenerator();

  /// Registered key SHA3-384 fingerprints from the store, via the Rust
  /// store client. Returns `null` (instead of throwing) when the app is
  /// not signed in — matching the old `snapcraft keys` failure mode, which
  /// callers treat as "no registered fingerprints known".
  Future<Set<String>?> listRegisteredFingerprints() async {
    final session = SnapstoreAuthSession.current;
    if (session == null) return null;
    if (session.auth.state != AuthState.succeeded) return null;
    try {
      // Blocking FFI + HTTP — run off the UI isolate.
      final raw = await Isolate.run(() => session.auth.accountInfoRaw());
      final keys = raw['account_keys'];
      if (keys is! List) return <String>{};
      final fps = <String>{};
      for (final Object? e in keys) {
        if (e is! Map) continue;
        final fp = e['public-key-sha3-384'];
        if (fp is String && fp.isNotEmpty) fps.add(fp);
      }
      return fps;
    } catch (_) {
      return null;
    }
  }

  /// Local keys in the GPG keyring, via `snap keys` (snap, not snapcraft).
  Future<List<SigningKey>> listLocalKeys() async {
    final shell = Shell(
      throwOnError: false,
      verbose: false,
      environment: HostEnv.sanitized,
      includeParentEnvironment: false,
    );
    final result = await shell.run('snap keys');
    if (result.first.exitCode != 0) return [];

    final text = result.outText;
    if (text.toLowerCase().contains('no keys')) return [];

    final lines = text.split('\n');
    final keys = <SigningKey>[];
    for (final line in lines.skip(1)) {
      if (line.trim().isEmpty) continue;
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length >= 2) {
        keys.add(SigningKey(name: parts[0], sha3384: parts[1]));
      }
    }
    return keys;
  }

  /// Local keys with the `registered` flag filled in from the store.
  Future<List<SigningKey>> listKeys() async {
    final local = await listLocalKeys();
    final registeredFingerprints = await listRegisteredFingerprints();
    if (registeredFingerprints == null) return local;
    return local
        .map((k) =>
            k.copyWith(registered: registeredFingerprints.contains(k.sha3384)))
        .toList();
  }

  /// Key-name rules (unchanged from `KeyService`).
  /// Validates a signing key name: non-empty, <= 64 chars, and matching
  /// `^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$` (lowercase letters, digits and
  /// dashes; no leading/trailing dash). Returns an error message or `null`.
  static String? validateKeyName(String name) {
    if (name.isEmpty) return 'Key name is required.';
    if (name.length > 64) return 'Key name is too long.';
    if (!RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$').hasMatch(name)) {
      return 'Use lowercase letters, digits and dashes only.';
    }
    return null;
  }

  /// Creates the signing key [name] by generating it directly in the host
  /// GPG keyring via `gpg --gen-key` (see [GpgKeyGenerator]). The passphrase
  /// is entered in the system's graphical pinentry dialog (pinentry-gnome3)
  /// — the same popup `snap sign` uses — so no terminal is needed and the
  /// passphrase never touches this app. The key lands in the very keyring
  /// (`~/.snap/gnupg`) that `snap keys`, `snap export-key` and `snap sign`
  /// use, so nothing downstream changes.
  Future<void> createKey(String name) async {
    try {
      await keyGenerator.generate(name: name);
    } on KeyGenerationException catch (e) {
      throw KeyException(e.message);
    } catch (e) {
      throw KeyException('Key creation failed: $e');
    }
  }

  /// Registers a key: `snap export-key <name> <account-id>` produces the
  /// serialized assertion from the host GPG keyring (no prompt — the key
  /// already exists), then the assertion is uploaded through the Rust store
  /// client, replacing the `snapcraft register-key` terminal entirely.
  Future<void> registerKey(String name) async {
    final session = SnapstoreAuthSession.current;
    if (session == null || session.auth.state != AuthState.succeeded) {
      throw KeyException('Sign in to the Snap Store first.');
    }

    // 1. Account id (Rust whoami — one HTTP request).
    final info = await _whoami(session);
    final accountId = info.id;
    if (accountId.isEmpty) {
      throw KeyException('Could not determine the account id.');
    }

    // 2. Produce the assertion on the host (GPG keyring, no prompt).
    final assertion = await _exportKey(name, accountId);

    // 3. Upload through Rust (blocking FFI + HTTP — off the UI isolate).
    try {
      await Isolate.run(() => session.auth.registerKey(assertion));
    } catch (e) {
      if (_isExpiredCredential(e)) {
        throw KeyAuthExpiredException(_friendly(e));
      }
      throw KeyException(_friendly(e));
    }
  }

  /// `true` when [e] signals that the store rejected the macaroon pair
  /// (expired/invalid), i.e. the in-process session still *thinks* it is
  /// signed in but the store no longer honours its credentials. The 401 the
  /// store returns for `account-key` without a valid `Authorization` header
  /// is the sole trustworthy signal here (the body wording isn't a stable
  /// contract) — callers should re-run the interactive login rather than
  /// just surfacing the error.
  static bool _isExpiredCredential(Object e) {
    if (e is SnapstoreAuthError) {
      return e.kind == 'http' && e.httpStatus == 401;
    }
    return false;
  }

  /// Creates (if needed) then registers. The create step prompts for the
  /// passphrase in the system pinentry dialog; the register step runs through
  /// Rust as before.
  Future<void> createAndRegister(String name) async {
    final existing = await listLocalKeys();
    if (!existing.any((k) => k.name == name)) {
      await createKey(name);
    }
    await registerKey(name);
  }

  /// Cleanly stops the gpg-agent that snap uses for its keyring
  /// (~/.snap/gnupg) so it does not linger after the app exits.
  /// (Host-side, unchanged — kept for main.dart's shutdown path.)
  static Future<void> stopSnapGpgAgent() async {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return;
    try {
      await Process.run(
        'gpgconf',
        ['--homedir', '$home/.snap/gnupg', '--kill', 'gpg-agent'],
        environment: HostEnv.sanitized,
        includeParentEnvironment: false,
      );
    } catch (_) {}
  }

  // -- internals -------------------------------------------------------------

  Future<AccountInfo> _whoami(SnapstoreAuthSession session) async {
    try {
      return await Isolate.run(() => session.auth.whoami());
    } catch (_) {
      // Fall back to the UI isolate (bounded by the Rust-side timeout).
      return session.auth.whoami();
    }
  }

  /// `snap export-key --account=<account-id> <name>` — the serialized
  /// account-key assertion (no tty/prompt: the key already exists in the
  /// keyring).
  ///
  /// NOTE: the account id MUST be the `--account=` option, NOT a second
  /// positional. `snap export-key` accepts exactly one positional
  /// (`<key-name>`); passing the account id positionally yields
  /// `error: too many arguments for command`. This mirrors snapcraft's own
  /// invocation (`["snap", "export-key", f"--account={account_id}", name]`).
  Future<String> _exportKey(String name, String accountId) async {
    final shell = Shell(
      throwOnError: false,
      verbose: false,
      environment: HostEnv.sanitized,
      includeParentEnvironment: false,
    );
    final result = await shell.run(
        'snap export-key --account=${_shellQuote(accountId)} '
        '${_shellQuote(name)}');
    if (result.first.exitCode != 0) {
      final err = result.errText.trim();
      throw KeyException(err.isEmpty
          ? 'Could not export key "$name" (is it in the local keyring?).'
          : err);
    }
    final out = result.outText.trim();
    if (out.isEmpty) {
      throw KeyException('snap export-key returned no assertion.');
    }
    return out;
  }

  String _shellQuote(String s) {
    final escaped = s.replaceAll("'", "'\\''");
    return "'$escaped'";
  }

  static String _friendly(Object e) {
    // SnapstoreAuthError exposes `.detail`; anything else stringifies.
    Object? detail;
    try {
      detail = (e as dynamic).detail;
    } catch (_) {}
    if (detail is String && detail.isNotEmpty) {
      final idx = detail.lastIndexOf(' (code: ');
      final base = idx > 0 ? detail.substring(0, idx) : detail;
      return base.trim();
    }
    return e.toString();
  }
}

class KeyException implements Exception {
  final String message;
  KeyException(this.message);
  @override
  String toString() => message;
}

/// Thrown by [RustKeyService.registerKey] when the store rejects the
/// in-process session's macaroon (expired/invalid) with a 401. The
/// in-process [AuthState] still reads `succeeded`, so callers should offer
/// (or run) the interactive login again and retry, rather than just
/// displaying [message].
class KeyAuthExpiredException extends KeyException {
  KeyAuthExpiredException(super.message);
}
