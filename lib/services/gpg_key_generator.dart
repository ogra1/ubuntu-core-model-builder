import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Creates signing keys in the host GPG keyring by driving `gpg --gen-key`
/// directly, bypassing `snap create-key`.
///
/// Why bypass `snap create-key`?
///
/// `snap create-key` (snapd) reads the passphrase from the controlling
/// terminal itself (`terminal.ReadPassword(0)` in
/// `asserts/signtool/keymgr.go`) and feeds it to gpg as a `Passphrase:`
/// line in a `--batch --gen-key` params blob. That is why it always opens
/// a terminal window. `snap sign`, in contrast, never reads a passphrase
/// itself — it lets gpg-agent prompt through pinentry (pinentry-gnome3),
/// which is why signing gets a graphical dialog.
///
/// GPG is happy to route the key-generation passphrase through that same
/// agent→pinentry channel when the params blob contains no `Passphrase:`
/// line. This class reproduces snapd's exact key spec (RSA-4096, SHA512
/// digest, uid == key name — see [KeySpec]) so a key created here is
/// indistinguishable, to `snap keys`, `snap export-key` and `snap sign`,
/// from one created by `snap create-key`.
///
/// Security: the passphrase is entered in the system's graphical pinentry
/// dialog and travels only between gpg-agent and pinentry (a local
/// socket). It never touches this application — not its memory, not its
/// argv, and not the disk — which is exactly how `snap sign` works.
abstract final class KeySpec {
  /// The exact `gpg --gen-key` params snapd writes
  /// (`asserts/gpgkeypairmgr.go`, `generateTemplate`).
  ///
  /// The fixed 2016 creation date snapd pins for test determinism is NOT
  /// part of the assertions and is not validated, so it is deliberately
  /// omitted (the key simply gets the current date).
  ///
  /// There is deliberately no `Passphrase:` line: its presence is what
  /// would suppress the pinentry prompt. Keep this in sync with the
  /// invariants snapd enforces at sign time (`asserts/crypto.go`): RSA
  /// only, >= 4096 bits, SHA512 digest. The [GpgKeyGenerator.checkSpec]
  /// post-creation check exists precisely to fail loudly if those
  /// invariants ever drift.
  static String params(String name) =>
      'Key-Type: RSA\n'
      'Key-Length: 4096\n'
      'Name-Real: $name\n'
      'Preferences: SHA512\n';
}

/// A parsed secret key from `gpg --list-secret-keys --with-colons`.
///
/// Only the FIRST `sec:` record of the keyring is returned; the
/// `fpr:`/`uid:` fields are taken from the records that follow that `sec:`
/// (gpg emits `sec`, `fpr`/`grp`, `uid` in that order — the same ordering
/// snapd's `walkSecretKeys` relies on).
class GeneratedKeyInfo {
  final String fingerprint;
  final String uid;
  final int? length;
  final int? algo;
  final int? createdAtSeconds;

  const GeneratedKeyInfo({
    required this.fingerprint,
    required this.uid,
    this.length,
    this.algo,
    this.createdAtSeconds,
  });
}

/// The freshly created key.
class CreatedKey {
  final String name;
  final String fingerprint;

  const CreatedKey({required this.name, required this.fingerprint});
}

/// Failure to generate a key (missing environment, gpg error, or the
/// post-creation spec check rejecting the result).
class KeyGenerationException implements Exception {
  final String message;

  const KeyGenerationException(this.message);

  @override
  String toString() => message;
}

/// Drives `gpg --gen-key` in the host keyring (`~/.snap/gnupg`) and
/// verifies the result against snapd's signing-key invariants.
class GpgKeyGenerator {
  final String gpgBinary;
  final Future<String?> Function() homedirProvider;

  GpgKeyGenerator({
    this.gpgBinary = 'gpg',
    Future<String?> Function()? homedirProvider,
  }) : homedirProvider = homedirProvider ?? _defaultHomedir;

