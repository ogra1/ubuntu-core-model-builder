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

  Future<ImportResult> importFromFile(
    String path, {
    bool reResolveAppBase = true,
  }) async {
    final raw = await File(path).readAsString();
    final trimmed = raw.trimLeft();

    Map<String, dynamic> headerMap;
    List<Map<String, String>> snapMaps;
    // system-user-authority parsed from the appropriate source.
    SystemUserAuthorityParse suaParse;
    List<Map<String, String>> vsetMaps;

    if (trimmed.startsWith('{')) {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw ModelImportException('JSON is not a model object.');
      }
      headerMap = decoded;
      final rawSnaps = (decoded['snaps'] as List<dynamic>?) ?? const [];
      snapMaps = rawSnaps
          .whereType<Map>()
          .map((m) =>
              m.map((k, v) => MapEntry(k.toString(), v?.toString() ?? '')))
          .toList();
      // From JSON: the value is a real array or the string '*'.
      suaParse = _suaFromJson(decoded['system-user-authority']);
      vsetMaps = _vsetsFromJson(decoded['validation-sets']);
    } else {
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
      // From signed .model: dedicated block parser (handles multi-id lists).
      suaParse = AssertionParser.parseSystemUserAuthority(raw);
      vsetMaps = AssertionParser.parseValidationSets(raw);
    }

    return _buildResult(headerMap, snapMaps, suaParse, vsetMaps,
        reResolveAppBase: reResolveAppBase);
  }

  List<Map<String, String>> _vsetsFromJson(dynamic v) {
    if (v is! List) return const [];
    return v.whereType<Map>().map((m) {
      final mm = m.cast<String, dynamic>();
      return {
        'account-id': mm['account-id']?.toString() ?? '',
        'name': mm['name']?.toString() ?? '',
        'mode': mm['mode']?.toString() ?? '',
        if (mm['sequence'] != null) 'sequence': mm['sequence'].toString(),
      };
    }).toList();
  }

  SystemUserAuthorityParse _suaFromJson(dynamic v) {
    if (v is String && v.trim() == '*') {
      return const SystemUserAuthorityParse(anyone: true, ids: []);
    }
    if (v is List) {
      final ids = v
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
      if (ids.contains('*')) {
        return const SystemUserAuthorityParse(anyone: true, ids: []);
      }
      return SystemUserAuthorityParse(anyone: false, ids: ids);
    }
    if (v is String && v.trim().isNotEmpty) {
      return SystemUserAuthorityParse(anyone: false, ids: [v.trim()]);
    }
    return const SystemUserAuthorityParse(anyone: false, ids: []);
  }

  Future<ImportResult> _buildResult(
    Map<String, dynamic> h,
    List<Map<String, String>> snapMaps,
    SystemUserAuthorityParse suaParse,
    List<Map<String, String>> vsetMaps, {
    required bool reResolveAppBase,
  }) async {
    final warnings = <String>[];

    final classicVal = h['classic']?.toString().toLowerCase();
    if (classicVal == 'true') {
      throw ModelImportException(
        'This is a classic model (classic: true). This app edits Ubuntu '
        'Core grade models, which have different prerequisites (kernel, '
        'gadget, base, snapd). Classic models are not supported.',
      );
    }

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

    final hasGrade = (h['grade']?.toString().trim().isNotEmpty) ?? false;
    final hasBase = (h['base']?.toString().trim().isNotEmpty) ?? false;
    if (!hasGrade && !hasBase) {
      throw ModelImportException(
        'This model is not a grade-based Ubuntu Core model (no "grade" or '
        '"base" header, and no legacy kernel/gadget fields). The format is '
        'not supported.',
      );
    }

    final model = ModelAssertion()
      ..type = (h['type']?.toString()) ?? 'model'
      ..authorityId = h['authority-id']?.toString()
      ..brandId = h['brand-id']?.toString()
      ..series = (h['series']?.toString()) ?? '16'
      ..model = h['model']?.toString()
      ..architecture = _parseArch(h['architecture']?.toString(), warnings)
      ..base = h['base']?.toString()
      ..grade = _parseGrade(h['grade']?.toString(), warnings)
      ..store = h['store']?.toString();

    // Apply the parsed system-user-authority.
    if (suaParse.anyone) {
      model.systemUserAuthorityMode = SystemUserAuthorityMode.anyone;
    } else if (suaParse.ids.isNotEmpty) {
      model.systemUserAuthorityMode = SystemUserAuthorityMode.specificIds;
      model.systemUserAuthorityIds = suaParse.ids;
    } else {
      model.systemUserAuthorityMode = SystemUserAuthorityMode.brandOnly;
    }

    // validation-sets. An absent account-id means "use the brand-id", so we
    // fill it in from the model's brand-id for display/round-trip.
    final brandForVsets = model.brandId?.trim() ?? '';
    model.validationSets = vsetMaps.map((m) {
      final seqStr = m['sequence'];
      final acct = (m['account-id'] ?? '').trim();
      return ValidationSetRef(
        accountId: acct.isEmpty ? brandForVsets : acct,
        name: m['name'] ?? '',
        mode: (m['mode'] == null || m['mode']!.isEmpty) ? 'enforce' : m['mode']!,
        sequence: (seqStr != null && seqStr.isNotEmpty)
            ? int.tryParse(seqStr)
            : null,
      );
    }).where((v) => v.name.isNotEmpty).toList();

    // storage-safety (top-level scalar)
    switch (h['storage-safety']?.toString()) {
      case 'encrypted':
        model.storageSafety = StorageSafety.encrypted;
        break;
      case 'prefer-encrypted':
        model.storageSafety = StorageSafety.preferEncrypted;
        break;
      case 'prefer-unencrypted':
        model.storageSafety = StorageSafety.preferUnencrypted;
        break;
      default:
        model.storageSafety = StorageSafety.unset;
    }

    final arch = model.architecture.name;

    final entries = <SnapEntry>[];
    for (final m in snapMaps) {
      final name = m['name'];
      if (name == null || name.isEmpty) continue;
      final type = _parseType(m['type']);
      final isDependentBase = type == SnapType.base && name != model.base;
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
      final futures = <Future<void>>[];
      for (var i = 0; i < entries.length; i++) {
        final e = entries[i];
        if (e.type != SnapType.app) continue;
        futures.add(() async {
          try {
            // Resolve the base for the app's SELECTED channel, since a snap
            // can have different bases per channel (e.g. console-conf:
            // 24/* => core24, 26/* => core26). Falls back to the
            // channel-agnostic base if the per-channel lookup returns null.
            final perChannel = await _store.getBaseForChannel(
                e.name, arch, e.defaultChannel);
            if (perChannel != null) {
              entries[i] = e.copyWith(appBase: perChannel);
            } else {
              final info = await _store.getSnapInfo(e.name, arch);
              entries[i] = e.copyWith(appBase: info.base);
            }
          } catch (_) {
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

  bool _isScalarString(dynamic v) => v is String && v.trim().isNotEmpty;

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
