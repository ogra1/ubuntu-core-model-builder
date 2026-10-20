// App smoke test: the wizard shell builds and shows the account step.
//
// (Replaces the default counter-app template test, which referenced a
// `MyApp` class that never existed in this project.)
//
// The Rust auth backend is not initialized in widget tests (main() does
// that); RustStoreService degrades gracefully to "not signed in".
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ubuntu_core_model_builder/main.dart';
import 'package:ubuntu_core_model_builder/services/status_bar_service.dart';

void main() {
  testWidgets('wizard shell builds and shows the Account step',
      (WidgetTester tester) async {
    // This is a desktop app: size the test surface like a real window
    // (the default 800x600 viewport is too narrow for the account page's
    // button row and triggers a benign YaruTile overflow in tests only).
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const ModelBuilderApp());
    // Bounded pumps, NOT pumpAndSettle: the app owns a periodic poll
    // timer (RustStoreService), which would otherwise never settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // The app name lives in the sidebar brand header (the top app bar was
    // removed as redundant); the first wizard step's headline is visible.
    expect(find.text('Model Builder'), findsOneWidget);
    expect(find.text('Getting Started'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('status bar shows posted messages and clears on dismiss',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const ModelBuilderApp());
    await tester.pump();

    // An error stays in the footer with a dismiss control.
    StatusBarService.instance.error('Something went wrong');
    await tester.pump();
    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.byTooltip('Dismiss (Esc)'), findsOneWidget);

    // Errors do NOT auto-clear: well past the info/success timeout they are
    // still visible.
    await tester.pump(const Duration(seconds: 6));
    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.byTooltip('Dismiss (Esc)'), findsOneWidget);

    // A success message replaces it; no dismiss button is offered.
    StatusBarService.instance.success('All done');
    await tester.pump();
    expect(find.text('All done'), findsOneWidget);
    expect(find.byTooltip('Dismiss (Esc)'), findsNothing);

    // ...and it auto-clears once the 5s timeout elapses.
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('All done'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('All done'), findsNothing);
    StatusBarService.instance.clear();
  });

  testWidgets('truncated text gets a hover tooltip; short text does not',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // A narrow host row, standing in for the footer's left slot.
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: 160,
            child: TruncatingTooltipText(
                'Could not load the store catalog: the store rejected the '
                    'session because the macaroon expired.'),
          ),
        ),
      ),
    ));
    await tester.pump();

    const msg = 'Could not load the store catalog: the store rejected the '
        'session because the macaroon expired.';

    // It is ellipsized in the 160px slot, so a Tooltip is attached.
    expect(find.text(msg), findsOneWidget);
    expect(find.ancestor(of: find.text(msg), matching: find.byType(Tooltip)),
        findsOneWidget);

    // A short text at the same width is not truncated: no Tooltip.
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
              width: 160, child: TruncatingTooltipText('Ready')),
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('Ready'), findsOneWidget);
    expect(find.ancestor(of: find.text('Ready'),
        matching: find.byType(Tooltip)), findsNothing);

    // Back to the long text: hovering opens the overlay with the full text.
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(width: 160, child: TruncatingTooltipText(msg)),
        ),
      ),
    ));
    await tester.pump();

    final gesture =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.text(msg)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    // The overlay renders the full message a second time.
    expect(find.text(msg), findsNWidgets(2));

    // ...and it dismisses once the pointer leaves (RawTooltip dismisses
    // after its exit delay; pump in small steps so that timer runs).
    await gesture.moveTo(const Offset(700, 400));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.text(msg), findsOneWidget);
    await gesture.removePointer();
    await tester.pump();
  });
}
