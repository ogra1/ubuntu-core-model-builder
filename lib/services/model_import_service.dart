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

    // Reject model types this app does not support editing. We build
    // grade-based Ubuntu Core models (with a base, grade, and snaps list).
    // Classic and legacy UC16/18 models have different prerequisites.
    final classicVal = h['classic']?.toString().toLowerCase();
    if (classicVal == 'true') {
      throw ModelImportException(
        'This is a classic model (classic: true). This app edits Ubuntu '
        'Core grade models, which have different prerequisites (kernel, '
        'gadget, base, snapd). Classic models are not supported.',
      );
    }
    // Positive detection of legacy UC16/18 models: they carry top-level
    // scalar "kernel:" and/or "gadget:" headers (as strings like
    // "pc-kernel=18"), whereas grade models list kernel/gadget only inside
    // the nested "snaps:" block. A top-level kernel/gadget scalar therefore
    // means a legacy model.
    final topLevelKernel = _isScalarString(h['kernel']);
    final topLevelGadget = _isScalarString(h['gadget']);
    if (topLevelKernel || topLevelGadget) {
      throw ModelImportException(
        'This looks like a legacy UC16/18 model: it declares top-level '
        '"kernel"/"gadget" fields instead of a grade-based "snaps" list. '
        'This app builds modern Ubuntu Core grade models and does not '
        'support the legacy format.',
      );
    }

    // Fallback heuristic: a grade model always has both a grade and a base.
    final hasGrade = (h['grade']?.toString().trim().isNotEmpty) ?? false;
    final hasBase = (h['base']?.toString().trim().isNotEmpty) ?? false;
    if (!hasGrade && !hasBase) {
      throw ModelImportException(
        'This model is not a grade-based Ubuntu Core model (no "grade" or '
        '"base" header, and no legacy kernel/gadget fields). The format is '
        'not supported.',
      );
    }

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

  /// True if [v] is a non-empty scalar string (i.e. a top-level string
  /// header value), as opposed to a nested list/map (which the parser
  /// represents as a List) or null.
  bool _isScalarString(dynamic v) {
    return v is String && v.trim().isNotEmpty;
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
