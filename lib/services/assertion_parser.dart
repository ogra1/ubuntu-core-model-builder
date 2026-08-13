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

/// Result of parsing the system-user-authority header from signed assertion
/// text. `anyone` true means the header was '*'. Otherwise [ids] holds the
/// list of account IDs (possibly empty if the header was absent).
class SystemUserAuthorityParse {
  final bool anyone;
  final List<String> ids;
  const SystemUserAuthorityParse({required this.anyone, required this.ids});

  bool get isPresent => anyone || ids.isNotEmpty;
}

class AssertionParser {
  static ParsedAssertion parse(String text) {
    final normalized = text.replaceAll('\r\n', '\n');

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
  /// belong to nested structures (e.g. the "snaps:" list) and must NOT
  /// overwrite top-level keys.
  static Map<String, dynamic> _parseTopLevelHeaders(String block) {
    final headers = <String, dynamic>{};

    for (final line in block.split('\n')) {
      if (line.isEmpty) continue;
      if (line.startsWith(' ') || line.startsWith('\t')) continue;

      final colon = line.indexOf(':');
      if (colon <= 0) continue;

      final key = line.substring(0, colon).trim();
      final value = line.substring(colon + 1).trim();
      headers[key] = value;
    }

    return headers;
  }

  /// Extracts the `snaps:` list from a signed assertion's text form.
  /// Returns a list of maps with keys: name, id, type, default-channel, and
  /// optionally presence. Empty list if there is no snaps block.
  static List<Map<String, String>> parseSnaps(String text) {
    final lines = text.replaceAll('\r\n', '\n').split('\n');

    var i = 0;
    while (i < lines.length) {
      if (lines[i].trimRight() == 'snaps:') break;
      i++;
    }
    if (i >= lines.length) return const [];
    i++;

    final result = <Map<String, String>>[];
    Map<String, String>? current;

    while (i < lines.length) {
      final line = lines[i];

      if (line.isNotEmpty && !line.startsWith(' ') && !line.startsWith('\t')) {
        break;
      }

      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        i++;
        continue;
      }

      if (trimmed == '-') {
        current = <String, String>{};
        result.add(current);
        i++;
        continue;
      }

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

  /// Parses the `system-user-authority` header from signed assertion text.
  ///
  /// Handles two shapes:
  ///   system-user-authority: *          -> anyone
  ///   system-user-authority:
  ///     - id1
  ///     - id2                           -> ids: [id1, id2]
  /// Absent -> anyone: false, ids: [].
  static SystemUserAuthorityParse parseSystemUserAuthority(String text) {
    final lines = text.replaceAll('\r\n', '\n').split('\n');

    var i = 0;
    String? sameLineValue;
    while (i < lines.length) {
      final line = lines[i];
      // Top-level (column-zero) key match.
      if (!line.startsWith(' ') &&
          !line.startsWith('\t') &&
          line.startsWith('system-user-authority:')) {
        sameLineValue =
            line.substring('system-user-authority:'.length).trim();
        break;
      }
      i++;
    }
    if (i >= lines.length) {
      return const SystemUserAuthorityParse(anyone: false, ids: []);
    }

    // Scalar on the same line?
    if (sameLineValue != null && sameLineValue.isNotEmpty) {
      if (sameLineValue == '*') {
        return const SystemUserAuthorityParse(anyone: true, ids: []);
      }
      // A single scalar id on the same line (uncommon but handle it).
      return SystemUserAuthorityParse(anyone: false, ids: [sameLineValue]);
    }

    // Otherwise, collect indented list items on the following lines.
    i++;
    final ids = <String>[];
    while (i < lines.length) {
      final line = lines[i];
      // A non-indented, non-empty line ends the block.
      if (line.isNotEmpty && !line.startsWith(' ') && !line.startsWith('\t')) {
        break;
      }
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        i++;
        continue;
      }
      if (trimmed.startsWith('-')) {
        final item = trimmed.substring(1).trim();
        if (item == '*') {
          // A list containing '*' -> treat as anyone.
          return const SystemUserAuthorityParse(anyone: true, ids: []);
        }
        if (item.isNotEmpty) ids.add(item);
      }
      i++;
    }

    return SystemUserAuthorityParse(anyone: false, ids: ids);
  }
}

class AssertionParseException implements Exception {
  final String message;
  AssertionParseException(this.message);
  @override
  String toString() => message;
}
