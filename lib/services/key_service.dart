import 'dart:io';

import 'package:process_run/process_run.dart';

import 'host_env.dart';
import 'snapcraft_env.dart';
import 'terminal_runner.dart';

class SigningKey {
  final String name;
  final String sha3384;
  final bool registered;

  SigningKey({
    required this.name,
    required this.sha3384,
    this.registered = false,
  });

  SigningKey copyWith({bool? registered}) => SigningKey(
        name: name,
        sha3384: sha3384,
        registered: registered ?? this.registered,
      );
}

class KeyService {
  Future<List<SigningKey>> listKeys() async {
    final local = await _listLocalKeys();
    final registeredFingerprints = await _listRegisteredFingerprints();
    return local
        .map((k) =>
            k.copyWith(registered: registeredFingerprints.contains(k.sha3384)))
        .toList();
  }

  /// Local keys in the GPG keyring, via `snap keys` (snap, not snapcraft).
  Future<List<SigningKey>> _listLocalKeys() async {
    final shell = Shell(
      throwOnError: false,
      verbose: false,
      environment: HostEnv.sanitized,
      includeParentEnvironment: false,
    );
    final result = await shell.run('snap keys');
    if (result.first.exitCode != 0) return [];

    final text = result.outText;
    if (text.toLowerCase().contains('no keys')) return [];

    final lines = text.split('\n');
    final keys = <SigningKey>[];
    for (final line in lines.skip(1)) {
      if (line.trim().isEmpty) continue;
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length >= 2) {
        keys.add(SigningKey(name: parts[0], sha3384: parts[1]));
      }
    }
    return keys;
  }

  /// Registered key SHA3-384 fingerprints from the store, via
  /// `snapcraft keys`. Uses the snapcraft environment (candid on 9.x+).
  Future<Set<String>> _listRegisteredFingerprints() async {
    final shell = Shell(
      throwOnError: false,
      verbose: false,
      environment: await SnapcraftEnv.environment(),
      includeParentEnvironment: false,
    );
    final result = await shell.run('snapcraft keys');
    if (result.first.exitCode != 0) return {};

    final fingerprints = <String>{};
    final fpPattern = RegExp(r'[A-Za-z0-9_\-]{40,}');

    for (final line in result.outText.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      if (trimmed.startsWith('-')) {
        final rest = trimmed.substring(1).trim();
        final m = fpPattern.firstMatch(rest);
        if (m != null) fingerprints.add(m.group(0)!);
        continue;
      }

      for (final token in trimmed.split(RegExp(r'\s+'))) {
        if (fpPattern.hasMatch(token) && token.length >= 40) {
          fingerprints.add(token);
        }
      }
    }
    return fingerprints;
  }

  static String? validateKeyName(String name) {
    if (name.isEmpty) return 'Key name is required.';
    if (name.length > 64) return 'Key name is too long.';
    if (!RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$').hasMatch(name)) {
      return 'Use lowercase letters, digits and dashes only.';
    }
    return null;
  }

  /// Creates a key by running `snap create-key <name>` in a terminal so the
  /// passphrase prompt has a real tty. (snap, not snapcraft.)
  Future<void> createKey(String name) async {
    final cmd = 'snap create-key ${_shellQuote(name)}; '
        'echo; '
        'echo "If successful, you can close this window."; '
        'read -n 1 -s -r -p "Press any key to close..."';
    await TerminalRunner.runToCompletion(cmd);
  }

  /// Registers a key by running `snapcraft register-key <name>` in a terminal.
  /// On snapcraft 9.x+ the candid auth env var is inlined so register-key
  /// reads the same credentials as login.
  Future<void> registerKey(String name) async {
    final envPrefix = await _snapcraftEnvPrefix();
    final cmd = '$envPrefix'
        'snapcraft register-key ${_shellQuote(name)}; '
        'echo; '
        'echo "If successful, you can close this window."; '
        'read -n 1 -s -r -p "Press any key to close..."';
    await TerminalRunner.runToCompletion(cmd);
  }

  /// Creates (if needed) then registers, both in a terminal.
  Future<void> createAndRegister(String name) async {
    final existing = await _listLocalKeys();
    final createPart = existing.any((k) => k.name == name)
        ? ''
        : 'snap create-key ${_shellQuote(name)} && ';
    final envPrefix = await _snapcraftEnvPrefix();
    final cmd = '$createPart'
        '$envPrefix'
        'snapcraft register-key ${_shellQuote(name)}; '
        'echo; '
        'echo "If successful, you can close this window."; '
        'read -n 1 -s -r -p "Press any key to close..."';
    await TerminalRunner.runToCompletion(cmd);
  }

  /// Shell prefix exporting snapcraft-specific env vars (candid on 9.x+) for
  /// snapcraft invoked inside a TerminalRunner command. Empty on older
  /// snapcraft.
  Future<String> _snapcraftEnvPrefix() async {
    final env = await SnapcraftEnv.environment();
    final auth = env['SNAPCRAFT_STORE_AUTH'];
    if (auth == null || auth.isEmpty) return '';
    return "SNAPCRAFT_STORE_AUTH='$auth' ";
  }

  /// Cleanly stops the gpg-agent that snap uses for its keyring
  /// (~/.snap/gnupg) so it does not linger after the app exits.
  static Future<void> stopSnapGpgAgent() async {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return;
    try {
      await Process.run(
        'gpgconf',
        ['--homedir', '$home/.snap/gnupg', '--kill', 'gpg-agent'],
        environment: HostEnv.sanitized,
        includeParentEnvironment: false,
      );
    } catch (_) {}
  }

  String _shellQuote(String s) {
    final escaped = s.replaceAll("'", "'\\''");
    return "'$escaped'";
  }
}

class KeyException implements Exception {
  final String message;
  KeyException(this.message);
  @override
  String toString() => message;
}
