import 'dart:io';

import 'package:process_run/process_run.dart';

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
  final _shell = Shell(throwOnError: false);

  Future<List<SigningKey>> listKeys() async {
    final local = await _listLocalKeys();
    final registeredFingerprints = await _listRegisteredFingerprints();
    return local
        .map((k) =>
            k.copyWith(registered: registeredFingerprints.contains(k.sha3384)))
        .toList();
  }

  /// Local keys in the GPG keyring, via `snap keys`.
  /// Output columns are: Name  SHA3-384
  Future<List<SigningKey>> _listLocalKeys() async {
    final result = await _shell.run('snap keys');
    if (result.first.exitCode != 0) return [];

    final text = result.outText;
    // `snap keys` prints "No keys registered..." style message when empty.
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
  /// `snapcraft keys`. On this snapcraft version the output lists
  /// registered fingerprints as bullet lines:
  ///
  ///   The following SHA3-384 key fingerprints have been registered ...
  ///   - <fingerprint>
  ///   - <fingerprint>
  ///
  /// Locally-available registered keys may instead appear in a table with
  /// a Name and SHA3-384 column; we capture fingerprints from both shapes.
  Future<Set<String>> _listRegisteredFingerprints() async {
    final result = await _shell.run('snapcraft keys');
    if (result.first.exitCode != 0) return {};

    final fingerprints = <String>{};
    // A SHA3-384 base64url fingerprint is ~64 chars of [A-Za-z0-9_-].
    final fpPattern = RegExp(r'[A-Za-z0-9_\-]{40,}');

    for (final line in result.outText.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      // Bullet form: "- <fingerprint>"
      if (trimmed.startsWith('-')) {
        final rest = trimmed.substring(1).trim();
        final m = fpPattern.firstMatch(rest);
        if (m != null) fingerprints.add(m.group(0)!);
        continue;
      }

      // Table form: "Name  <fingerprint>" or "* Name <fingerprint>".
      // Grab any long base64url token on the line.
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
  /// passphrase prompt has a real tty.
  Future<void> createKey(String name) async {
    final cmd = 'snap create-key ${_shellQuote(name)}; '
        'echo; '
        'echo "If successful, you can close this window."; '
        'read -n 1 -s -r -p "Press any key to close..."';
    await TerminalRunner.runToCompletion(cmd);
  }

  /// Registers a key by running `snapcraft register-key <name>` in a terminal.
  Future<void> registerKey(String name) async {
    final cmd = 'snapcraft register-key ${_shellQuote(name)}; '
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
    final cmd = '$createPart'
        'snapcraft register-key ${_shellQuote(name)}; '
        'echo; '
        'echo "If successful, you can close this window."; '
        'read -n 1 -s -r -p "Press any key to close..."';
    await TerminalRunner.runToCompletion(cmd);
  }

  String _shellQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";
  /// Cleanly stops the gpg-agent that snap uses for its keyring
  /// (~/.snap/gnupg), so it does not linger after the app exits.
  ///
  /// Uses `gpgconf --kill`, the supported way to terminate an agent for a
  /// specific GPG home. Best-effort: failures are ignored.
  static Future<void> stopSnapGpgAgent() async {
    final home = _snapGnupgHome();
    if (home == null) return;
    try {
      await Process.run('gpgconf', ['--homedir', home, '--kill', 'gpg-agent']);
    } catch (_) {
      // gpgconf not present or agent already gone; ignore.
    }
  }

  static String? _snapGnupgHome() {
    final env = Platform.environment;
    final base = env['HOME'];
    if (base == null || base.isEmpty) return null;
    return '$base/.snap/gnupg';
  }
}



class KeyException implements Exception {
  final String message;
  KeyException(this.message);
  @override
  String toString() => message;
}
