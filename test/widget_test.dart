// App smoke test: the wizard shell builds and shows the account step.
//
// (Replaces the default counter-app template test, which referenced a
// `MyApp` class that never existed in this project.)
//
// The Rust auth backend is not initialized in widget tests (main() does
// that); RustStoreService degrades gracefully to "not signed in".
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

    // An error stays in the status bar with a dismiss control.
    StatusBarService.instance.error('Something went wrong');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.byTooltip('Dismiss (Esc)'), findsOneWidget);

    // A success message replaces it and no dismiss button is offered.
    StatusBarService.instance.success('All done');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('All done'), findsOneWidget);
    expect(find.byTooltip('Dismiss (Esc)'), findsNothing);

    // Dismissing empties the bar again (one pump covers the AnimatedSwitcher
    // exit transition).
    StatusBarService.instance.clear();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('All done'), findsNothing);

    StatusBarService.instance.clear();
  });
}
