import 'dart:convert';
import 'dart:io';

import 'host_env.dart';

/// A brand store the account can access. `ubuntu` is the global store, for
/// which the model's `store` field should be omitted entirely.
class BrandStore {
  final String id;
  final String? name;
  final List<String> roles;
  const BrandStore({required this.id, this.name, this.roles = const []});

  bool get isGlobal => id == 'ubuntu';

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'roles': roles,
      };

  factory BrandStore.fromJson(Map<String, dynamic> j) => BrandStore(
        id: j['id'] as String,
        name: j['name'] as String?,
        roles: (j['roles'] as List<dynamic>?)
                ?.map((r) => r.toString())
                .toList() ??
            const [],
      );
}

class SurlAuthException implements Exception {
  final String message;
  SurlAuthException(this.message);
  @override
  String toString() => message;
}

class SurlUnavailableException implements Exception {
  final String message;
  SurlUnavailableException([this.message = 'surl is not available.']);
  @override
  String toString() => message;
}

class SurlService {
  /// Shared SharedPreferences key for the cached brand-store list, so both
  /// the metadata page (which writes it) and the account page (which clears
  /// it on logout) reference one source of truth.
  static const prefCachedStores = 'metadata.cachedStores';


  // The auth identity this app owns in surl. The user never manages this.
  static const _authName = 'ubuntu-core-model-builder';
  static const _server = 'production';
  static const _accountUrl =
      'https://dashboard.snapcraft.io/dev/api/account';

  // NOTE: "_pyVer" is coupled to the python3.12-minimal stage-package in
  // snapcraft.yaml AND the venv built against it. If you bump the Python
  // version (e.g. a new base), update BOTH the stage-package and this
  // constant together. All bundled paths derive from it.
  static const _pyVer = 'python3.12';

  bool get _inSnap => (Platform.environment['SNAP'] ?? '').isNotEmpty;
  String get _snap => Platform.environment['SNAP'] ?? '';

  /// Stable directory where surl writes its <auth>.surl credential file.
  /// Prefer snapd's SNAP_USER_COMMON if set; otherwise a per-user dir.
  String get _authDir {
    final fromSnapd = Platform.environment['SNAP_USER_COMMON'];
    if (fromSnapd != null && fromSnapd.isNotEmpty) return fromSnapd;
    final home = Platform.environment['HOME'] ?? '/tmp';
    return '$home/.local/share/ubuntu-core-model-builder/surl';
  }

  /// Environment for invoking bundled surl. Unlike host tools (which get
  /// their library env stripped), bundled surl's Python extensions NEED the
  /// snap's libraries, so we add LD_LIBRARY_PATH back here only. We also set
  /// PYTHONPATH, SSL cert paths, and the credential dir.
  Map<String, String> _surlEnv() {
    final env = HostEnv.sanitized; // starts from host env minus lib vars
    if (_inSnap) {
      final venv = '$_snap/usr/share/surl-venv';
      env['PYTHONPATH'] = '$venv/lib/$_pyVer/site-packages';
      env.remove('PYTHONHOME');
      env['LD_LIBRARY_PATH'] =
          '$_snap/usr/lib/x86_64-linux-gnu:$_snap/lib/x86_64-linux-gnu';
      env['SSL_CERT_FILE'] = '$_snap/etc/ssl/certs/ca-certificates.crt';
      env['SSL_CERT_DIR'] = '$_snap/etc/ssl/certs';
    }
    env['SNAP_USER_COMMON'] = _authDir;
    return env;
  }

  /// (executable, argsPrefix) to run surl. In the snap: staged python3.12 on
  /// surl_cli.py. In dev (no $SNAP): host `surl`.
  (String, List<String>) _invocation() {
    if (_inSnap) {
      return (
        '$_snap/usr/bin/$_pyVer',
        ['$_snap/usr/share/surl-venv/bin/surl_cli.py'],
      );
    }
    return ('surl', const <String>[]);
  }

  Future<void> _ensureAuthDir() async {
    try {
      await Directory(_authDir).create(recursive: true);
    } catch (_) {}
  }

  /// Whether an auth token already exists for our identity (avoids launching
  /// web-login when we are already authenticated).
  Future<bool> hasCredential() async {
    final f = File('$_authDir/$_authName.surl');
    return f.exists();
  }

  /// Lists brand stores from the account endpoint. Throws:
  ///  - [SurlUnavailableException] if surl can't be executed,
  ///  - [SurlAuthException] if not authenticated / token invalid.
  Future<List<BrandStore>> listStores() async {
    await _ensureAuthDir();
    final (exe, prefix) = _invocation();

    final ProcessResult r;
    try {
      r = await Process.run(
        exe,
        [...prefix, '-a', _authName, '-s', _server, _accountUrl],
        environment: _surlEnv(),
        includeParentEnvironment: false,
      );
    } on ProcessException catch (e) {
      throw SurlUnavailableException('Could not run surl: ${e.message}');
    }

    final out = (r.stdout as String?)?.trim() ?? '';
    final err = (r.stderr as String?)?.trim() ?? '';

    if (r.exitCode != 0) {
      // Non-zero usually means missing/expired token → needs web-login.
      throw SurlAuthException(err.isNotEmpty ? err : 'Not authenticated.');
    }
    if (out.isEmpty) {
      throw SurlAuthException('Empty response from surl (login may be needed).');
    }

    Map<String, dynamic> data;
    try {
      data = jsonDecode(out) as Map<String, dynamic>;
    } catch (_) {
      // Non-JSON output typically means an auth/error message, not data.
      throw SurlAuthException(
          'Unexpected surl output (login may be needed):\n$out');
    }

    final stores = data['stores'] as List<dynamic>? ?? const [];
    return stores
        .whereType<Map>()
        .map((e) {
          final m = e.cast<String, dynamic>();
          return BrandStore(
            id: (m['id'] ?? '') as String,
            name: m['name'] as String?,
            roles: (m['roles'] as List<dynamic>?)
                    ?.map((r) => r.toString())
                    .toList() ??
                const [],
          );
        })
        .where((s) => s.id.isNotEmpty)
        .toList();
  }

  /// Interactive web-login. surl opens the browser and blocks until SSO
  /// completes, then returns account JSON. No terminal is needed because the
  /// interaction happens in the browser, not on a tty.
  ///
  /// Returns nothing; on success surl has stored the credential. Throws
  /// [SurlUnavailableException] if surl can't be run, or [SurlAuthException]
  /// if login did not complete successfully.
  Future<void> webLogin() async {
    await _ensureAuthDir();
    final (exe, prefix) = _invocation();

    final ProcessResult r;
    try {
      r = await Process.run(
        exe,
        [...prefix, '-a', _authName, '--web-login', '-s', _server],
        environment: _surlEnv(),
        includeParentEnvironment: false,
      );
    } on ProcessException catch (e) {
      throw SurlUnavailableException('Could not run surl: ${e.message}');
    }

    if (r.exitCode != 0) {
      final err = (r.stderr as String?)?.trim() ?? '';
      final out = (r.stdout as String?)?.trim() ?? '';
      throw SurlAuthException(
        err.isNotEmpty ? err : (out.isNotEmpty ? out : 'Login failed.'),
      );
    }
  }
}
