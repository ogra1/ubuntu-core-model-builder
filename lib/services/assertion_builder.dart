import 'dart:convert';
import '../models/model_assertion.dart';
import '../models/snap_entry.dart';

class AssertionBuilder {
  static Map<String, dynamic> buildHeader(ModelAssertion model) {
    _validate(model);

    final header = <String, dynamic>{
      'type': 'model',
      'authority-id': model.authorityId,
      'series': model.series ?? '16',
      'brand-id': model.brandId,
      'model': model.model,
      'architecture': model.architecture.name,
    };

    if (model.base != null) {
      header['base'] = model.base;
    }

    header['grade'] = model.grade.name;

    header['snaps'] =
        _orderedSnaps(model.snaps).map(_snapToMap).toList(growable: false);

    header['timestamp'] = _rfc3339Utc(DateTime.now().toUtc());

    header.removeWhere((_, v) => v == null);
    return header;
  }

  static String buildJson(ModelAssertion model) {
    return const JsonEncoder.withIndent('  ').convert(buildHeader(model));
  }

  static List<SnapEntry> _orderedSnaps(List<SnapEntry> snaps) =>
      orderedSnaps(snaps);

  /// Returns [snaps] in the canonical order used in the generated model
  /// file: snapd, base(s), kernel, gadget, then apps; alphabetical within
  /// each group. Exposed so the UI can display snaps in the same order the
  /// signed assertion will contain them.
  static List<SnapEntry> orderedSnaps(List<SnapEntry> snaps) {
    int rank(SnapType t) => switch (t) {
          SnapType.snapd => 0,
          SnapType.base => 1,
          SnapType.kernel => 2,
          SnapType.gadget => 3,
          SnapType.app => 4,
        };
    final sorted = [...snaps]
      ..sort((a, b) {
        final r = rank(a.type).compareTo(rank(b.type));
        return r != 0 ? r : a.name.compareTo(b.name);
      });
    return sorted;
  }

  static Map<String, dynamic> _snapToMap(SnapEntry snap) {
    final map = <String, dynamic>{
      'name': snap.name,
      'id': snap.id,
      'type': snap.type.name,
      'default-channel': snap.defaultChannel,
    };
    // Emit presence for app snaps and for dependent base snaps (both may be
    // optional/required). Infrastructure snaps leave presence null.
    if (snap.presence != null) {
      map['presence'] =
          snap.presence == SnapPresence.required_ ? 'required' : 'optional';
    }
    map.removeWhere((_, v) => v == null || (v is String && v.isEmpty));
    return map;
  }

  static String _rfc3339Utc(DateTime dt) {
    final iso = dt.toIso8601String();
    final withoutFraction = iso.replaceFirst(RegExp(r'\.\d+'), '');
    return withoutFraction.endsWith('Z')
        ? withoutFraction
        : '${withoutFraction}Z';
  }

  static void _validate(ModelAssertion model) {
    final errors = <String>[];

    if (_isBlank(model.authorityId)) {
      errors.add('authority-id is missing (sign in to your store account).');
    }
    if (_isBlank(model.brandId)) {
      errors.add('brand-id is missing (sign in to your store account).');
    }
    if (model.authorityId != model.brandId) {
      errors.add('authority-id must equal brand-id for a self-signed model.');
    }
    if (_isBlank(model.model)) {
      errors.add('model name is required.');
    } else if (!RegExp(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?$')
        .hasMatch(model.model!)) {
      errors.add('model name must be lowercase alphanumeric with dashes.');
    }
    if (_isBlank(model.base)) {
      errors.add('base is required (e.g. core22, core24).');
    }

    for (final snap in model.snaps) {
      if (_isBlank(snap.id)) {
        errors.add('Snap "${snap.name}" has no resolved snap ID.');
      }
    }

    final hasKernel = model.snaps.any((s) => s.type == SnapType.kernel);
    final hasGadget = model.snaps.any((s) => s.type == SnapType.gadget);
    if (!hasKernel) errors.add('A kernel snap is required.');
    if (!hasGadget) errors.add('A gadget snap is required.');

    if (errors.isNotEmpty) {
      throw AssertionBuildException(errors);
    }
  }

  static bool _isBlank(String? s) => s == null || s.trim().isEmpty;
}

class AssertionBuildException implements Exception {
  final List<String> errors;
  AssertionBuildException(this.errors);

  @override
  String toString() =>
      'Cannot build assertion:\n${errors.map((e) => '  - $e').join('\n')}';
}
