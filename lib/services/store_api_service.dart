import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/store_snap.dart';

/// Queries the public Snap Store API (api.snapcraft.io) with an explicit
/// device architecture, so we can find snaps (e.g. pi-kernel, pi) for an
/// architecture different from the host running this app.
class StoreApiService {
  static const _base = 'https://api.snapcraft.io/v2';

  Map<String, String> _headers(String architecture) => {
        'Snap-Device-Architecture': architecture,
        'Snap-Device-Series': '16',
      };

  /// Search snaps for a given architecture.
  /// results[] shape: name, snap-id, revision:{type}, snap:{title,summary}.
  Future<List<StoreSnap>> findSnaps(String query, String architecture) async {
    final uri = Uri.parse(
      '$_base/snaps/find?q=${Uri.encodeQueryComponent(query)}'
      '&fields=title,summary,type',
    );
    final resp = await http.get(uri, headers: _headers(architecture));
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

  /// Get detailed info (channel map, snap-id, and per-architecture base) for
  /// a snap on a given architecture.
  ///
  /// The channel-map entries carry the interesting per-revision data:
  ///   { "base": "core24",
  ///     "type": "app",
  ///     "channel": { "architecture": <arch>, "name": "...",
  ///                  "track": "...", "risk": "..." } }
  /// The base can differ per architecture/channel, so we read it from the
  /// entries matching the requested architecture.
  Future<StoreSnap> getSnapInfo(String name, String architecture) async {
    final uri = Uri.parse(
      '$_base/snaps/info/${Uri.encodeComponent(name)}'
      '?fields=snap-id,title,summary,type,revision,base',
    );
    final resp = await http.get(uri, headers: _headers(architecture));
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

      // Only consider entries for the requested architecture.
      if (arch != null && arch != architecture) continue;

      // Type (per-revision or per-entry).
      final revision = m['revision'];
      if (revision is Map<String, dynamic>) {
        typeFromMap ??= revision['type'] as String?;
      }
      typeFromMap ??= m['type'] as String?;

      // Base for this architecture. Prefer the value on a stable channel,
      // but fall back to the first arch-matching entry.
      final entryBase = m['base'] as String?;
      if (entryBase != null) {
        baseForArch ??= entryBase;
        final risk = ch?['risk'] as String?;
        if (risk == 'stable') {
          baseStablePreferred ??= entryBase;
        }
      }

      // Channel name in canonical track/risk form.
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
    // A null base on an app snap means the original "core" base: it predates
    // the base concept, so snaps built on it declare no base. Explicit bases
    // like "bare", "core18", "core24" come through non-null and are used
    // as-is. Non-app snaps (base/kernel/gadget/snapd) legitimately have a
    // null base and must NOT be given a fabricated one (e.g. the "bare" and
    // "coreXX" base snaps themselves report base: null).
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
