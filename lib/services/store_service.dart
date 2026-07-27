import 'dart:io';
import 'package:process_run/process_run.dart';
import 'package:path_provider/path_provider.dart';

import 'cancel_token.dart';
import 'host_env.dart';

class StoreAccount {
  final String email;
  final String accountId;
  final String? username;

  StoreAccount({
    required this.email,
    required this.accountId,
    this.username,
  });
}

/// Handle for an in-progress terminal login. Call [cancel] to signal the
/// inner shell (via a sentinel file) to kill the login and close the window.
class LoginSession {
  final String sentinelPath;
  LoginSession(this.sentinelPath);

  /// Signals cancellation by creating the sentinel file the inner shell polls.
  Future<void> cancel() async {
    try {
      await File(sentinelPath).create(recursive: true);
    } catch (_) {}
  }

  /// Cleans up the sentinel file (call after login completes or is cancelled).
  Future<void> dispose() async {
    try {
      final f = File(sentinelPath);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

class StoreService {
  Future<StoreAccount?> getCurrentAccount() async {
    final shell = Shell(
        throwOnError: false,
		verbose: false,
        environment: HostEnv.sanitized,
        includeParentEnvironment: false);
    final result = await shell.run('snapcraft whoami');
    if (result.first.exitCode != 0) return null;

    final output = result.outText;
    String? email, accountId, username;

    for (final line in output.split('\n')) {
      final parts = line.split(':');
      if (parts.length < 2) continue;
      final key = parts[0].trim().toLowerCase();
      final value = parts.sublist(1).join(':').trim();
      switch (key) {
        case 'email':
          email = value;
          break;
        case 'developer id':
        case 'account id':
        case 'id':
          accountId = value;
          break;
        case 'username':
          username = value;
          break;
      }
    }

    if (email == null || accountId == null) return null;
    return StoreAccount(email: email, accountId: accountId, username: username);
  }

  Future<bool> isLoggedIn() async => (await getCurrentAccount()) != null;

  /// Launches `snapcraft login` in a terminal, using a sentinel-file cancel
  /// mechanism that works across all terminals. Returns a [LoginSession];
  /// the caller polls whoami for success and can call session.cancel().
  ///
  /// On success the window auto-closes immediately (the app confirms login
  /// via whoami polling). On cancel the inner shell kills snapcraft login
  /// and exits, closing the window.
  ///
  /// Throws [NoTerminalException] if no terminal emulator is found.
  Future<LoginSession> loginInTerminal() async {
    final term = await _findTerminal();
    if (term == null) throw NoTerminalException();

    // Unique sentinel path in a temp dir.
    final dir = await getTemporaryDirectory();
    final sentinel =
        '${dir.path}/uc-login-cancel-${DateTime.now().millisecondsSinceEpoch}';
    // Make sure a stale sentinel isn't present.
    try {
      final f = File(sentinel);
      if (await f.exists()) await f.delete();
    } catch (_) {}

    // Inner shell: run snapcraft login in the background; poll for either its
    // completion (exit immediately -> window closes) or the cancel sentinel
    // (kill it and exit). No trailing "press any key" so success auto-closes.
    final inner = '''
# Background watcher: kill the whole script group when the sentinel appears.
(
  while [ ! -f "$sentinel" ]; do sleep 0.3; done
  kill 0 2>/dev/null
) &
WATCHER=\$!

# Foreground interactive login (owns the tty so it can prompt).
snapcraft login

# Login returned on its own; stop the watcher and close the window.
kill "\$WATCHER" 2>/dev/null
exit 0
''';

    final env = HostEnv.sanitized;
    final hasSetsid = await _which('setsid') != null;

    if (hasSetsid) {
      await Process.start(
        'setsid',
        [term.command, ...term.waitArgs, ...term.execArgs, 'sh', '-c', inner],
        mode: ProcessStartMode.detached,
        environment: env,
        includeParentEnvironment: false,
      );
    } else {
      await Process.start(
        term.command,
        [...term.waitArgs, ...term.execArgs, 'sh', '-c', inner],
        mode: ProcessStartMode.detached,
        environment: env,
        includeParentEnvironment: false,
      );
    }

    return LoginSession(sentinel);
  }

  Future<StoreAccount?> waitForLogin({
    Duration interval = const Duration(seconds: 2),
    Duration timeout = const Duration(minutes: 2),
    CancelToken? cancelToken,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (cancelToken?.isCancelled ?? false) return null;

      final sliceEnd = DateTime.now().add(interval);
      while (DateTime.now().isBefore(sliceEnd)) {
        if (cancelToken?.isCancelled ?? false) return null;
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }

      if (cancelToken?.isCancelled ?? false) return null;
      final acct = await getCurrentAccount();
      if (acct != null) return acct;
    }
    return null;
  }

  Future<void> logout() async {
    final shell = Shell(
        throwOnError: false,
        environment: HostEnv.sanitized,
        includeParentEnvironment: false);
    await shell.run('snapcraft logout');
  }

  Future<StoreAccount?> importCredentials(String credentials) async {
    final trimmed = credentials.trim();
    if (trimmed.isEmpty) {
      throw CredentialImportException('No credentials provided.');
    }

    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/snapcraft-login-${DateTime.now().millisecondsSinceEpoch}.txt',
    );

    try {
      await file.writeAsString(trimmed);
      try {
        await Process.run('chmod', ['600', file.path],
            environment: HostEnv.sanitized, includeParentEnvironment: false);
      } catch (_) {}

      final result = await Process.run(
        'snapcraft',
        ['login', '--with', file.path],
        environment: HostEnv.sanitized,
        includeParentEnvironment: false,
      );

      if (result.exitCode != 0) {
        final err = (result.stderr as String?)?.trim() ?? '';
        final out = (result.stdout as String?)?.trim() ?? '';
        throw CredentialImportException(
          err.isNotEmpty ? err : (out.isNotEmpty ? out : 'Unknown error.'),
        );
      }

      return getCurrentAccount();
    } finally {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  Future<String?> _which(String cmd) async {
    final r = await Process.run('which', [cmd],
        environment: HostEnv.sanitized, includeParentEnvironment: false);
    if (r.exitCode != 0) return null;
    final out = (r.stdout as String).trim();
    return out.isEmpty ? null : out;
  }

  Future<_Terminal?> _findTerminal() async {
    Future<bool> exists(String cmd) async => (await _which(cmd)) != null;

    final candidates = <_Terminal>[
      _Terminal('gnome-terminal', execArgs: ['--'], waitArgs: ['--wait']),
      _Terminal('ptyxis', execArgs: ['--'], waitArgs: ['--wait']),
      _Terminal('konsole', execArgs: ['-e']),
      _Terminal('tilix', execArgs: ['-e']),
      _Terminal('xfce4-terminal', execArgs: ['-x']),
      _Terminal('alacritty', execArgs: ['-e']),
      _Terminal('kitty', execArgs: <String>[]),
      _Terminal('xterm', execArgs: ['-e']),
    ];

    for (final c in candidates) {
      if (await exists(c.command)) return c;
    }
    return null;
  }
}

class _Terminal {
  final String command;
  final List<String> execArgs;
  final List<String> waitArgs;
  _Terminal(this.command,
      {required this.execArgs, this.waitArgs = const <String>[]});
}

class NoTerminalException implements Exception {
  @override
  String toString() =>
      'No terminal emulator found to run the interactive login.';
}

class CredentialImportException implements Exception {
  final String message;
  CredentialImportException(this.message);
  @override
  String toString() => message;
}
