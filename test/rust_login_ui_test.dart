// Widget test: drives the *real* UI — the Account step's "Sign in" button
// through the in-app credentials dialog and the 2FA dialog — against the
// same mock store the e2e suite uses (the `snapstore_auth` package's
// tool/mock_store.py) and the
// real native Rust library (libsnapstore_auth).
//
// Skips automatically when the native library is not available (the app
// degrades gracefully in that case — the Sign in button stays disabled):
//
//   SNAPSTORE_AUTH_LIB=/path/to/libsnapstore_auth.so flutter test \
//       test/rust_login_ui_test.dart
//
// Or stage it with:  ./scripts/build_rust_backend.sh
//
// Isolation (coexists safely with rust_backend_e2e_test.dart):
//  * Different mock port: 8472 here vs 8471 in the e2e suite, so parallel
//    `flutter test` processes never collide on the socket.
//  * Different test files run in SEPARATE processes, so each gets its own
//    process-global Rust runtime (OnceLock). This file performs the first
//    `SnapstoreAuthSession.init` with the mock URLs; RustStoreService
//    (which inits without URLs) then reuses that already-configured
//    runtime.
//
// Timing (the tricky part):
//  * The test body runs in FAKE async. `pump` advances the app's
//    `Timer.periodic` pollers (the dialog phase watchers, the login loop);
//    a bare `await Future.delayed(...)` in the body would never complete
//    (fake time only moves on pump). The Rust driver does its HTTP I/O on
//    real wall-clock time, so `_wait` alternates `pump` (fake) with
//    `runAsync(sleep)` (real) to keep both in sync.
//  * `pumpAndSettle` is deliberately NOT used: while a flow is in flight a
//    periodic poller timer is always pending, so settle would time out.
//  * Every test ends with the machine in `idle`, no dialogs open, and no
//    periodic timer left behind (the dialog watchers are one-shot
//    self-terminating, but they need a few fake frames after the flow
//    settles to notice — `settleWatchers` provides them).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ubuntu_core_model_builder/models/wizard_step.dart';
import 'package:ubuntu_core_model_builder/pages/account_page.dart';
import 'package:ubuntu_core_model_builder/services/ffi/snapstore_auth_client.dart';
import 'package:ubuntu_core_model_builder/services/rust_store_service.dart';
import 'support/mock_store_path.dart';

const _mockStore = 'http://127.0.0.1:8472';
const _password = 's3cret';
const _goodCode = '654321';
const _badCode = '000000';
const _email = 'user@example.com';

// Button/field finders. `find.text('Sign in')` alone is ambiguous while
// the credentials dialog is open (the page button and the dialog's submit
// button share the label), so dialog buttons are scoped to the open
// AlertDialog. `find.byType(TextField)` would NOT match the dialogs'
// TextFormFields (exact runtime-type matching), hence byType(TextFormField).
Finder pageSignIn() => find.widgetWithText(ElevatedButton, 'Sign in');
Finder dialogSubmit() => find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text('Sign in'),
    );
Finder dialogVerify() => find.widgetWithText(ElevatedButton, 'Verify');
Finder dialogCancel() => find.widgetWithText(TextButton, 'Cancel');
Finder signOut() => find.widgetWithText(TextButton, 'Sign out');

