import 'dart:convert';
import 'dart:io';
import '../models/store_snap.dart';

class SnapdService {
  static const _socketPath = '/run/snapd.socket';

  Future<List<StoreSnap>> findSnaps(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];

    final seen = <String>{};
    final merged = <StoreSnap>[];

    // 1. Exact name lookup first.
    try {
      final exact = await _findByName(q);
      for (final s in exact) {
        if (seen.add(s.name)) merged.add(s);
      }
    } catch (e) {
      // Surface to console for debugging; don't crash the UI.
      // ignore: avoid_print
      print('snapd name lookup failed for "$q": $e');
    }

    // 2. Fuzzy search.
    try {
      final fuzzy = await _findByQuery(q);
      for (final s in fuzzy) {
        if (seen.add(s.name)) merged.add(s);
      }
    } catch (e) {
      // ignore: avoid_print
      print('snapd query search failed for "$q": $e');
    }

    return merged;
  }

  Future<List<StoreSnap>> _findByQuery(String query) async {
    final response = await _request(
      'GET',
      '/v2/find?q=${Uri.encodeQueryComponent(query)}',
    );
    final result = response['result'] as List<dynamic>? ?? [];
    return result
        .map((e) => StoreSnap.fromSnapdJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<StoreSnap>> _findByName(String name) async {
    final response = await _request(
      'GET',
      '/v2/find?name=${Uri.encodeQueryComponent(name)}',
    );
    final result = response['result'];
    if (result is! List) return [];
    return result
        .map((e) => StoreSnap.fromSnapdJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<StoreSnap> getSnapInfo(String name) async {
    final response = await _request(
      'GET',
      '/v2/find?name=${Uri.encodeQueryComponent(name)}',
    );
    final result = response['result'] as List<dynamic>? ?? [];
    if (result.isEmpty) {
      throw Exception('Snap "$name" not found in store');
    }
    final data = result.first as Map<String, dynamic>;

    final channels = <String>[];
    if (data['channels'] is Map) {
      channels.addAll((data['channels'] as Map).keys.cast<String>());
    }
    channels.sort(_channelCompare);

    return StoreSnap(
      name: data['name'] as String,
      snapId: (data['id'] ?? data['snap-id'] ?? '') as String,
      title: data['title'] as String?,
      summary: data['summary'] as String?,
      type: data['type'] as String?,
      channels: channels,
    );
  }

  static int _channelCompare(String a, String b) {
    final (ta, ra) = _splitChannel(a);
    final (tb, rb) = _splitChannel(b);

    int trackRank(String t) {
      if (t == 'latest') return 1000000;
      final n = int.tryParse(t);
      return n ?? -1;
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

  static (String track, String risk) _splitChannel(String channel) {
    final parts = channel.split('/');
    if (parts.length == 1) return ('latest', parts[0]);
    return (parts[0], parts.sublist(1).join('/'));
  }

  /// Performs an HTTP/1.1 request over the snapd unix socket and returns the
  /// decoded JSON body. Reads at the byte level and handles both
  /// Content-Length and chunked transfer encodings correctly.
  Future<Map<String, dynamic>> _request(String method, String path) async {
    final socket = await Socket.connect(
      InternetAddress(_socketPath, type: InternetAddressType.unix),
      0,
    );

    final request = '$method $path HTTP/1.1\r\n'
        'Host: localhost\r\n'
        'Accept: application/json\r\n'
        'Connection: close\r\n\r\n';
    socket.write(request);

    // Collect ALL bytes (Connection: close means the server closes when done).
    final bytes = <int>[];
    await for (final chunk in socket) {
      bytes.addAll(chunk);
    }
    socket.destroy();

    // Split headers from body at the first CRLF CRLF, byte-wise.
    final sep = _indexOfCrlfCrlf(bytes);
    if (sep < 0) {
      throw const FormatException('Malformed HTTP response (no header end).');
    }
    final headerBytes = bytes.sublist(0, sep);
    final bodyBytes = bytes.sublist(sep + 4);

    final headerText = ascii.decode(headerBytes, allowInvalid: true);
    final isChunked =
        headerText.toLowerCase().contains('transfer-encoding: chunked');

    final List<int> decodedBody =
        isChunked ? _dechunk(bodyBytes) : bodyBytes;

    // Decode as UTF-8 only after reassembling the full byte body.
    final jsonText = utf8.decode(decodedBody, allowMalformed: true);
    final decoded = jsonDecode(jsonText);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Unexpected JSON shape from snapd.');
    }
    return decoded;
  }

  int _indexOfCrlfCrlf(List<int> data) {
    // 13 10 13 10 == \r \n \r \n
    for (var i = 0; i + 3 < data.length; i++) {
      if (data[i] == 13 &&
          data[i + 1] == 10 &&
          data[i + 2] == 13 &&
          data[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  /// Decodes an HTTP chunked-transfer body at the byte level.
  List<int> _dechunk(List<int> data) {
    final out = <int>[];
    var i = 0;

    List<int> readLine() {
      final line = <int>[];
      while (i + 1 < data.length) {
        if (data[i] == 13 && data[i + 1] == 10) {
          i += 2;
          return line;
        }
        line.add(data[i]);
        i++;
      }
      // No trailing CRLF; consume the rest.
      while (i < data.length) {
        line.add(data[i]);
        i++;
      }
      return line;
    }

    while (i < data.length) {
      final sizeLine = ascii.decode(readLine(), allowInvalid: true).trim();
      if (sizeLine.isEmpty) continue;
      // Chunk size may have extensions after ';'.
      final sizeToken = sizeLine.split(';').first.trim();
      final size = int.tryParse(sizeToken, radix: 16);
      if (size == null) break;
      if (size == 0) break; // last chunk
      final end = i + size;
      if (end > data.length) {
        // Truncated; take what we can.
        out.addAll(data.sublist(i));
        break;
      }
      out.addAll(data.sublist(i, end));
      i = end;
      // Skip the trailing CRLF after the chunk data.
      if (i + 1 < data.length && data[i] == 13 && data[i + 1] == 10) {
        i += 2;
      }
    }
    return out;
  }
}
