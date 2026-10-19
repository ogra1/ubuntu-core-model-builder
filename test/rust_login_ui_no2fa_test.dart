// Widget test (no-2FA mode): drives the *real* UI — the Account step's
// "Sign in" button through the in-app credentials dialog — against the
// mock store (the `snapstore_auth` package's tool/mock_store.py, resolved
// via test/support/mock_store_path.dart) in NO-TWO-FACTOR mode (without
// --two-factor) and the real native Rust library (libsnapstore_auth).
//
// In no-2FA mode the mock validates the password on the FIRST discharge:
// a wrong password gets 401 BAD_CREDENTIALS directly (no twofactor-required
// challenge), so the Rust machine maps it to `credentials_rejected` and the
// dialog must surface it INLINE — this file verifies exactly that.
//
// Skips automatically when the native library is not available:
//
//   SNAPSTORE_AUTH_LIB=/path/to/libsnapstore_auth.so flutter test \
//       test/rust_login_ui_no2fa_test.dart
//
// Or stage it with:  ./scripts/build_rust_backend.sh
//
// Isolation (why this coexists with the other suites):
//  * Different mock port: 8473 here; 8471 = rust_backend_e2e_test.dart,
//    8472 = rust_login_ui_test.dart (the 2FA dialog journey).
//  * Different test files run in SEPARATE processes, so each gets its own
//    process-global Rust runtime (OnceLock). This file performs the first
//    `SnapstoreAuthSession.init` with the mock URLs; RustStoreService
//    (which inits without URLs) then reuses that already-configured
//    runtime.
//
// Timing: the test body is fake-async; `pump` advances the app's
// Timer.periodic pollers while `runAsync(sleep)` gives the Rust driver's
// real HTTP I/O wall-clock time. `_wait` alternates the two. See the file
// header of rust_login_ui_test.dart for the full discussion.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ubuntu_core_model_builder/models/wizard_step.dart';
import 'package:ubuntu_core_model_builder/pages/account_page.dart';
import 'package:ubuntu_core_model_builder/services/ffi/snapstore_auth_client.dart';
import 'package:ubuntu_core_model_builder/services/rust_store_service.dart';
import 'support/mock_store_path.dart';

const _mockStore = 'http://127.0.0.1:8473';
const _password = 's3cret';
const _email = 'user@example.com';

Finder pageSignIn() => find.widgetWithText(ElevatedButton, 'Sign in');
Finder dialogSubmit() => find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text('Sign in'),
    );
Finder dialogCancel() => find.widgetWithText(TextButton, 'Cancel');