/// Polls [condition] until it holds or [timeout] of REAL time elapses,
/// interleaving fake-clock pumps (app pollers) with real-time slices (Rust
/// driver HTTP). Returns whether the condition finally held.
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

  /// AccountPage is a StatelessWidget that does not observe [state] itself;
  /// HomePage subscribes in the real app (`_state.addListener`). Mirror
  /// that with a ListenableBuilder so the page rebuilds when the login
  /// settles the account.
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

  /// Puts the machine back to `idle` with a clean event buffer, whatever a
  /// previous test left behind.
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

  /// After a dialog closes, the dialog's phase watcher keeps polling for
  /// up to one more tick (150ms fake) before it notices the flow settled
  /// and cancels its periodic timer. Pump until no dialog / no in-flight
  /// state, then a few extra frames, so no periodic timer leaks past the
  /// test (the binding fails tests on leaked periodic timers).
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

  /// Pumps fake time until a snackbar (if any) has fully dismissed, so the
  /// page is in a clean state at test end.
  Future<void> drainSnackbars(WidgetTester t) async {
    for (var i = 0; i < 60; i++) {
      if (find.byType(SnackBar).evaluate().isEmpty) return;
      await t.pump(const Duration(milliseconds: 500));
    }
  }

  /// Opens the credentials dialog from the page (asserts it appears).
  Future<void> openCredentialsDialog(WidgetTester t) async {
    await t.tap(pageSignIn());
    final ok = await _wait(t,
        () => find.text('Sign in to the Snap Store').evaluate().isNotEmpty);
    expect(ok, isTrue, reason: 'the credentials dialog must open');
  }

  /// Fills and submits the credentials dialog, then waits for the 2FA
  /// dialog to take over (the machine must PAUSE on the challenge, not
  /// block or fail).
  Future<void> submitCredentialsAndWaitFor2fa(WidgetTester t) async {
    await t.enterText(find.byType(TextFormField).first, _email);
    await t.enterText(find.byType(TextFormField).last, _password);
    await t.tap(dialogSubmit());
    final ok = await _wait(t,
        () => find.text('Two-factor authentication').evaluate().isNotEmpty);
    expect(ok, isTrue, reason: 'the 2FA dialog must open');
    // The credentials dialog slides out during the route removal
    // transition; wait for it to be gone before addressing the 2FA field.
    await _wait(t,
        () => find.text('Sign in to the Snap Store').evaluate().isEmpty);
    expect(session.auth.state, AuthState.needs2faCode,
        reason: 'the Rust machine must be paused on the 2FA challenge');
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
          '8472',
          '--two-factor',
          '--password',
          _password,
          '--good-code',
          _goodCode,
        ],
        workingDirectory: Directory.current.path);
    // Wait for the socket to come up.
    for (var i = 0; i < 50; i++) {
      try {
        final s = await Socket.connect('127.0.0.1', 8472,
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

  group('Sign in button -> credentials + 2FA dialogs (mock store)', () {
    testWidgets(
        'validation blocks empty submit; good credentials pause the '
        'machine on the 2FA dialog; cancel aborts the flow',
        (WidgetTester t) async {
      if (!SnapstoreAuthSession.isAvailable()) return;
      await parkIdle(t);
      state = WizardState();
      await t.pumpWidget(pageFor(state));
      await t.pump();

      // 1. The "Not signed in" tile exposes an enabled Sign in button.
      expect(find.text('Not signed in'), findsOneWidget);
      expect(pageSignIn(), findsOneWidget);
      expect(t.widget<ButtonStyleButton>(pageSignIn()).onPressed, isNotNull);

      // 2. Tap -> the credentials dialog appears.
      await openCredentialsDialog(t);
      expect(find.text('Ubuntu One email'), findsOneWidget);
      expect(find.text('Password'), findsOneWidget);

      // 3. An empty submit is blocked by form validation.
      await t.tap(dialogSubmit());
      await t.pump();
      expect(find.text('Email is required.'), findsOneWidget);
      expect(find.text('Password is required.'), findsOneWidget);

      // 4. Good credentials -> the Rust machine hands off to the 2FA
      //    challenge and PAUSES (no blocking, no failure). Note: with
      //    two-factor enabled the store answers the first (OTP-less)
      //    discharge with twofactor-required for ANY password, so the
      //    hand-off happens even for a wrong password — that is exactly
      //    the interactive pause this test is about.
      await submitCredentialsAndWaitFor2fa(t);

      // 5. Cancel at the 2FA prompt: the dialog closes, the whole flow is
      //    aborted, and nothing is logged in.
      await t.tap(dialogCancel());
      await _wait(t, () => find.byType(AlertDialog).evaluate().isEmpty);
      await _wait(t, () => session.auth.state == AuthState.idle,
          timeout: const Duration(seconds: 10));
      expect(SnapstoreAuthSession.hasActiveSession, isFalse);
      expect(find.text('Not signed in'), findsOneWidget);
      expect(find.textContaining('Sign-in was cancelled or failed'),
          findsOneWidget);
      await settleWatchers(t);
      await drainSnackbars(t);
    });

    testWidgets(
        'full journey: credentials -> 2FA dialog -> wrong code retry -> '
        'good code -> signed in -> sign out', (WidgetTester t) async {
      if (!SnapstoreAuthSession.isAvailable()) return;
      await parkIdle(t);
      state = WizardState();
      await t.pumpWidget(pageFor(state));
      await t.pump();

      // --- Phase 1+2: credentials -> the machine pauses on 2FA ---------
      await openCredentialsDialog(t);
      await submitCredentialsAndWaitFor2fa(t);

      // --- Phase 3: a wrong code is rejected inline; dialog stays open --
      final codeField = find.byType(TextFormField).first;
      await t.enterText(codeField, _badCode);
      await t.tap(dialogVerify());
      await _wait(t,
          () => find.text('The code was not accepted. Check it and try again.')
              .evaluate()
              .isNotEmpty);
      expect(find.text('Two-factor authentication'), findsOneWidget);
      expect(session.auth.state, AuthState.needs2faCode);

      // --- Phase 4: the correct code completes the login ---------------
      await t.enterText(codeField, _goodCode);
      await t.tap(dialogVerify());

      // --- Phase 5: both dialogs gone; the page shows the account ------
      await _wait(t,
          () => find.text('Two-factor authentication').evaluate().isEmpty &&
              find.text('Sign in to the Snap Store').evaluate().isEmpty);
      await _wait(t, () => find.text('mock@example.com').evaluate().isNotEmpty);
      expect(session.auth.state, AuthState.succeeded);
      expect(SnapstoreAuthSession.hasActiveSession, isTrue);
      expect(
          find.textContaining(
              'Account ID: DEADBEEF1234DEADBEEF1234DEADBEEF1234DEAD'),
          findsOneWidget);
      expect(state.account, isNotNull);
      expect(state.account!.email, 'mock@example.com');
      expect(state.account!.accountId,
          'DEADBEEF1234DEADBEEF1234DEADBEEF1234DEAD');

      // --- Phase 6: sign out returns to the "Not signed in" tile -------
      await t.tap(signOut());
      await _wait(t, () => !SnapstoreAuthSession.hasActiveSession,
          timeout: const Duration(seconds: 15));
      await _wait(t, () => find.text('Not signed in').evaluate().isNotEmpty,
          timeout: const Duration(seconds: 15));
      expect(session.auth.state, AuthState.idle);
      expect(state.account, isNull);
      await settleWatchers(t);
    });

    testWidgets(
        'cancel from the credentials dialog aborts the flow; the machine '
        'stays reusable on the same handle', (WidgetTester t) async {
      if (!SnapstoreAuthSession.isAvailable()) return;
      await parkIdle(t);
      state = WizardState();
      await t.pumpWidget(pageFor(state));
      await t.pump();

      // 1. Open the credentials dialog and cancel it.
      await openCredentialsDialog(t);
      await t.tap(dialogCancel());
      await _wait(t, () => find.byType(AlertDialog).evaluate().isEmpty);
      await _wait(t, () => session.auth.state == AuthState.idle,
          timeout: const Duration(seconds: 10));
      expect(SnapstoreAuthSession.hasActiveSession, isFalse);
      expect(find.text('Not signed in'), findsOneWidget);
      expect(find.textContaining('Sign-in was cancelled or failed'),
          findsOneWidget);
      await settleWatchers(t);
      await drainSnackbars(t);

      // 2. The driver stays parked in Idle (the patched behavior): a fresh
      //    flow can start on the same handle right away.
      await openCredentialsDialog(t);
      await t.tap(dialogCancel());
      await _wait(t, () => find.byType(AlertDialog).evaluate().isEmpty);
      await _wait(t, () => session.auth.state == AuthState.idle,
          timeout: const Duration(seconds: 10));
      await settleWatchers(t);
      await drainSnackbars(t);
    });
  });
}
