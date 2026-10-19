// End-to-end test for the Rust-backed store services (RustStoreService /
// RustKeyService / RustStoreCatalogService) against the real native library and a
// local mock store (the `snapstore_auth` package's tool/mock_store.py,
// resolved via test/support/mock_store_path.dart).
//
// Skips automatically when the native library is not available (the
// adapters degrade gracefully in that case anyway):
//
//   SNAPSTORE_AUTH_LIB=/path/to/libsnapstore_auth.so flutter test \
//       test/rust_backend_e2e_test.dart
//
// Or stage it with:  ./scripts/build_rust_backend.sh
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ubuntu_core_model_builder/services/ffi/snapstore_auth_client.dart';
import 'package:ubuntu_core_model_builder/services/rust_key_service.dart';
import 'package:ubuntu_core_model_builder/services/rust_store_catalog_service.dart';
import 'package:ubuntu_core_model_builder/services/store_models.dart' show StoreAuthExpiredException;
import 'package:ubuntu_core_model_builder/services/rust_store_service.dart';
import 'support/mock_store_path.dart';

const _mockStore = 'http://127.0.0.1:8471';

void main() {
  late Process mock;

  setUpAll(() async {
    if (!SnapstoreAuthSession.isAvailable()) {
      print('SKIP: libsnapstore_auth not found '
          '(set SNAPSTORE_AUTH_LIB or run scripts/build_rust_backend.sh)');
      return;
    }
    mock = await Process.start('python3',
        [
          mockStorePath(),
          '--port',
          '8471',
          '--two-factor',
          '--password',
          's3cret',
          '--good-code',
          '654321',
        ],
        workingDirectory: Directory.current.path);
    // Wait for the socket to come up.
    for (var i = 0; i < 50; i++) {
      try {
        final s = await Socket.connect('127.0.0.1', 8471,
            timeout: const Duration(milliseconds: 200));
        await s.close();
        break;
      } on SocketException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  tearDownAll(() {
    mock.kill();
  });

  group('Rust backend (e2e, mock store)', () {
    late RustStoreService store;
    late RustStoreCatalogService catalog;

    setUp(() async {
      store = RustStoreService();
      catalog = RustStoreCatalogService();
      // A *completed* session is reusable by the next test (several tests
      // assume the login from the first test still holds). Only abort a
      // leftover IN-PROGRESS flow, which would block any new flow.
      final session = SnapstoreAuthSession.current;
      if (session != null) {
        final st = session.auth.state;
        if (st != AuthState.idle && st != AuthState.succeeded) {
          session.auth.cancel();
          await _waitStates(session, const {AuthState.idle},
              const Duration(seconds: 5));
        }
      }
    });

    test('library resolves', () {
      expect(SnapstoreAuthSession.isAvailable(), isTrue);
    });

    test('full login flow: credentials + 2FA -> succeeded', () async {
      final session = await SnapstoreAuthSession.init(
        storeUrl: _mockStore,
        loginUrl: _mockStore,
        permissions: RustStoreService.loginAcls.join(','),
      );

      // Interactive login with scripted prompts (no UI in the test).
      final s = await session.login(
        promptCredentials: () async {
          session.auth.submitCredentials('user@example.com', 's3cret');
          // Wait until the machine hands off to 2FA (or fails).
          await _waitStates(session,
              const {AuthState.needs2faCode, AuthState.idle},
              const Duration(seconds: 10));
          return session.auth.state != AuthState.idle;
        },
        promptTwoFactor: () async {
          session.auth.submit2faCode('654321');
          await _waitStates(session,
              const {AuthState.succeeded, AuthState.idle},
              const Duration(seconds: 10));
          return session.auth.state == AuthState.succeeded;
        },
      );

      expect(s, AuthState.succeeded);

      // The success event carries the credentials to persist.
      final events = session.auth.drainEvents();
      final succeeded = events.whereType<SucceededEvent>().toList();
      expect(succeeded, hasLength(1));
      final credsJson = succeeded.first.credentialsJson;
      final creds =
          jsonDecode(credsJson) as Map<String, Object?>;
      expect(creds['root'], isNotEmpty);
      expect(creds['discharge'], isNotEmpty);
    });

    test('interactive 2FA pause/resume emits the right events', () async {
      // Start from a clean slate: log out any session left by the login test.
      final prev = SnapstoreAuthSession.current;
      if (prev != null && prev.auth.state == AuthState.succeeded) {
        await prev.logout();
      }
      // Clear the LoggedOutEvent so the assertions below only see the
      // events emitted by THIS flow.
      prev?.auth.drainEvents();

      final session = await SnapstoreAuthSession.init(
        storeUrl: _mockStore,
        loginUrl: _mockStore,
        permissions: RustStoreService.loginAcls.join(','),
      );
      final auth = session.auth;

      // 1. idle -> needsCredentials.
      expect(auth.state, AuthState.idle);
      auth.startLogin();
      await _waitStates(session, const {AuthState.needsCredentials},
          const Duration(seconds: 5));
      expect(auth.state, AuthState.needsCredentials);
      expect(auth.drainEvents(),
          everyElement(isA<NeedsCredentialsEvent>()));

      // 2. Submit credentials -> the machine must PAUSE on the 2FA
      //    challenge, emit Needs2faCodeEvent, and NOT block or fail.
      auth.submitCredentials('user@example.com', 's3cret');
      await _waitStates(session, const {AuthState.needs2faCode, AuthState.idle},
          const Duration(seconds: 10));
      expect(auth.state, AuthState.needs2faCode,
          reason: 'a 2FA challenge must pause the flow');
      expect(auth.drainEvents(), everyElement(isA<Needs2faCodeEvent>()));

      // 3. Submit the TOTP code -> resume -> succeeded with the macaroons.
      auth.submit2faCode('654321');
      await _waitStates(session, const {AuthState.succeeded, AuthState.idle},
          const Duration(seconds: 10));
      expect(auth.state, AuthState.succeeded);
      final events = auth.drainEvents();
      final succeeded = events.whereType<SucceededEvent>().toList();
      expect(succeeded, hasLength(1));
      expect(succeeded.single.usedTwoFactor, isTrue);
      final creds = jsonDecode(succeeded.single.credentialsJson)
          as Map<String, Object?>;
      expect(creds['root'], isNotEmpty);
      expect(creds['discharge'], isNotEmpty);
    });

    test('account / store endpoints via the Rust client', () async {
      expect(SnapstoreAuthSession.hasActiveSession, isTrue);

      final acct = await store.getCurrentAccount();
      expect(acct, isNotNull);
      expect(acct!.email, 'mock@example.com');
      expect(acct.accountId, 'DEADBEEF1234DEADBEEF1234DEADBEEF1234DEAD');
      expect(acct.username, 'mockuser');

      final stores = await catalog.listStores();
      expect(stores.map((e) => e.id), contains('mock-brand'));
      expect(stores.map((e) => e.id), contains('ubuntu'));

      final snaps = await catalog.listStoreSnaps('mock-brand');
      expect(snaps.map((e) => e.name),
          containsAll(['mock-gadget', 'mock-kernel']));

      // Expired-macaroon simulation: the store stops honouring the session
      // while the in-process state machine still reads `succeeded`. The
      // catalog service must surface this as the typed
      // StoreAuthExpiredException the pages' re-login recovery relies on
      // (NOT the generic StoreAuthException), and getCurrentAccount() must
      // read null (its whoami 401s). try/finally (not addTearDown) so the
      // shared mock is restored even on an unexpected failure.
      // The flag is off now: reaching `succeeded` above required the mock
      // to accept a discharge, which is impossible while rejecting.
      await toggleRejectMacaroon(_mockStore);
      try {
        expect(await store.getCurrentAccount(), isNull,
            reason: 'whoami 401s, so the account reads null even though the '
                'in-process session still reports succeeded');
        await expectLater(catalog.listStores(),
            throwsA(isA<StoreAuthExpiredException>()));
        await expectLater(catalog.listStoreSnaps('mock-brand'),
            throwsA(isA<StoreAuthExpiredException>()));
      } finally {
        await toggleRejectMacaroon(_mockStore);
      }
      // Healthy again: the same calls succeed with NO re-login (the session
      // itself was never disturbed by the rejection).
      expect(await catalog.listStores(), isNotEmpty);
      expect(await catalog.listStoreSnaps('mock-brand'), isNotEmpty);
    });

    test('registered key fingerprints via RustKeyService', () async {
      final fps = await RustKeyService().listRegisteredFingerprints();
      expect(fps, isNotNull);
      expect(
          fps!.contains('aabbccdd00112233445566aabbccdd00112233445566'), isTrue);
    });

    test('restore a persisted pair (app relaunch simulation)', () async {
      final session = SnapstoreAuthSession.current!;
      // Log out (clears the in-process session).
      await session.logout();
      expect(SnapstoreAuthSession.hasActiveSession, isFalse);

      // Simulate an app relaunch: the pair a previous SucceededEvent would
      // have persisted, now fed back through restore().
      final pairJson = jsonEncode({'root': _fixtureRoot, 'discharge': _fixtureDischarge});
      final ok = await session.restore(pairJson);
      expect(ok, isTrue);
      expect(SnapstoreAuthSession.hasActiveSession, isTrue);
    });

    test('import an exported-login payload', () async {
      // The mock's fixture macaroons, in the `snapcraft export-login`
      // on-disk format: base64({"t":"u1-macaroon","v":{"r":..,"d":..}}).
      final root =
          'MDAyY2xvY2F0aW9uIGh0dHBzOi8vZGFzaGJvYXJkLnNuYXBjcmFmdC5pbwowMDE5aWRlbnRpZmllciByb290LWlkLTEKMDAxMGNpZCBjaWQtMDAxCjAwNTF2aWQgDVQZMibgN_0yFc5ogte1xjxpKc5XmjPtPUWWYjviSULNh5-nmPcN1s6-h-c8qSgmFQvO8Iy__a9fehkpatZve0PCpRiUI3hNCjAwMzhjbCBodHRwczovL2xvZ2luLnVidW50dS5jb20vYXBpL3YyL3Rva2Vucy9kaXNjaGFyZ2UKMDAyZnNpZ25hdHVyZSC0CqFfWTisBnfUsDI0y9i5xkTUuL-BFCOwFXL2EJj9dwo';
      final discharge =
          'MDAyNmxvY2F0aW9uIGh0dHBzOi8vbG9naW4udWJ1bnR1LmNvbQowMDFiaWRlbnRpZmllciBkaXNjaGFyZ2UtMQowMDBmc2lnbmF0dXJlIAo';
      final payload = base64Encode(utf8.encode(jsonEncode({
        't': 'u1-macaroon',
        'v': {'r': root, 'd': discharge},
      })));

      final session = SnapstoreAuthSession.current!;
      // Ensure we start from idle (the previous test may have left us
      // succeeded; a re-import must replace the session).
      if (session.auth.state == AuthState.succeeded) {
        await session.logout();
      }

      final s = await store.importCredentials(payload);
      expect(s, isNotNull);
      expect(SnapstoreAuthSession.hasActiveSession, isTrue);
    });

    test('logout then re-login (driver stays alive)', () async {
      final session = SnapstoreAuthSession.current!;
      await session.logout();
      expect(SnapstoreAuthSession.hasActiveSession, isFalse);

      // Re-login on the SAME runtime handle: requires the patched driver
      // (stays parked in Idle instead of exiting).
      final s = await session.login(
        promptCredentials: () async {
          session.auth.submitCredentials('user@example.com', 's3cret');
          await _waitStates(session,
              const {AuthState.needs2faCode, AuthState.idle},
              const Duration(seconds: 10));
          return session.auth.state != AuthState.idle;
        },
        promptTwoFactor: () async {
          session.auth.submit2faCode('654321');
          await _waitStates(session,
              const {AuthState.succeeded, AuthState.idle},
              const Duration(seconds: 10));
          return session.auth.state == AuthState.succeeded;
        },
      );
      expect(s, AuthState.succeeded);
    });
  });
}

// Exact macaroon fixtures served by the mock store (pymacaroons v1
// binary) — used for the restore/import tests.
const _fixtureRoot =
    'MDAyY2xvY2F0aW9uIGh0dHBzOi8vZGFzaGJvYXJkLnNuYXBjcmFmdC5pbwowMDE5aWRlbnRpZmllciByb290LWlkLTEKMDAxMGNpZCBjaWQtMDAxCjAwNTF2aWQgDVQZMibgN_0yFc5ogte1xjxpKc5XmjPtPUWWYjviSULNh5-nmPcN1s6-h-c8qSgmFQvO8Iy__a9fehkpatZve0PCpRiUI3hNCjAwMzhjbCBodHRwczovL2xvZ2luLnVidW50dS5jb20vYXBpL3YyL3Rva2Vucy9kaXNjaGFyZ2UKMDAyZnNpZ25hdHVyZSC0CqFfWTisBnfUsDI0y9i5xkTUuL-BFCOwFXL2EJj9dwo';
const _fixtureDischarge =
    'MDAyNmxvY2F0aW9uIGh0dHBzOi8vbG9naW4udWJ1bnR1LmNvbQowMDFiaWRlbnRpZmllciBkaXNjaGFyZ2UtMQowMDBmc2lnbmF0dXJlIAo';

/// Toggles the mock's "macaroon no longer honoured" mode (its /__reject
/// control endpoint). Paired calls in a try/finally restore the original
/// (off) state for the rest of the suite.
Future<void> toggleRejectMacaroon(String base) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(Uri.parse('$base/__reject'));
    final res = await req.close();
    final status = res.statusCode;
    await res.drain<void>();
    if (status != 200) throw StateError('mock /__reject returned $status');
  } finally {
    client.close(force: true);
  }
}

Future<AuthState> _waitStates(
    SnapstoreAuthSession session, Set<AuthState> targets, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final s = session.auth.state;
    if (targets.contains(s)) return s;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return session.auth.state;
}
