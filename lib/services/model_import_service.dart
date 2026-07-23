import 'dart:convert';
import 'dart:io';

import '../models/model_assertion.dart';
import '../models/snap_entry.dart';
import 'assertion_parser.dart';
import 'store_api_service.dart';

class ImportResult {
  final ModelAssertion model;
  final String? importedBrandId;
  final List<String> warnings;

  ImportResult({
    required this.model,
    required this.importedBrandId,
    this.warnings = const [],
  });
}

class ModelImportException implements Exception {
  final String message;
  ModelImportException(this.message);
  @override
  String toString() => message;
}

class ModelImportService {
  final StoreApiService _store;
  ModelImportService({StoreApiService? store})
      : _store = store ?? StoreApiService();

  /// Imports a model from a file. Detects unsigned JSON vs. signed assertion
  /// text by content. Returns an editable ModelAssertion.
  ///
  /// [reResolveAppBase] looks up each app snap's base from the store so
  /// dependent-base presence coupling works after import. Costs one network
  /// call per app snap (parallelised).
  Future<ImportResult> importFromFile(
    String path, {
    bool reResolveAppBase = true,
  }) async {
    final raw = await File(path).readAsString();
    final trimmed = raw.trimLeft();

    Map<String, dynamic> headerMap;
    List<Map<String, String>> snapMaps;

    if (trimmed.startsWith('{')) {
      // Unsigned JSON.
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw ModelImportException('JSON is not a model object.');
      }
      headerMap = decoded;
      final rawSnaps = (decoded['snaps'] as List<dynamic>?) ?? const [];
      snapMaps = rawSnaps
          .whereType<Map>()
          .map((m) => m.map(
              (k, v) => MapEntry(k.toString(), v?.toString() ?? '')))
          .toList();
    } else {
      // Signed .model assertion text: parse scalar headers + snaps block.
      final ParsedAssertion parsed;
      try {
        parsed = AssertionParser.parse(raw);
      } on AssertionParseException catch (e) {
        throw ModelImportException('Not a valid model file: ${e.message}');
      }
      if (parsed.type != 'model') {
        throw ModelImportException(
            'File is a "${parsed.type}" assertion, not a model.');
      }
      headerMap = parsed.headers;
      snapMaps = AssertionParser.parseSnaps(raw);
    }

    return _buildResult(headerMap, snapMaps,
        reResolveAppBase: reResolveAppBase);
  }

  Future<ImportResult> _buildResult(
    Map<String, dynamic> h,
    List<Map<String, String>> snapMaps, {
    required bool reResolveAppBase,
  }) async {
    final warnings = <String>[];

    final model = ModelAssertion()
      ..type = (h['type']?.toString()) ?? 'model'
      ..authorityId = h['authority-id']?.toString()
      ..brandId = h['brand-id']?.toString()
      ..series = (h['series']?.toString()) ?? '16'
      ..model = h['model']?.toString()
      ..architecture = _parseArch(h['architecture']?.toString(), warnings)
      ..base = h['base']?.toString()
      ..grade = _parseGrade(h['grade']?.toString(), warnings);

    final arch = model.architecture.name;

    final entries = <SnapEntry>[];
    for (final m in snapMaps) {
      final name = m['name'];
      if (name == null || name.isEmpty) continue;
      final type = _parseType(m['type']);
      // A base snap that is not the model's own base can only have gotten
      // into the model because an app pulled it in. Mark such bases as
      // autoAdded so the Snaps page auto-removes them when their last
      // dependent app is removed, matching freshly built models.
      final isDependentBase =
          type == SnapType.base && name != model.base;
      entries.add(SnapEntry(
        name: name,
        id: m['id'] ?? '',
        type: type,
        defaultChannel: m['default-channel'] ?? 'latest/stable',
        presence: _parsePresence(m['presence']),
        autoAdded: isDependentBase,
      ));
    }

    if (reResolveAppBase) {
      // Parallelise the per-app store lookups.
      final futures = <Future<void>>[];
      for (var i = 0; i < entries.length; i++) {
        final e = entries[i];
        if (e.type != SnapType.app) continue;
        futures.add(() async {
          try {
            final info = await _store.getSnapInfo(e.name, arch);
            entries[i] = e.copyWith(appBase: info.base);
          } catch (err) {
            warnings.add(
                'Could not resolve base for "${e.name}"; dependent base '
                'coupling may be inexact for it.');
          }
        }());
      }
      await Future.wait(futures);
    }

    model.snaps = entries;

    return ImportResult(
      model: model,
      importedBrandId: model.brandId,
      warnings: warnings,
    );
  }

  ModelArchitecture _parseArch(String? v, List<String> warnings) {
    for (final a in ModelArchitecture.values) {
      if (a.name == v) return a;
    }
    if (v != null) {
      warnings.add('Unknown architecture "$v"; defaulting to amd64.');
    }
    return ModelArchitecture.amd64;
  }

  ModelGrade _parseGrade(String? v, List<String> warnings) {
    for (final g in ModelGrade.values) {
      if (g.name == v) return g;
    }
    if (v != null) {
      warnings.add('Unknown grade "$v"; defaulting to signed.');
    }
    return ModelGrade.signed;
  }

  SnapType _parseType(String? v) {
    switch (v) {
      case 'kernel':
        return SnapType.kernel;
      case 'gadget':
        return SnapType.gadget;
      case 'base':
        return SnapType.base;
      case 'snapd':
        return SnapType.snapd;
      default:
        return SnapType.app;
    }
  }

  SnapPresence? _parsePresence(String? v) {
    switch (v) {
      case 'required':
        return SnapPresence.required_;
      case 'optional':
        return SnapPresence.optional;
      default:
        return null;
    }
  }
}
