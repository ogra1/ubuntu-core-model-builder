import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/store_snap.dart';

/// Queries the public Snap Store API (api.snapcraft.io) with an explicit
/// device architecture and, optionally, a brand store ID so brand-store snaps
/// are returned.
class StoreApiService {
  static const _base = 'https://api.snapcraft.io/v2';

  static const prefCachedStores = 'metadata.cachedStores';

  Map<String, String> _headers(String architecture, String? storeId) {
    final h = <String, String>{
      'Snap-Device-Architecture': architecture,
      'Snap-Device-Series': '16',
    };
    // Scope to a brand store when one is given (and not the global store).
    if (storeId != null && storeId.isNotEmpty && storeId != 'ubuntu') {
      h['Snap-Device-Store'] = storeId;
    }
    return h;
  }

  Future<List<StoreSnap>> findSnaps(String query, String architecture,
      {String? storeId}) async {
    final uri = Uri.parse(
      '$_base/snaps/find?q=${Uri.encodeQueryComponent(query)}'
      '&fields=title,summary,type',
    );
    final resp = await http.get(uri, headers: _headers(architecture, storeId));
    if (resp.statusCode != 200) {
      throw Exception('Store search failed (${resp.statusCode}): ${resp.body}');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final results = body['results'] as List<dynamic>? ?? [];
    final out = <StoreSnap>[];
    for (final e in results) {
      final m = e as Map<String, dynamic>;
      final snap = m['snap'] as Map<String, dynamic>? ?? const {};
      final revision = m['revision'] as Map<String, dynamic>? ?? const {};
      final name = (m['name'] ?? snap['name'] ?? '') as String;
      if (name.isEmpty) continue;
      out.add(StoreSnap(
        name: name,
        snapId: (m['snap-id'] ?? snap['snap-id'] ?? '') as String,
        title: snap['title'] as String?,
        summary: snap['summary'] as String?,
        type: (revision['type'] ?? snap['type']) as String?,
      ));
    }
    return out;
  }

  Future<StoreSnap> getSnapInfo(String name, String architecture,
      {String? storeId}) async {
    final uri = Uri.parse(
      '$_base/snaps/info/${Uri.encodeComponent(name)}'
      '?fields=snap-id,title,summary,type,revision,base',
    );
    final resp = await http.get(uri, headers: _headers(architecture, storeId));
    if (resp.statusCode != 200) {
      throw Exception(
          'Store info for "$name" failed (${resp.statusCode}): ${resp.body}');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;

    final snap = body['snap'] as Map<String, dynamic>? ?? const {};
    final channelMap = body['channel-map'] as List<dynamic>? ?? [];

    final channels = <String>{};
    String? typeFromMap;
    String? baseForArch;
    String? baseStablePreferred;

    for (final entry in channelMap) {
      final m = entry as Map<String, dynamic>;
      final ch = m['channel'] as Map<String, dynamic>?;
      final arch = ch?['architecture'] as String?;
      if (arch != null && arch != architecture) continue;

      final revision = m['revision'];
      if (revision is Map<String, dynamic>) {
        typeFromMap ??= revision['type'] as String?;
      }
      typeFromMap ??= m['type'] as String?;

      final entryBase = m['base'] as String?;
      if (entryBase != null) {
        baseForArch ??= entryBase;
        final risk = ch?['risk'] as String?;
        if (risk == 'stable') {
          baseStablePreferred ??= entryBase;
        }
      }

      if (ch != null) {
        final track = ch['track'] as String? ?? 'latest';
        final risk = ch['risk'] as String? ?? 'stable';
        final chanName = ch['name'] as String?;
        if (chanName != null && chanName.contains('/')) {
          channels.add(chanName);
        } else {
          channels.add('$track/$risk');
        }
      }
    }

    final sorted = channels.toList()..sort(_channelCompare);
    var resolvedBase = baseStablePreferred ?? baseForArch;

    final resolvedType = (snap['type'] ?? typeFromMap) as String?;
    if (resolvedBase == null &&
        (resolvedType == null || resolvedType == 'app')) {
      resolvedBase = 'core';
    }

    return StoreSnap(
      name: (body['name'] ?? name) as String,
      snapId: (snap['snap-id'] ?? body['snap-id'] ?? '') as String,
      title: snap['title'] as String?,
      summary: snap['summary'] as String?,
      type: resolvedType,
      base: resolvedBase,
      channels: sorted,
    );
  }

  Future<List<({String channel, String? base})>> getChannelsWithBases(
      String name, String architecture,
      {String? storeId}) async {
    final uri = Uri.parse(
      '$_base/snaps/info/${Uri.encodeComponent(name)}'
      '?fields=base,revision',
    );
    final resp = await http.get(uri, headers: _headers(architecture, storeId));
    if (resp.statusCode != 200) return const [];
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final channelMap = body['channel-map'] as List<dynamic>? ?? const [];

    final seen = <String>{};
    final result = <({String channel, String? base})>[];
    for (final entry in channelMap) {
      final m = entry as Map<String, dynamic>;
      final ch = m['channel'] as Map<String, dynamic>?;
      if (ch == null) continue;
      final arch = ch['architecture'] as String?;
      if (arch != null && arch != architecture) continue;

      final track = ch['track'] as String? ?? 'latest';
      final risk = ch['risk'] as String? ?? 'stable';
      final chanName = ch['name'] as String?;
      // Always use canonical 'track/risk' (including 'latest/stable') to
      // stay consistent with getSnapInfo's defaultChannel and
      // getBaseForChannel's matching.
      final canonical = (chanName != null && chanName.contains('/'))
          ? chanName
          : '$track/$risk';

      if (seen.add(canonical)) {
        result.add((channel: canonical, base: m['base'] as String?));
      }
    }
    result.sort((a, b) => _channelCompare(a.channel, b.channel));
    return result;
  }

  Future<String?> getBaseForChannel(
      String name, String architecture, String channel,
      {String? storeId}) async {
    final uri = Uri.parse(
      '$_base/snaps/info/${Uri.encodeComponent(name)}'
      '?fields=base,revision',
    );
    final resp = await http.get(uri, headers: _headers(architecture, storeId));
    if (resp.statusCode != 200) return null;
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final channelMap = body['channel-map'] as List<dynamic>? ?? const [];

    for (final entry in channelMap) {
      final m = entry as Map<String, dynamic>;
      final ch = m['channel'] as Map<String, dynamic>?;
      if (ch == null) continue;
      final arch = ch['architecture'] as String?;
      if (arch != null && arch != architecture) continue;

      final track = ch['track'] as String? ?? 'latest';
      final risk = ch['risk'] as String? ?? 'stable';
      final nameField = ch['name'] as String?;

      // Build all the forms this channel could be referenced by, so we match
      // whatever defaultChannel we stored. Note getSnapInfo stores the
      // canonical 'track/risk' form (e.g. 'latest/stable'), so we MUST accept
      // that here — the previous code collapsed 'latest/<risk>' to bare
      // '<risk>' and therefore missed 'latest/stable'.
      final canonical = '$track/$risk';           // e.g. latest/stable
      final bareRisk = risk;                        // e.g. stable
      final composedName =
          (nameField != null && nameField.contains('/'))
              ? nameField
              : canonical;

      if (channel == canonical ||
          channel == bareRisk ||
          channel == nameField ||
          channel == composedName) {
        return m['base'] as String?;
      }
    }
    return null;
  }

  static int _channelCompare(String a, String b) {
    final pa = a.split('/');
    final pb = b.split('/');
    final ta = pa.length > 1 ? pa[0] : 'latest';
    final tb = pb.length > 1 ? pb[0] : 'latest';
    final ra = pa.last;
    final rb = pb.last;

    int trackRank(String t) {
      if (t == 'latest') return 1000000;
      return int.tryParse(t) ?? -1;
    }

    final tr = trackRank(tb).compareTo(trackRank(ta));
    if (tr != 0) return tr;

    int riskRank(String r) => switch (r) {
          'stable' => 0,
          'candidate' => 1,
          'beta' => 2,
          'edge' => 3,
          _ => 4,
        };
    return riskRank(ra).compareTo(riskRank(rb));
  }
}
