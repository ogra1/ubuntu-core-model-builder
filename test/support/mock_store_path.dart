import 'dart:convert';
import 'dart:io';

/// Resolves the shared mock-store script. It now ships with the
/// `snapstore_auth` package (`tool/mock_store.py`) rather than living in this
/// repo, so the Rust-backed test suites locate it through the package's
/// resolved path.
///
/// Resolution order:
///   1. `$SNAPSTORE_AUTH_LOCAL` — an explicit local checkout of the shared
///      repo (also used for development via `dependency_overrides`);
///   2. the `snapstore_auth` entry in `.dart_tool/package_config.json`
///      (works for a git dependency, a local path dependency, or a pub-cache
///      git checkout);
///   3. a scan of the pub cache git checkouts (`$PUB_CACHE/git/`).
///
/// Throws [StateError] with an actionable message if it can't be found.
String mockStorePath() {
  final local = Platform.environment['SNAPSTORE_AUTH_LOCAL'];
  if (local != null && local.isNotEmpty) {
    final p = File('$local/tool/mock_store.py');
    if (p.existsSync()) return p.path;
  }

  final fromConfig = _fromPackageConfig();
  if (fromConfig != null) return fromConfig;

  final pubCache =
      Platform.environment['PUB_CACHE'] ?? '${_home()}/.pub-cache';
  final git = Directory('$pubCache/git');
  if (git.existsSync()) {
    for (final e in git.listSync()) {
      if (e is! Directory) continue;
      final name = e.path.split(Platform.pathSeparator).last;
      if (!name.startsWith('snapstore-auth')) continue;
      final p = File('${e.path}/tool/mock_store.py');
      if (p.existsSync()) return p.path;
    }
  }

  throw StateError(
      'Could not locate tool/mock_store.py from the `snapstore_auth` '
      'package. Run `flutter pub get`, or set '
      'SNAPSTORE_AUTH_LOCAL=/path/to/snapstore-auth.');
}

String? _fromPackageConfig() {
  try {
    final dotTool =
        Directory('${Directory.current.path}/.dart_tool').absolute.path;
    final cfg = File('$dotTool/package_config.json');
    if (!cfg.existsSync()) return null;
    final map = jsonDecode(cfg.readAsStringSync()) as Map<String, Object?>;
    final pkgs = (map['packages'] as List?) ?? const [];
    for (final o in pkgs) {
      final p = o as Map<String, Object?>;
      if (p['name'] != 'snapstore_auth') continue;
      final rootUri = (p['rootUri'] as String?) ?? '';
      final Uri dirUri;
      if (rootUri.startsWith('file://')) {
        dirUri = Uri.parse(rootUri);
      } else if (rootUri.startsWith('/')) {
        dirUri = Uri.directory(rootUri);
      } else {
        // Relative to the package_config.json location (.dart_tool/).
        dirUri = Uri.directory('$dotTool/').resolve(rootUri);
      }
      final candidate = File('${dirUri.toFilePath()}/tool/mock_store.py');
      if (candidate.existsSync()) return candidate.path;
    }
  } catch (_) {
    // Fall through to the other strategies.
  }
  return null;
}

String _home() =>
    Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
