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

/// A parsed snap entry: flat scalar fields plus a components map
/// (name -> presence).
class ParsedSnap {
  final Map<String, String> fields;
  final Map<String, String> components; // name -> presence
  ParsedSnap(this.fields, this.components);
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

  static int _indentOf(String line) {
    var n = 0;
    while (n < line.length && line[n] == ' ') {
      n++;
    }
    return n;
  }

  /// Parses the `snaps:` list, including each entry's nested `components:`
  /// block. Entry fields are at 4-space indent; components names at 6, their
  /// presence at 8 (per the assertion format).
  static List<ParsedSnap> parseSnaps(String text) {
    final lines = text.replaceAll('\r\n', '\n').split('\n');

    var i = 0;
    while (i < lines.length) {
      if (lines[i].trimRight() == 'snaps:') break;
      i++;
    }
    if (i >= lines.length) return const [];
    i++;

    final result = <ParsedSnap>[];
    Map<String, String>? fields;
    Map<String, String>? components;

    void startEntry() {
      fields = <String, String>{};
      components = <String, String>{};
      result.add(ParsedSnap(fields!, components!));
    }

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

      final indent = _indentOf(line);

      // Entry start "  -" (indent 2).
      if (trimmed == '-') {
        startEntry();
        i++;
        continue;
      }

      if (fields == null) {
        // Field before any entry start; skip defensively.
        i++;
        continue;
      }

      // A "components:" field (indent 4, empty value) introduces the nested
      // components block.
      if (indent <= 4 && trimmed == 'components:') {
        i++;
        // Parse nested component entries until indentation returns to <= 4
        // (next entry field) or the block ends.
        while (i < lines.length) {
          final cl = lines[i];
          if (cl.isNotEmpty &&
              !cl.startsWith(' ') &&
              !cl.startsWith('\t')) {
            break; // end of snaps block
          }
          final ct = cl.trim();
          if (ct.isEmpty) {
            i++;
            continue;
          }
          final ci = _indentOf(cl);
          if (ci <= 4) break; // back to entry-field level or entry start
          // Component name line "      <name>:" (indent 6).
          if (ct.endsWith(':') && ci >= 6 && ci < 8) {
            final compName = ct.substring(0, ct.length - 1).trim();
            // Look ahead for its "presence:" line (indent 8).
            var presence = 'optional';
            var j = i + 1;
            while (j < lines.length) {
              final pl = lines[j];
              final pt = pl.trim();
              if (pt.isEmpty) {
                j++;
                continue;
              }
              final pi = _indentOf(pl);
              if (pi < 8) break; // no deeper -> done with this component
              if (pt.startsWith('presence:')) {
                presence = pt.substring('presence:'.length).trim();
              }
              j++;
              // Only consume the immediate deeper lines for this component.
              // Stop if we hit the next component (indent 6).
              if (j < lines.length) {
                final nl = lines[j];
                if (nl.trim().isNotEmpty && _indentOf(nl) <= 6) break;
              }
            }
            if (compName.isNotEmpty) {
              components![compName] = presence;
            }
            i = j;
            continue;
          }
          i++;
        }
        continue;
      }

      // A normal "key: value" entry field (indent 4).
      final colon = trimmed.indexOf(':');
      if (colon > 0) {
        final key = trimmed.substring(0, colon).trim();
        final value = trimmed.substring(colon + 1).trim();
        fields![key] = value;
      }
      i++;
    }

    return result;
  }

  static List<Map<String, String>> parseValidationSets(String text) {
    return _parseListOfMaps(text, 'validation-sets:');
  }

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

  static List<String> parseStringList(String text, String topKey) {
    final lines = text.replaceAll('\r\n', '\n').split('\n');
    final keyLine = topKey.endsWith(':') ? topKey : '$topKey:';

    var i = 0;
    String? sameLine;
    while (i < lines.length) {
      final line = lines[i];
      if (!line.startsWith(' ') &&
          !line.startsWith('\t') &&
          line.startsWith(keyLine)) {
        sameLine = line.substring(keyLine.length).trim();
        break;
      }
      i++;
    }
    if (i >= lines.length) return const [];

    if (sameLine != null && sameLine.isNotEmpty) {
      return [sameLine];
    }

    i++;
    final items = <String>[];
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
        if (item.isNotEmpty) items.add(item);
      }
      i++;
    }
    return items;
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
