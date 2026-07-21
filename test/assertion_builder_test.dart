import 'package:flutter_test/flutter_test.dart';
import 'package:ubuntu_core_model_builder/models/model_assertion.dart';
import 'package:ubuntu_core_model_builder/models/snap_entry.dart';
import 'package:ubuntu_core_model_builder/services/assertion_builder.dart';

void main() {
  ModelAssertion validModel() {
    return ModelAssertion()
      ..authorityId = 'abc123'
      ..brandId = 'abc123'
      ..model = 'my-device'
      ..base = 'core24'
      ..snaps = [
        SnapEntry(
          name: 'my-app',
          id: 'x' * 32,
          type: SnapType.app,
          defaultChannel: 'stable',
        ),
        SnapEntry(
          name: 'pc-kernel',
          id: 'y' * 32,
          type: SnapType.kernel,
          defaultChannel: '24/stable',
        ),
        SnapEntry(
          name: 'pc',
          id: 'z' * 32,
          type: SnapType.gadget,
          defaultChannel: '24/stable',
        ),
      ];
  }

  test('builds valid header with ordered snaps', () {
    final header = AssertionBuilder.buildHeader(validModel());
    final snaps = header['snaps'] as List;

    expect(header['type'], 'model');
    expect(header['series'], '16');
    expect(header['grade'], 'signed');
    expect(header['base'], 'core24');
    // kernel & gadget ordered before app
    expect(snaps.first['name'], 'pc-kernel');
    expect(snaps.last['name'], 'my-app');
    expect(header['timestamp'], matches(r'Z$'));
  });

  test('throws when snap ID unresolved', () {
    final model = validModel();
    model.snaps = [
      SnapEntry(
        name: 'pc-kernel',
        id: '',
        type: SnapType.kernel,
        defaultChannel: 'stable',
      ),
      SnapEntry(
        name: 'pc',
        id: 'z' * 32,
        type: SnapType.gadget,
        defaultChannel: 'stable',
      ),
    ];

    expect(
      () => AssertionBuilder.buildHeader(model),
      throwsA(isA<AssertionBuildException>()),
    );
  });

  test('throws when kernel missing', () {
    final model = validModel();
    model.snaps = [
      SnapEntry(
        name: 'pc',
        id: 'z' * 32,
        type: SnapType.gadget,
        defaultChannel: 'stable',
      ),
    ];

    expect(
      () => AssertionBuilder.buildHeader(model),
      throwsA(isA<AssertionBuildException>()),
    );
  });

  test('throws when authority-id differs from brand-id', () {
    final model = validModel()..authorityId = 'different';
    expect(
      () => AssertionBuilder.buildHeader(model),
      throwsA(isA<AssertionBuildException>()),
    );
  });

  test('buildJson produces valid indented JSON', () {
    final json = AssertionBuilder.buildJson(validModel());
    expect(json, contains('"type": "model"'));
    expect(json, contains('"brand-id": "abc123"'));
  });
}
