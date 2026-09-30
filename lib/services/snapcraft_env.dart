import 'package:process_run/process_run.dart';

import 'host_env.dart';

/// Centralises the environment used for all snapcraft invocations.
///
/// Historically this also enabled Candid browser login via
/// SNAPCRAFT_STORE_AUTH=candid, but Candid web login is being retired, so we
/// no longer set it — snapcraft uses its default (terminal/macaroon) auth.
class SnapcraftEnv {
  SnapcraftEnv._();

  /// The environment for invoking snapcraft: the host-sanitised environment.
  static Future<Map<String, String>> environment() async {
    return HostEnv.sanitized;
  }
}
