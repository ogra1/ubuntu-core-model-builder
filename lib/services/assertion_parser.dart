class ParsedAssertion {
  final Map<String, dynamic> headers;
  final String signature;
  final String raw;

  ParsedAssertion({
    required this.headers,
    required this.signature,
    required this.raw,
  });

  String? get type => headers['type'] as String?;
  String? get authorityId => headers['authority-id'] as String?;
  String? get brandId => headers['brand-id'] as String?;
  String? get model => headers['model'] as String?;
  String? get signKeySha3384 => headers['sign-key-sha3-384'] as String?;
}

class AssertionParser {
  static ParsedAssertion parse(String text) {
    final normalized = text.replaceAll('\r\n', '\n');

    // Split headers from the trailing signature block at the first blank line.
    final blankIdx = normalized.indexOf('\n\n');
    if (blankIdx < 0) {
      throw AssertionParseException('Assertion has no signature block.');
    }

    final headerBlock = normalized.substring(0, blankIdx);
    final signature = normalized.substring(blankIdx).trim();

    if (signature.isEmpty) {
      throw AssertionParseException('Empty signature block.');
    }

    final headers = _parseTopLevelHeaders(headerBlock);

    if (headers['type'] == null) {
      throw AssertionParseException('Missing "type" header.');
    }

    return ParsedAssertion(
      headers: headers,
      signature: signature,
      raw: text,
    );
  }

  /// Parses ONLY top-level (column-zero) scalar headers. Indented lines
  /// belong to nested structures (e.g. the "snaps:" list, whose entries
  /// have their own "type:" fields) and must NOT overwrite top-level keys.
  static Map<String, dynamic> _parseTopLevelHeaders(String block) {
    final headers = <String, dynamic>{};

    for (final line in block.split('\n')) {
      if (line.isEmpty) continue;

      // Skip indented lines (they are part of a nested value/list).
      if (line.startsWith(' ') || line.startsWith('\t')) continue;

      final colon = line.indexOf(':');
      if (colon <= 0) continue; // need a non-empty key before ':'

      final key = line.substring(0, colon).trim();
      final value = line.substring(colon + 1).trim();

      // A top-level key with an empty value introduces a nested block
      // (e.g. "snaps:"); record it as present but don't parse the nested
      // content here. We only need scalar headers for verification.
      headers[key] = value;
    }

    return headers;
  }

  /// Extracts the `snaps:` list from a signed assertion's text form.
  /// Returns a list of maps with keys: name, id, type, default-channel, and
  /// optionally presence. Returns an empty list if there is no snaps block.
  ///
  /// Expected format (2-space indent for entries, 4-space for fields):
  ///   snaps:
  ///     -
  ///       default-channel: latest/stable
  ///       id: <id>
  ///       name: <name>
  ///       presence: optional   (optional line)
  ///       type: <type>
  ///     -
  ///       ...
  ///   <next top-level key>:
  static List<Map<String, String>> parseSnaps(String text) {
    final lines = text.replaceAll('\r\n', '\n').split('\n');

    // Find the "snaps:" line at column 0.
    var i = 0;
    while (i < lines.length) {
      if (lines[i].trimRight() == 'snaps:') {
        break;
      }
      i++;
    }
    if (i >= lines.length) return const [];
    i++; // move past "snaps:"

    final result = <Map<String, String>>[];
    Map<String, String>? current;

    while (i < lines.length) {
      final line = lines[i];

      // A non-indented, non-empty line ends the snaps block.
      if (line.isNotEmpty && !line.startsWith(' ') && !line.startsWith('\t')) {
        break;
      }

      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        i++;
        continue;
      }

      if (trimmed == '-') {
        // Start of a new snap entry.
        current = <String, String>{};
        result.add(current);
        i++;
        continue;
      }

      // A "key: value" field line belongs to the current entry.
      final colon = trimmed.indexOf(':');
      if (colon > 0 && current != null) {
        final key = trimmed.substring(0, colon).trim();
        final value = trimmed.substring(colon + 1).trim();
        current[key] = value;
      }
      i++;
    }

    return result;
  }
}

class AssertionParseException implements Exception {
  final String message;
  AssertionParseException(this.message);
  @override
  String toString() => message;
}
