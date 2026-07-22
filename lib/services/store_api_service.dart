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
  /// Observed results[] shape: name, snap-id, revision:{type}, snap:{title,summary}.
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

  /// Get detailed info (channel map + snap-id) for a snap on a given arch.
  ///
  /// NOTE: the info endpoint does NOT accept "channel" as a field. The
  /// "channel-map" is returned by default; each entry carries a "channel"
  /// object with track/risk/architecture. Requested fields (revision, type)
  /// apply to each channel-map entry.
  Future<StoreSnap> getSnapInfo(String name, String architecture) async {
    final uri = Uri.parse(
      '$_base/snaps/info/${Uri.encodeComponent(name)}'
      '?fields=snap-id,title,summary,type,revision',
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
    for (final entry in channelMap) {
      final m = entry as Map<String, dynamic>;
      final revision = m['revision'];
      if (revision is Map<String, dynamic>) {
        typeFromMap ??= revision['type'] as String?;
      }
      typeFromMap ??= m['type'] as String?;

      final ch = m['channel'] as Map<String, dynamic>?;
      if (ch == null) continue;
      final arch = ch['architecture'] as String?;
      if (arch != null && arch != architecture) continue;

      // Prefer an explicit channel name; else compose from track/risk.
      // Always use the canonical "track/risk" form. snap sign requires a
      // track in the model's default-channel (e.g. "latest/stable"), so we
      // must NOT collapse "latest/stable" down to "stable".
      final track = ch['track'] as String? ?? 'latest';
      final risk = ch['risk'] as String? ?? 'stable';
      final chanName = ch['name'] as String?;
      if (chanName != null && chanName.contains('/')) {
        channels.add(chanName);
      } else {
        channels.add('$track/$risk');
      }
    }

    final sorted = channels.toList()..sort(_channelCompare);

    return StoreSnap(
      name: (body['name'] ?? name) as String,
      snapId: (snap['snap-id'] ?? body['snap-id'] ?? '') as String,
      title: snap['title'] as String?,
      summary: snap['summary'] as String?,
      type: (snap['type'] ?? typeFromMap) as String?,
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
