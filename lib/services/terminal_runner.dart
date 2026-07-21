import 'dart:io';
import 'package:process_run/process_run.dart';

/// Runs a shell command inside a terminal emulator so interactive prompts
/// (passphrases, 2FA) have a real tty. Shared by login and key operations.
class TerminalRunner {
  /// Launches [command] (a shell snippet) in a terminal. Returns the
  /// [Process] handle. Uses setsid where available so the whole group can
  /// be signalled. Throws [NoTerminalException] if no emulator is found.
  ///
  /// When [wait] is true, terminals that support it (gnome-terminal, ptyxis)
  /// are told to block until the inner command exits, so the returned
  /// Process exit reflects completion instead of returning early.
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

    if (hasSetsid) {
      return Process.start(
        'setsid',
        [term.command, ...launchArgs],
        mode: ProcessStartMode.normal,
      );
    }
    return Process.start(
      term.command,
      launchArgs,
      mode: ProcessStartMode.normal,
    );
  }

  /// Runs [command] in a terminal and completes when it exits. Passes
  /// [wait] through so gnome-terminal/ptyxis block properly.
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
    final shell = Shell(throwOnError: false);
    final r = await shell.run('which $cmd');
    if (r.first.exitCode != 0) return null;
    final out = r.outText.trim();
    return out.isEmpty ? null : out;
  }

  static Future<_Term?> _findTerminal() async {
    Future<bool> exists(String c) async => (await _which(c)) != null;
    // waitArgs: flags that make the launcher block until the child exits.
    // execArgs: flag that means "run this command".
    // Order matters: waitArgs come before execArgs on the command line.
    final candidates = <_Term>[
      _Term('gnome-terminal', execArgs: ['--'], waitArgs: ['--wait']),
      _Term('ptyxis', execArgs: ['--'], waitArgs: ['--wait']),
      // konsole blocks by default when using -e.
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
