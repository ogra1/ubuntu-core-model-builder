import 'dart:io';
import 'package:process_run/process_run.dart';
import 'package:path_provider/path_provider.dart';

import 'cancel_token.dart';

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

class StoreService {
  Future<StoreAccount?> getCurrentAccount() async {
    final shell = Shell(throwOnError: false);
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

  /// Launches `snapcraft login` inside a terminal emulator and returns the
  /// terminal [Process] so the caller can [Process.kill] it on cancel.
  ///
  /// Uses a new session (setsid) so we can signal the whole process group,
  /// killing the terminal AND the snapcraft child inside it.
  ///
  /// Throws [NoTerminalException] if no known terminal emulator is found.
  Future<Process> loginInTerminal() async {
    final term = await _findTerminal();
    if (term == null) {
      throw NoTerminalException();
    }

    const inner = 'snapcraft login; '
        'echo; '
        'echo "You may close this window."; '
        'read -n 1 -s -r -p "Press any key to close..."';

    // Prefix with `setsid` so the terminal starts its own process group,
    // letting us kill the whole group later. Fall back gracefully if
    // setsid is unavailable.
    final hasSetsid = await _which('setsid') != null;

    final Process process;
    if (hasSetsid) {
      process = await Process.start(
        'setsid',
        [term.command, ...term.execArgs, 'sh', '-c', inner],
        mode: ProcessStartMode.normal,
      );
    } else {
      process = await Process.start(
        term.command,
        [...term.execArgs, 'sh', '-c', inner],
        mode: ProcessStartMode.normal,
      );
    }

    // Drain stdio to avoid the pipe filling up (terminal emulators are
    // usually quiet, but be safe).
    process.stdout.drain<void>();
    process.stderr.drain<void>();

    return process;
  }

  /// Kills a terminal process launched by [loginInTerminal], attempting to
  /// take down its whole process group (so snapcraft inside dies too).
  Future<void> killTerminal(Process process) async {
    final pid = process.pid;
    try {
      // Negative pid signals the process group (works when started via
      // setsid). Try SIGTERM first, then SIGKILL.
      final term = await Process.run('kill', ['-TERM', '-$pid']);
      if (term.exitCode != 0) {
        // Fall back to killing just the process.
        process.kill(ProcessSignal.sigterm);
      }
    } catch (_) {
      try {
        process.kill(ProcessSignal.sigterm);
      } catch (_) {}
    }

    // Give it a moment, then force-kill the group if still around.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    try {
      await Process.run('kill', ['-KILL', '-$pid']);
    } catch (_) {
      try {
        process.kill(ProcessSignal.sigkill);
      } catch (_) {}
    }
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
    final shell = Shell(throwOnError: false);
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
        await Process.run('chmod', ['600', file.path]);
      } catch (_) {}

      final result = await Process.run(
        'snapcraft',
        ['login', '--with', file.path],
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
    final shell = Shell(throwOnError: false);
    final r = await shell.run('which $cmd');
    if (r.first.exitCode != 0) return null;
    final out = r.outText.trim();
    return out.isEmpty ? null : out;
  }

  Future<_Terminal?> _findTerminal() async {
    Future<bool> exists(String cmd) async => (await _which(cmd)) != null;

    final candidates = <_Terminal>[
      _Terminal('gnome-terminal', ['--']),
      _Terminal('ptyxis', ['--']),
      _Terminal('konsole', ['-e']),
      _Terminal('tilix', ['-e']),
      _Terminal('xfce4-terminal', ['-x']),
      _Terminal('alacritty', ['-e']),
      _Terminal('kitty', <String>[]),
      _Terminal('xterm', ['-e']),
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
  _Terminal(this.command, this.execArgs);
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
