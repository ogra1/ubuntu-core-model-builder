// Widget tests for the wizard shell and the Account step.
//
// These drive the real [HomePage] (wrapped in the same YaruTheme/MaterialApp
// the app uses) and verify the navigation rail, footer buttons, and the
// account step's content. They also lock in the step-1 change: no "snapcraft"
// remnant is rendered anywhere on the account step.
//
// The Rust auth backend is not initialized in widget tests (main() does that);
// RustStoreService degrades gracefully to "not signed in". Bounded pumps are
// used (NOT pumpAndSettle) because the app owns a periodic poll timer.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaru/yaru.dart';

import 'package:ubuntu_core_model_builder/pages/home_page.dart';

Widget harness(Widget child) {
  return YaruTheme(
    builder: (context, yaru, _) {
      return MaterialApp(
        title: 'Model Builder',
        theme: yaru.theme,
        darkTheme: yaru.darkTheme,
        debugShowCheckedModeBanner: false,
        home: child,
      );
    },
  );
}

Future<void> pumpApp(WidgetTester tester) async {
  // Desktop-sized surface (matches the existing smoke test; the default
  // 800x600 is too narrow and triggers a benign YaruTile overflow).
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(harness(const HomePage()));
  // Let HomePage._bootstrap() (ToolLocator + RustStoreService) settle its
  // async work with bounded pumps.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump();
}

void main() {
  testWidgets('rail shows all six wizard step labels', (tester) async {
    await pumpApp(tester);
    for (final label in [
      'Account',
      'Metadata',
      'Snaps',
      'Extras',
      'Signing Key',
      'Review & Sign',
    ]) {
      expect(find.text(label), findsOneWidget, reason: 'missing "$label"');
    }
  });

  testWidgets('footer Back and Next start disabled', (tester) async {
    await pumpApp(tester);

    final back = tester.widget<OutlinedButton>(
      find.ancestor(
          of: find.text('Back'), matching: find.byType(OutlinedButton)),
    );
    final next = tester.widget<ElevatedButton>(
      find.ancestor(
          of: find.text('Next'), matching: find.byType(ElevatedButton)),
    );
    // Nothing is complete yet: can't go back (first step) or next.
    expect(back.onPressed, isNull);
    expect(next.onPressed, isNull);
  });

  testWidgets('account step renders the required tools and sign-in UI',
      (tester) async {
    await pumpApp(tester);

    // Step headline. The app bar was removed as redundant, so 'Model
    // Builder' now appears exactly once: the sidebar brand header.
    expect(find.text('Model Builder'), findsOneWidget);
    expect(find.text('Getting Started'), findsOneWidget);

    // Required tools section. snapd is required; pinentry is recommended.
    expect(find.text('Required Tools'), findsOneWidget);
    expect(find.text('snap'), findsWidgets);
    expect(find.text('pinentry (graphical passphrase prompt)'), findsOneWidget);

    // Not signed in: the sign-in and import actions are offered.
    expect(find.text('Not signed in'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Import credentials'), findsOneWidget);
  });

  testWidgets('no snapcraft remnant is rendered (step-1 regression)',
      (tester) async {
    await pumpApp(tester);
    // Step 1 removed the snapcraft tile, install handler, and all gating.
    // The literal text must not appear anywhere on the account step.
    expect(find.textContaining('snapcraft'), findsNothing);
  });

  testWidgets('rail collapse toggle flips between extended and collapsed',
      (tester) async {
    await pumpApp(tester);

    // Extended rail: the toggle tooltip is "Collapse" and step labels are
    // shown in the rail.
    expect(find.byTooltip('Collapse'), findsOneWidget);
    expect(find.text('Account'), findsOneWidget);

    // Collapse the rail. (Labels remain mounted but are visually clipped by
    // the rail; the tooltip flip is the authoritative state signal.)
    await tester.tap(find.byTooltip('Collapse'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byTooltip('Expand'), findsOneWidget);

    // Expand again to confirm the toggle round-trips.
    await tester.tap(find.byTooltip('Expand'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byTooltip('Collapse'), findsOneWidget);
    expect(find.text('Account'), findsOneWidget);
  });

  testWidgets('disabled future rail destinations are not selectable',
      (tester) async {
    await pumpApp(tester);

    // Only the Account step is enabled at start. The Review destination is
    // disabled (isStepEnabled(Review) == false), so its NavigationRail
    // destination reports disabled=true and cannot be selected.
    final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
    final destinations =
        rail.destinations.cast<NavigationRailDestination>().toList();
    expect(destinations, hasLength(6));
    expect(destinations[0].disabled, isFalse); // Account
    // Every later step is disabled until its prerequisites are complete.
    for (var i = 1; i < destinations.length; i++) {
      expect(destinations[i].disabled, isTrue,
          reason: 'step $i must be disabled at start');
    }
  });
}
