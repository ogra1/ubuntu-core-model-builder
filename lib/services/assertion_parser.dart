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

  static List<Map<String, String>> parseSnaps(String text) {
    return _parseListOfMaps(text, 'snaps:');
  }

  /// Parses the `validation-sets:` list from signed assertion text into a
  /// list of maps (account-id, name, mode, sequence). Empty if absent.
  static List<Map<String, String>> parseValidationSets(String text) {
    return _parseListOfMaps(text, 'validation-sets:');
  }

  /// Generic parser for a top-level "key:" introducing a list of "- " entries
  /// whose fields are indented "field: value" lines. Used for both snaps and
  /// validation-sets (identical structure).
  static List<Map<String, String>> _parseListOfMaps(
      String text, String topKey) {
    final lines = text.replaceAll('\r\n', '\n').split('\n');

    var i = 0;
    while (i < lines.length) {
      if (lines[i].trimRight() == topKey) break;
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

  static SystemUserAuthorityParse parseSystemUserAuthority(String text) {
    final lines = text.replaceAll('\r\n', '\n').split('\n');

    var i = 0;
    String? sameLineValue;
    while (i < lines.length) {
      final line = lines[i];
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

    if (sameLineValue != null && sameLineValue.isNotEmpty) {
      if (sameLineValue == '*') {
        return const SystemUserAuthorityParse(anyone: true, ids: []);
      }
      return SystemUserAuthorityParse(anyone: false, ids: [sameLineValue]);
    }

    i++;
    final ids = <String>[];
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
      if (trimmed.startsWith('-')) {
        final item = trimmed.substring(1).trim();
        if (item == '*') {
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