/// Polls [condition] until it holds or [timeout] of REAL time elapses,
/// interleaving fake-clock pumps (app pollers) with real-time slices
/// (Rust driver HTTP). Returns whether the condition finally held.
Future<bool> _wait(
    WidgetTester tester, bool Function() condition,
    {Duration timeout = const Duration(seconds: 45)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return true;
    await tester.pump(const Duration(milliseconds: 250));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
  }
  return condition();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Process mock;
  late SnapstoreAuthSession session;
  late WizardState state;

  /// AccountPage is a StatelessWidget; HomePage subscribes to [state] in the
  /// real app (`_state.addListener`). Mirror that so the page rebuilds
  /// when the login settles the account.
  Widget pageFor(WizardState s) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: ListenableBuilder(
            listenable: s,
            builder: (context, _) =>
                AccountPage(state: s, onRetry: () async {}),
          ),
        ),
      );

  /// Puts the machine back to `idle` with a clean event buffer.
  Future<void> parkIdle(WidgetTester t) async {
    final s0 = session.auth.state;
    if (s0 == AuthState.succeeded) {
      session.auth.logout();
    } else if (s0 != AuthState.idle) {
      session.auth.cancel();
    }
    if (s0 != AuthState.idle) {
      await _wait(t, () => session.auth.state == AuthState.idle,
          timeout: const Duration(seconds: 10));
    }
    session.auth.drainEvents();
  }

  /// After a dialog closes, the dialog's phase watcher needs a few more
  /// fake frames to notice the flow settled and cancel its periodic timer.
  /// Pump until it's gone so no timer leaks past the test.
  Future<void> settleWatchers(WidgetTester t) async {
    for (var i = 0; i < 40; i++) {
      await t.pump(const Duration(milliseconds: 200));
      final anyDialog = find.byType(AlertDialog).evaluate().isNotEmpty;
      final inFlight = session.auth.state == AuthState.working ||
          session.auth.state == AuthState.needsCredentials ||
          session.auth.state == AuthState.needs2faCode;
      if (!anyDialog && !inFlight) {
        for (var j = 0; j < 4; j++) {
          await t.pump(const Duration(milliseconds: 200));
        }
        return;
      }
    }
  }

  /// Opens the credentials dialog from the page (asserts it appears).
  Future<void> openCredentialsDialog(WidgetTester t) async {
    await t.tap(pageSignIn());
    final ok = await _wait(t,
        () => find.text('Sign in to the Snap Store').evaluate().isNotEmpty);
    expect(ok, isTrue, reason: 'the credentials dialog must open');
  }

  setUpAll(() async {
    if (!SnapstoreAuthSession.isAvailable()) {
      print('SKIP: libsnapstore_auth not found '
          '(set SNAPSTORE_AUTH_LIB or run scripts/build_rust_backend.sh)');
      return;
    }
    mock = await Process.start(
        'python3',
        [
          mockStorePath(),
          '--port',
          '8473',
          '--no-two-factor',
          '--password',
          _password,
        ],
        workingDirectory: Directory.current.path);
    // Wait for the socket to come up.
    for (var i = 0; i < 50; i++) {
      try {
        final s = await Socket.connect('127.0.0.1', 8473,
            timeout: const Duration(milliseconds: 200));
        await s.close();
        break;
      } on SocketException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    // FIRST init in this process: configures the process-global Rust
    // runtime at the mock store (see the file header).
    session = await SnapstoreAuthSession.init(
      storeUrl: _mockStore,
      loginUrl: _mockStore,
      permissions: RustStoreService.loginAcls.join(','),
    );
    state = WizardState();
  });

  tearDownAll(() {
    mock.kill();
  });

  group('Sign in without 2FA (mock store, no-2FA mode)', () {
    testWidgets(
        'wrong password -> inline credentials error; the dialog stays '
        'open and the flow can be retried', (WidgetTester t) async {
      if (!SnapstoreAuthSession.isAvailable()) return;
      await parkIdle(t);
      state = WizardState();
      await t.pumpWidget(pageFor(state));
      await t.pump();

      expect(find.text('Not signed in'), findsOneWidget);
      expect(pageSignIn(), findsOneWidget);
      expect(t.widget<ButtonStyleButton>(pageSignIn()).onPressed, isNotNull);

      // 1. Open the credentials dialog and submit a WRONG password.
      await openCredentialsDialog(t);
      await t.enterText(find.byType(TextFormField).first, _email);
      await t.enterText(find.byType(TextFormField).last, 'wrong-password');
      await t.tap(dialogSubmit());

      // 2. While the discharge round-trip is in flight the dialog shows
      //    its submitting state.
      await _wait(t, () => find.text('Signing in…').evaluate().isNotEmpty);

      // 3. The 401 BAD_CREDENTIALS must surface as an INLINE error — the
      //    dialog stays open (no crash, no premature pop, no 2FA dialog).
      await _wait(t,
          () => find.textContaining('rejected your credentials')
              .evaluate()
              .isNotEmpty);
      expect(find.text('Sign in to the Snap Store'), findsOneWidget,
          reason: 'the dialog must stay open for a retry');
      expect(find.text('Two-factor authentication'), findsNothing,
          reason: 'no-2FA mode must not escalate to the 2FA dialog');
      expect(session.auth.state, AuthState.idle,
          reason: 'a rejected flow settles back to idle');

      // 4. In-place retry: fix the password and submit again — the SAME
      //    dialog completes the login (this is the regression the stale
      //    watcher pop guard protects).
      await t.enterText(find.byType(TextFormField).last, _password);
      await t.tap(dialogSubmit());
      await _wait(t, () => find.text('mock@example.com').evaluate().isNotEmpty);

      // 5. Both dialogs gone; the page shows the signed-in account.
      expect(find.text('Sign in to the Snap Store'), findsNothing);
      expect(find.text('Two-factor authentication'), findsNothing);
      expect(session.auth.state, AuthState.succeeded);
      expect(SnapstoreAuthSession.hasActiveSession, isTrue);
      expect(state.account, isNotNull);
      expect(state.account!.email, 'mock@example.com');

      // 6. Sign out: back to the "Not signed in" tile (suite cleanup).
      await t.tap(find.widgetWithText(TextButton, 'Sign out'));
      await _wait(t, () => !SnapstoreAuthSession.hasActiveSession,
          timeout: const Duration(seconds: 15));
      await _wait(t, () => find.text('Not signed in').evaluate().isNotEmpty,
          timeout: const Duration(seconds: 15));
      expect(session.auth.state, AuthState.idle);
      expect(state.account, isNull);
      await settleWatchers(t);
    });
  });
}