  /// Creates the key [name] in the host keyring.
  ///
  /// The passphrase is prompted for by the system graphical pinentry
  /// (gpg-agent's default channel) — the same dialog `snap sign` uses —
  /// and is never received or handled by this application.
  ///
  /// [timeout] bounds the whole generation, which is where the user is
  /// entering the passphrase.
  ///
  /// Throws [KeyGenerationException] on any failure, including the
  /// post-creation spec check ([checkSpec]) that guards against future
  /// snapd policy drift.
  Future<CreatedKey> generate({
    required String name,
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final homedir = await homedirProvider();
    if (homedir == null || homedir.isEmpty) {
      throw const KeyGenerationException(
          'Could not determine the GPG home directory (~/.snap/gnupg).');
    }
    await ensureHomedir(homedir);
    await _runGenKey(homedir, name: name, timeout: timeout);

    final listing = await _listSecretKeys(homedir);
    final info = parseSecretKey(listing);
    if (info == null) {
      throw const KeyGenerationException(
          'Key creation finished but no key was found in the keyring. '
          'It may have been cancelled at the passphrase prompt.');
    }
    final specError = checkSpec(info, name);
    if (specError != null) {
      throw KeyGenerationException(specError);
    }
    return CreatedKey(name: name, fingerprint: info.fingerprint);
  }

  /// Creates [homedir] (and any missing parents, e.g. `~/.snap`) if it does
  /// not exist yet, with the permissions gpg requires:
  ///
  /// * the gnupg homedir leaf — 0700, or gpg emits
  ///   `WARNING: unsafe permissions on homedir` and treats the keyring as
  ///   compromised;
  /// * a `~/.snap` parent we had to create — 0711 (traversable, not
  ///   listable), the same permissions snapd uses for the directory.
  ///
  /// gpg does **not** create its homedir. Without this, the first key
  /// generation on a machine where nothing has written to `~/.snap` yet
  /// (fresh installs, CI/builder containers) fails with
  /// `keyblock resource '.../pubring.kbx': No such file or directory` and
  /// `No agent running` instead of showing the passphrase prompt.
  static Future<void> ensureHomedir(String homedir) async {
    final dir = Directory(homedir);
    if (await dir.exists()) return;
    await dir.parent.create(recursive: true);
    await dir.create();
    try {
      await Process.run('chmod', ['700', dir.path]);
      if (dir.parent.path.split(Platform.pathSeparator).last == '.snap') {
        await Process.run('chmod', ['711', dir.parent.path]);
      }
    } on ProcessException {
      // chmod is POSIX-only; elsewhere the directories keep the default
      // umask permissions (gpg will warn but still work in the 0755 case).
    }
  }

  // -- internals -------------------------------------------------------------

  /// Runs `gpg --gen-key`, feeding the params blob on stdin.
  ///
  /// There is no `Passphrase:` line in the blob and no loopback options,
  /// so gpg-agent prompts for the passphrase (and a confirmation) through
  /// pinentry — the same channel `snap sign` uses. `--batch` suppresses
  /// gpg's *own* interactive prompts (the "proceed?" confirmation, ...);
  /// it does not suppress the agent's pinentry, which is exactly the
  /// behaviour we want here.
  Future<void> _runGenKey(
    String homedir, {
    required String name,
    required Duration timeout,
  }) async {
    final args = <String>[
      '--homedir',
      homedir,
      '-q',
      '--no-auto-check-trustdb',
      '--batch',
      '--gen-key',
    ];

    Process process;
    try {
      process = await Process.start(gpgBinary, args);
    } on ProcessException catch (e) {
      throw KeyGenerationException(
          'Could not run "gpg". Is GnuPG installed?\n${e.message}');
    }

    process.stdout.drain<void>();
    final errFut = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    // gpg may exit before we finish feeding it the params blob (bad
    // homedir, missing agent, ...). The write then fails with a broken
    // pipe; swallow it so the exit-code/stderr path below produces the
    // friendly KeyGenerationException instead of a raw SocketException.
    try {
      process.stdin.add(utf8.encode(KeySpec.params(name)));
      await process.stdin.close();
    } on SocketException {
      // fall through: the process is already exiting.
    }

    final int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      throw KeyGenerationException(
          'Key creation timed out after ${timeout.inSeconds}s without a '
          'passphrase being entered. Try again.');
    }
    if (exitCode != 0) {
      final err = (await errFut).trim();
      throw KeyGenerationException(_friendlyGpgError(err, exitCode));
    }
  }

