import 'package:process_run/process_run.dart';

import 'host_env.dart';

/// Centralises snapcraft version detection and the environment used for all
/// snapcraft invocations. snapcraft 9.x+ supports Candid browser-based login;
/// we enable it via SNAPCRAFT_STORE_AUTH=candid, which must be present for
/// ALL snapcraft calls (not just login) so credentials are read consistently.
class SnapcraftEnv {
  SnapcraftEnv._();

  static int? _majorVersion;
  static bool _detected = false;

  /// Detects snapcraft's major version (e.g. 9 from "snapcraft 9.5.1").
  /// Cached after first detection. Returns null if not found/unparseable.
  static Future<int?> majorVersion() async {
    if (_detected) return _majorVersion;
    _detected = true;
    try {
      final shell = Shell(
        throwOnError: false,
        verbose: false,
        environment: HostEnv.sanitized,
        includeParentEnvironment: false,
      );
      final r = await shell.run('snapcraft --version');
      final out = '${r.outText}\n${r.errText}';
      final m = RegExp(r'(\d+)\.\d+').firstMatch(out);
	  _majorVersion = m != null ? int.tryParse(m.group(1)!) : null;
    } catch (_) {
      _majorVersion = null;
    }
    return _majorVersion;
  }

  /// True if snapcraft supports Candid web login (>= 9).
  static Future<bool> supportsWebLogin() async {
    final v = await majorVersion();
    return v != null && v >= 9;
  }

  /// Environment for invoking snapcraft: host-sanitized, plus
  /// SNAPCRAFT_STORE_AUTH=candid when web login is supported.
  static Future<Map<String, String>> environment() async {
    final env = HostEnv.sanitized;
    if (await supportsWebLogin()) {
      env['SNAPCRAFT_STORE_AUTH'] = 'candid';
    }
    return env;
  }
}
