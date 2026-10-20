// Widget tests for the content pages (metadata, snaps, keys, review, extras).
//
// Each page is driven with injected state (a real WizardState / ModelAssertion)
// and rendered under the app's YaruTheme/MaterialApp harness. Inputs are
// chosen so every async path is hermetic (no network, no Rust backend):
//   * metadata/extras/review  - prefs only
//   * keys                    - local `snap keys` only (Rust session absent)
//   * snaps                   - base + snapd present, NO gadget, global store,
//                               so _seedRequiredSnaps / _loadStoreName /
//                               _resolveGadgetBase all no-op (no HTTP).
// Bounded pumps are used (NOT pumpAndSettle) to flush the async loads.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yaru/yaru.dart';

import 'package:ubuntu_core_model_builder/models/model_assertion.dart';
import 'package:ubuntu_core_model_builder/models/snap_entry.dart';
import 'package:ubuntu_core_model_builder/models/wizard_step.dart';
import 'package:ubuntu_core_model_builder/pages/extras_page.dart';
import 'package:ubuntu_core_model_builder/pages/keys_page.dart';
import 'package:ubuntu_core_model_builder/pages/metadata_page.dart';
import 'package:ubuntu_core_model_builder/pages/review_page.dart';
import 'package:ubuntu_core_model_builder/pages/snaps_page.dart';

Widget harness(Widget page) {
  return YaruTheme(
    builder: (context, yaru, _) {
      return MaterialApp(
        theme: yaru.theme,
        darkTheme: yaru.darkTheme,
        debugShowCheckedModeBanner: false,
        home: Scaffold(body: page),
      );
    },
  );
}

/// Pumps [page] at desktop size and lets its async loads settle with bounded
/// pumps.
Future<void> pumpPage(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(harness(page));
  // Let initState / post-frame async work (prefs, `snap keys`) settle.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

/// A WizardState with a valid model identity and base (no snaps needed for
/// most pages).
WizardState stateWith({String? model = 'my-device', String? key}) {
  final st = WizardState();
  st.model
    ..model = model
    ..brandId = 'abc123'
    ..authorityId = 'abc123'
    ..base = 'core24';
  st.selectedKeyName = key;
  return st;
}

void main() {
  setUp(() {
    // Deterministic, in-memory prefs (no platform channel in tests).
    SharedPreferences.setMockInitialValues({});
  });

  group('MetadataPage', () {
    testWidgets('renders the identity form with the model name prefilled',
        (tester) async {
      final st = stateWith();
      await pumpPage(
          tester, MetadataPage(state: st, onChanged: () {}));

      expect(find.text('Model Metadata'), findsOneWidget);
      expect(find.text('Model Identity'), findsOneWidget);
      expect(find.text('Browse examples'), findsOneWidget);
      expect(find.text('Import model'), findsOneWidget);

      // The name field is prefilled from model.model.
      final nameField = find.byType(TextField).first;
      final controller =
          tester.widget<TextField>(nameField).controller!;
      expect(controller.text, 'my-device');
    });

    testWidgets('System: architecture and base share one row; no i386',
        (tester) async {
      final st = stateWith();
      await pumpPage(
          tester, MetadataPage(state: st, onChanged: () {}));

      // The two short, fixed-vocabulary pulldowns share a single row
      // (architecture first, base second) instead of stacking full-width.
      final arch =
          find.byType(DropdownButtonFormField<ModelArchitecture>);
      final base = find.byType(DropdownButtonFormField<String>).first;
      expect(arch, findsOneWidget);
      expect(base, findsOneWidget);

      final archRect = tester.getRect(arch);
      final baseRect = tester.getRect(base);
      expect(baseRect.top, archRect.top,
          reason: 'base must sit on the same row as architecture');
      expect(baseRect.left, greaterThan(archRect.right),
          reason: 'architecture is the left field, base the right one');

      // Ubuntu Core does not support i386: it is not an option. Open the
      // architecture menu and check the offered values. (The *selected*
      // value is also rendered in the button, so the unselected options —
      // arm64/armhf/riscv64 — are each exactly one; amd64 is not asserted
      // here because it would match the button too.)
      await tester.tap(arch);
      await tester.pumpAndSettle();
      expect(find.text('i386'), findsNothing);
      expect(find.text('arm64'), findsOneWidget);
      expect(find.text('armhf'), findsOneWidget);
      expect(find.text('riscv64'), findsOneWidget);
      // Close the menu again.
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
    });
  });

  group('ExtrasPage', () {
    testWidgets('renders the optional-settings sections', (tester) async {
      final st = stateWith();
      await pumpPage(tester, ExtrasPage(state: st, onChanged: () {}));

      expect(find.text('Extras'), findsOneWidget);
      expect(find.text('System-user authority'), findsOneWidget);
      expect(find.text('Brand only (default)'), findsOneWidget);
    });
  });

  group('KeysPage', () {
    testWidgets('renders the header and key actions', (tester) async {
      final st = stateWith();
      await pumpPage(tester, KeysPage(state: st));

      // The header and actions render synchronously. (The key list itself is
      // loaded from the host keyring via a real `snap keys` process call,
      // which is process-coupled and not deterministically pumpable in a
      // widget test, so we assert the chrome rather than the loaded list.)
      expect(find.text('Signing Key'), findsOneWidget);
      expect(find.text('New key'), findsOneWidget);
      expect(find.text('Refresh'), findsOneWidget);
      expect(
          find.text(
              'Select a registered key to sign your model. '
              'Only registered keys can produce store-valid assertions.'),
          findsOneWidget);
    });
  });

  group('ReviewPage', () {
    testWidgets('renders the unsigned review with a selected key',
        (tester) async {
      final st = stateWith(key: 'my-key');
      st.model.snaps = [
        SnapEntry(
            name: 'core24',
            id: 'b' * 32,
            type: SnapType.base,
            defaultChannel: 'stable'),
        SnapEntry(
            name: 'snapd',
            id: 's' * 32,
            type: SnapType.snapd,
            defaultChannel: 'stable'),
      ];
      await pumpPage(tester, ReviewPage(state: st));

      expect(find.text('Review & Sign'), findsOneWidget);
      expect(find.text('Assertion preview'), findsOneWidget);
      // A signing key is selected, so the sign action is offered.
      expect(find.text('Sign model'), findsOneWidget);
    });
  });

  group('SnapsPage', () {
    testWidgets('renders the search field for the model architecture',
        (tester) async {
      final model = ModelAssertion()
        ..architecture = ModelArchitecture.amd64
        ..base = 'core24'
        ..snaps = [
          // base + snapd present -> _seedRequiredSnaps no-ops (no network).
          SnapEntry(
              name: 'snapd',
              id: 's' * 32,
              type: SnapType.snapd,
              defaultChannel: 'stable'),
          SnapEntry(
              name: 'core24',
              id: 'b' * 32,
              type: SnapType.base,
              defaultChannel: 'stable'),
          // No gadget -> _resolveGadgetBase no-ops (no network).
        ];
      await pumpPage(tester, SnapsPage(model: model, onChanged: () {}));

      expect(find.text('Snaps'), findsOneWidget);
      // Global store (no brand store) -> the standard snap search hint.
      expect(find.text('Search snap (amd64)'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });
}
