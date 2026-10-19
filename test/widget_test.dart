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

    // App bar + the first wizard step's headline.
    // The app bar shows the app name. Scope to the AppBar: the sidebar
    // header (home_page.dart) also renders a "Model Builder" brand label, so
    // an unscoped find.text would match two and fail findsOneWidget.
    expect(find.descendant(of: find.byType(AppBar),
            matching: find.text('Model Builder')),
        findsOneWidget);
    expect(find.text('Getting Started'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
  });
}