  Future<String> _listSecretKeys(
    String homedir, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    Process process;
    try {
      process = await Process.start(gpgBinary, [
        '--homedir',
        homedir,
        '--batch',
        '--list-secret-keys',
        '--fingerprint',
        '--with-colons',
        '--fixed-list-mode',
      ]);
    } on ProcessException catch (e) {
      throw KeyGenerationException('Could not run "gpg": ${e.message}');
    }
    process.stderr.drain<void>();
    final outFut = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final exitCode = await process.exitCode.timeout(timeout);
    if (exitCode != 0) {
      throw const KeyGenerationException(
          'Could not read the GPG keyring to verify the new key.');
    }
    return outFut;
  }

  // -- pure, testable pieces ---------------------------------------------------

  /// Parses the first secret key out of
  /// `gpg --list-secret-keys --fingerprint --with-colons` output.
  ///
  /// Returns `null` when no `sec:`/`fpr:`/`uid:` triple is present (empty
  /// keyring, comments only, ...).
  static GeneratedKeyInfo? parseSecretKey(String text) {
    String? fingerprint;
    String? uid;
    int? length;
    int? algo;
    int? createdAt;

    for (final line in text.split('\n')) {
      final colon = line.indexOf(':');
      if (colon < 0) continue;
      final type = line.substring(0, colon);
      final f = line.substring(colon + 1).split(':');
      switch (type) {
        case 'sec':
          // After splitting off the record type, the gpg `sec:` fields are:
          //   f[0]=validity  f[1]=key-length  f[2]=algo  f[3]=key-id
          //   f[4]=created   (see gpg doc/DETAILS).
          // Only the FIRST secret key matters: the caller just created it.
          if (length == null && f.length > 4) {
            length = int.tryParse(f[1]);
            algo = int.tryParse(f[2]);
            createdAt = int.tryParse(f[4]);
          }
        case 'fpr':
          // gpg emits `fpr` + 9 colons + fingerprint + trailing colon;
          // the fingerprint is the first non-empty field after the type.
          if (fingerprint == null) {
            for (final field in f) {
              if (field.isNotEmpty) {
                fingerprint = field;
                break;
              }
            }
          }
        case 'uid':
          if (uid == null && f.length > 8) uid = f[8];
        default:
          break;
      }
    }

    if (fingerprint == null || uid == null) return null;
    return GeneratedKeyInfo(
      fingerprint: fingerprint,
      uid: uid,
      length: length,
      algo: algo,
      createdAtSeconds: createdAt,
    );
  }

  /// Validates [info] against the invariants snapd enforces on signing
  /// keys (`asserts/crypto.go`): RSA only, >= 4096 bits, uid == the
  /// requested [name].
  ///
  /// Returns an error message, or `null` when the key is conformant.
  /// This check is what keeps the app safe if a future snapd release
  /// tightens its key policy (e.g. raises the minimum size): the failure
  /// surfaces at creation time with an actionable message instead of the
  /// user getting a key that dies later at sign time.
  static String? checkSpec(GeneratedKeyInfo info, String name) {
    if (info.uid != name) {
      return 'gpg created a key named "${info.uid}", not "$name". Delete '
          'the stray key and try again.';
    }
    final algo = info.algo;
    if (algo == null || (algo != 1 && algo != 2 && algo != 3)) {
      return 'The new key is not an RSA key (OpenPGP algorithm $algo), '
          'but snap sign only accepts RSA keys.';
    }
    final len = info.length;
    if (len == null || len < 4096) {
      return 'The new key is $len bits; snap sign requires at least '
          '4096 bits.';
    }
    return null;
  }

  static String _friendlyGpgError(String err, int exitCode) {
    final blob = err.toLowerCase();
    if (blob.contains('inappropriate ioctl') ||
        blob.contains('no pinentry') ||
        blob.contains('pinentry')) {
      return 'gpg could not show the passphrase dialog (pinentry) on this '
          'machine. A graphical pinentry is required — the same one '
          '"snap sign" uses (pinentry-gnome3).';
    }
    if (blob.contains('already exists')) {
      return 'A key with that name already exists in the GPG keyring.';
    }
    if (blob.contains('agent_genkey') || blob.contains('key generation')) {
      return 'Key generation failed: $err';
    }
    return err.isEmpty
        ? 'gpg exited with code $exitCode.'
        : 'gpg failed (exit $exitCode): $err';
  }

  static Future<String?> _defaultHomedir() async {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return null;
    return '$home/.snap/gnupg';
  }
}
