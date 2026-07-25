import 'dart:io';

/// Provides a "host-safe" environment for spawning host binaries from within
/// a classically-confined snap.
///
/// The snap sets LD_LIBRARY_PATH, GTK_PATH, GIO_MODULE_DIR, LIBGL_DRIVERS_PATH
/// and GDK_BACKEND so its own bundled (patchelf'd) libraries are used by the
/// Flutter app. But when we spawn HOST tools (snap, snapcraft, gpg, pinentry,
/// gnome-terminal), those variables poison the child: it tries to load our
/// bundled libraries instead of the host's, causing launch failures or
/// missing pinentry dialogs. We strip them so host binaries use host
/// libraries.
class HostEnv {
  HostEnv._();

  static const _stripKeys = <String>[
    'LD_LIBRARY_PATH',
    'GTK_PATH',
    'GIO_MODULE_DIR',
    'LIBGL_DRIVERS_PATH',
    'GDK_BACKEND',
    // Flutter/engine and snap-injected paths that could also interfere:
    'LD_PRELOAD',
  ];

  /// A copy of the current environment with snap-bundled library paths
  /// removed, suitable for `Process.start`/`Process.run` `environment:`.
  static Map<String, String> get sanitized {
    final env = Map<String, String>.from(Platform.environment);
    for (final k in _stripKeys) {
      env.remove(k);
    }
    return env;
  }
}
