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

/// A snap listed in a brand store's catalog (id + name only; type/base/
/// channels are resolved separately via the store info API).
class StoreCatalogSnap {
  final String id;
  final String name;
  const StoreCatalogSnap({required this.id, required this.name});
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

  static const _authName = 'ubuntu-core-model-builder';
  static const _server = 'production';
  static const _accountUrl =
      'https://dashboard.snapcraft.io/dev/api/account';

  // Permissions the web-login token must carry. package_access covers the
  // account/store list; store_admin is required for the store catalog
  // endpoint (listing snaps in a brand store). Individual queries use only
  // the permission they need (package_access), but the token must be minted
  // with both.
  static const _loginPermissions = ['package_access', 'store_admin'];
  static const _queryPermission = 'package_access';

  // NOTE: "_pyVer" is coupled to the python3.12-minimal stage-package in
  // snapcraft.yaml AND the venv built against it. If you bump the Python
  // version (e.g. a new base), update BOTH the stage-package and this
  // constant together. All bundled paths derive from it.
  static const _pyVer = 'python3.12';

  bool get _inSnap => (Platform.environment['SNAP'] ?? '').isNotEmpty;
  String get _snap => Platform.environment['SNAP'] ?? '';

  String get _authDir {
    final fromSnapd = Platform.environment['SNAP_USER_COMMON'];
    if (fromSnapd != null && fromSnapd.isNotEmpty) return fromSnapd;
    final home = Platform.environment['HOME'] ?? '/tmp';
    return '$home/.local/share/ubuntu-core-model-builder/surl';
  }

  Map<String, String> _surlEnv() {
    final env = HostEnv.sanitized;
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

  Future<bool> hasCredential() async {
    final f = File('$_authDir/$_authName.surl');
    return f.exists();
  }

  Future<List<BrandStore>> listStores() async {
    await _ensureAuthDir();
    final (exe, prefix) = _invocation();
    final ProcessResult r;
    try {
      r = await Process.run(
        exe,
        [...prefix, '-a', _authName, '-p', _queryPermission, '-s', _server,
            _accountUrl],
        environment: _surlEnv(),
        includeParentEnvironment: false,
      );
    } on ProcessException catch (e) {
      throw SurlUnavailableException('Could not run surl: ${e.message}');
    }
    final out = (r.stdout as String?)?.trim() ?? '';
    final err = (r.stderr as String?)?.trim() ?? '';
    if (r.exitCode != 0) {
      throw SurlAuthException(err.isNotEmpty ? err : 'Not authenticated.');
    }
    if (out.isEmpty) {
      throw SurlAuthException('Empty response from surl (login may be needed).');
    }
    Map<String, dynamic> data;
    try {
      data = jsonDecode(out) as Map<String, dynamic>;
    } catch (_) {
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

  /// Lists the snaps in a brand store's catalog. Requires an authenticated
  /// token (minted with package_access + store_admin); the query itself uses
  /// package_access. Throws [SurlAuthException] if not authenticated.
  Future<List<StoreCatalogSnap>> listStoreSnaps(String storeId) async {
    await _ensureAuthDir();
    final (exe, prefix) = _invocation();
    final url =
        'https://dashboard.snapcraft.io/api/v2/stores/$storeId/snaps';
    final ProcessResult r;
    try {
      r = await Process.run(
        exe,
        [
          ...prefix,
          '-a', _authName,
          '-p', _queryPermission,
          '-s', _server,
          '-X', 'GET',
          url,
        ],
        environment: _surlEnv(),
        includeParentEnvironment: false,
      );
    } on ProcessException catch (e) {
      throw SurlUnavailableException('Could not run surl: ${e.message}');
    }
    final out = (r.stdout as String?)?.trim() ?? '';
    final err = (r.stderr as String?)?.trim() ?? '';
    if (r.exitCode != 0) {
      throw SurlAuthException(err.isNotEmpty ? err : 'Not authenticated.');
    }
    if (out.isEmpty) {
      throw SurlAuthException('Empty catalog response (login may be needed).');
    }
    Map<String, dynamic> data;
    try {
      data = jsonDecode(out) as Map<String, dynamic>;
    } catch (_) {
      throw SurlAuthException(
          'Unexpected catalog output (login may be needed):\n$out');
    }
    final snaps = data['snaps'] as List<dynamic>? ?? const [];
    return snaps
        .whereType<Map>()
        .map((e) {
          final m = e.cast<String, dynamic>();
          return StoreCatalogSnap(
            id: (m['id'] ?? '') as String,
            name: (m['name'] ?? '') as String,
          );
        })
        .where((s) => s.name.isNotEmpty)
        .toList();
  }

  /// Interactive web-login. Mints a token with the required permissions
  /// (package_access + store_admin) so both store listing and catalog
  /// browsing work. surl opens the browser and blocks until SSO completes.
  Future<void> webLogin() async {
    await _ensureAuthDir();
    final (exe, prefix) = _invocation();
    final permArgs = <String>[];
    for (final p in _loginPermissions) {
      permArgs
        ..add('-p')
        ..add(p);
    }
    final ProcessResult r;
    try {
      r = await Process.run(
        exe,
        [...prefix, '-a', _authName, ...permArgs, '--web-login', '-s',
            _server],
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
