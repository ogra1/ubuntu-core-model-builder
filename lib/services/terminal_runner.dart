import 'dart:io';
import 'package:process_run/process_run.dart';

import 'host_env.dart';

/// Runs a shell command inside a terminal emulator so interactive prompts
/// (passphrases, 2FA) have a real tty. Shared by login and key operations.
class TerminalRunner {
  static Future<Process> run(String command, {bool wait = false}) async {
    final term = await _findTerminal();
    if (term == null) throw NoTerminalException();

    final waitArgs = wait ? term.waitArgs : const <String>[];
    final launchArgs = [
      ...waitArgs,
      ...term.execArgs,
      'sh',
      '-c',
      command,
    ];

    final hasSetsid = await _which('setsid') != null;
    final env = HostEnv.sanitized;

    if (hasSetsid) {
      return Process.start(
        'setsid',
        [term.command, ...launchArgs],
        mode: ProcessStartMode.normal,
        environment: env,
        includeParentEnvironment: false,
      );
    }
    return Process.start(
      term.command,
      launchArgs,
      mode: ProcessStartMode.normal,
      environment: env,
      includeParentEnvironment: false,
    );
  }

  static Future<int> runToCompletion(
    String command, {
    bool wait = true,
  }) async {
    final proc = await run(command, wait: wait);
    proc.stdout.drain<void>();
    proc.stderr.drain<void>();
    return proc.exitCode;
  }

  static Future<String?> _which(String cmd) async {
    // `which` itself is a host binary; run it with a sanitized environment.
    final r = await Process.run(
      'which',
      [cmd],
      environment: HostEnv.sanitized,
      includeParentEnvironment: false,
    );
    if (r.exitCode != 0) return null;
    final out = (r.stdout as String).trim();
    return out.isEmpty ? null : out;
  }

  static Future<_Term?> _findTerminal() async {
    Future<bool> exists(String c) async => (await _which(c)) != null;
    final candidates = <_Term>[
      _Term('gnome-terminal', execArgs: ['--'], waitArgs: ['--wait']),
      _Term('ptyxis', execArgs: ['--'], waitArgs: ['--wait']),
      _Term('konsole', execArgs: ['-e']),
      _Term('tilix', execArgs: ['-e']),
      _Term('xfce4-terminal', execArgs: ['-x']),
      _Term('alacritty', execArgs: ['-e']),
      _Term('kitty', execArgs: <String>[]),
      _Term('xterm', execArgs: ['-e']),
    ];
    for (final c in candidates) {
      if (await exists(c.command)) return c;
    }
    return null;
  }
}

class _Term {
  final String command;
  final List<String> execArgs;
  final List<String> waitArgs;
  _Term(
    this.command, {
    required this.execArgs,
    this.waitArgs = const <String>[],
  });
}

class NoTerminalException implements Exception {
  @override
  String toString() =>
      'No terminal emulator found to run the interactive command.';
}
