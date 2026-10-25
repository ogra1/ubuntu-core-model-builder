import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ubuntu_core_model_builder/services/gpg_key_generator.dart';
import 'package:ubuntu_core_model_builder/services/rust_key_service.dart';

/// A fake `gpg` executable for hermetic tests.
///
/// * `--gen-key`: records the params blob (stdin) to `$homedir/params.txt`
///   and the full arg list to `$homedir/genargs.txt`.
/// * `--list-secret-keys`: prints a fixed, conformant RSA-4096
///   sec/fpr/uid triple (uid "stubkey").
///
/// `$homedir` is parsed from the `--homedir` argument, so each test with
/// its own temp dir stays isolated. Failing variants are tiny dedicated
/// stubs installed over this one.
const String kGpgStub = '''#!/usr/bin/env bash
homedir=""
prev=""
for a in "\$@"; do
  if [[ "\$prev" == "--homedir" ]]; then homedir="\$a"; fi
  prev="\$a"
done
if [[ "\$*" == *"--list-secret-keys"* ]]; then
  printf '%s\\n' \\
    "sec:u:4096:1:E57FCDC816DBDD4B:1792363345:::u:::escarESCA:::+:::23::0:" \\
    "fpr:::::::::879876185CAF9C6893B9FCC5E57FCDC816DBDD4B:" \\
    "uid:u::::1792363345::003E64CE9460FE899E4383C462E::stubkey::::::::::0:"
  exit 0
fi
cat > "\$homedir/params.txt"
printf '%s\\n' "\$*" > "\$homedir/genargs.txt"
exit 0
''';

String kConformantListing() =>
    'sec:u:4096:1:E57FCDC816DBDD4B:1792363345:::u:::escarESCA:::+:::23::0:\n'
    'fpr:::::::::879876185CAF9C6893B9FCC5E57FCDC816DBDD4B:\n'
    'uid:u::::1792363345::003E64CE9460FE899E4383C462E::stubkey::::::::::0:\n';

void main() {
  late Directory tmp;
  late File stubGpg;

  void installGpgStub(String script) {
    stubGpg.writeAsStringSync(script);
    Process.runSync('chmod', ['+x', stubGpg.path]);
  }

  GpgKeyGenerator generator() => GpgKeyGenerator(
        gpgBinary: stubGpg.path,
        homedirProvider: () async => tmp.path);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('gpg_key_generator_test.');
    stubGpg = File('${tmp.path}/gpg');
    installGpgStub(kGpgStub);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('parseSecretKey', () {
    test('parses a conformant sec/fpr/uid triple', () {
      final info = GpgKeyGenerator.parseSecretKey(kConformantListing());
      expect(info, isNotNull);
      expect(info!.fingerprint, '879876185CAF9C6893B9FCC5E57FCDC816DBDD4B');
      expect(info.uid, 'stubkey');
      expect(info.length, 4096);
      expect(info.algo, 1);
      expect(info.createdAtSeconds, 1792363345);
    });

    test('returns null for an empty keyring', () {
      expect(GpgKeyGenerator.parseSecretKey(''), isNull);
      expect(GpgKeyGenerator.parseSecretKey('# comment only\n'), isNull);
    });

    test('returns null when a record is missing', () {
      expect(
        GpgKeyGenerator.parseSecretKey(
            'sec:u:4096:1:E57FCDC816DBDD4B:1792363345:::u:::escarESCA:::+:::23::0:\n'),
        isNull,
      );
    });

    test('uses only the first secret key', () {
      final text = kConformantListing() + kConformantListing();
      final info = GpgKeyGenerator.parseSecretKey(text);
      expect(info, isNotNull);
      expect(info!.uid, 'stubkey');
      expect(info.length, 4096);
    });
  });

  group('checkSpec', () {
    test('accepts an RSA-4096 key whose uid matches the name', () {
      final info = GpgKeyGenerator.parseSecretKey(kConformantListing())!;
      expect(GpgKeyGenerator.checkSpec(info, 'stubkey'), isNull);
    });

    test('rejects a uid/name mismatch', () {
      final info = GpgKeyGenerator.parseSecretKey(kConformantListing())!;
      expect(GpgKeyGenerator.checkSpec(info, 'other-name'),
          contains('not "other-name"'));
    });

    test('rejects a non-RSA algorithm', () {
      const info = GeneratedKeyInfo(
          fingerprint: 'FP', uid: 'stubkey', length: 4096, algo: 16);
      expect(GpgKeyGenerator.checkSpec(info, 'stubkey'),
          contains('not an RSA key'));
    });

    test('rejects a key shorter than 4096 bits', () {
      const info = GeneratedKeyInfo(
          fingerprint: 'FP', uid: 'stubkey', length: 2048, algo: 1);
      expect(GpgKeyGenerator.checkSpec(info, 'stubkey'),
          contains('at least 4096'));
    });

    test('rejects when length or algo is unknown', () {
      const noAlgo = GeneratedKeyInfo(
          fingerprint: 'FP', uid: 'stubkey', length: 4096);
      expect(GpgKeyGenerator.checkSpec(noAlgo, 'stubkey'),
          contains('not an RSA key'));
      const noLen =
          GeneratedKeyInfo(fingerprint: 'FP', uid: 'stubkey', algo: 1);
      expect(GpgKeyGenerator.checkSpec(noLen, 'stubkey'),
          contains('requires at least 4096'));
    });
  });

  group('KeySpec', () {
    test('mirrors snapd generateTemplate (RSA 4096 SHA512, no Passphrase)',
        () {
      final params = KeySpec.params('my-key');
      expect(params.contains('Key-Type: RSA'), isTrue);
      expect(params.contains('Key-Length: 4096'), isTrue);
      expect(params.contains('Name-Real: my-key'), isTrue);
      expect(params.contains('Preferences: SHA512'), isTrue);
      // No Passphrase line: that is what keeps the pinentry prompt alive.
      // No expiry: snapd's template never expires, and we must not add one.
      expect(params.contains('Passphrase'), isFalse);
      expect(params.contains('Expire'), isFalse);
    });
  });

  group('generate (stub gpg)', () {
    test('pipes snapd\'s exact params on stdin to --gen-key', () async {
      final key = await generator().generate(name: 'stubkey');
      expect(key.name, 'stubkey');
      expect(key.fingerprint, '879876185CAF9C6893B9FCC5E57FCDC816DBDD4B');

      final params = File('${tmp.path}/params.txt').readAsStringSync();
      expect(params, KeySpec.params('stubkey'));
    });

    test('argv: --batch, no loopback/passphrase options (pinentry path)',
        () async {
      await generator().generate(name: 'stubkey');
      final args = File('${tmp.path}/genargs.txt').readAsStringSync();
      expect(args, contains('--batch'));
      expect(args, contains('--gen-key'));
      // The pinentry path must not hand the passphrase to gpg itself:
      expect(args, isNot(contains('--passphrase')));
      expect(args, isNot(contains('loopback')));
    });

    test('gpg failure: pinentry error surfaces the friendly hint', () async {
      // Drain stdin before dying: the real gpg reads the params blob even
      // when generation later fails. Without this the stub can exit before
      // the test finishes writing to it, racing the write into an EPIPE
      // (broken pipe) whose likelihood depends on builder CPU speed —
      // exactly what flaked on the arm64 Launchpad builder.
      installGpgStub('''#!/usr/bin/env bash
if [[ "\$*" == *"--list-secret-keys"* ]]; then exit 0; fi
cat > /dev/null
echo "gpg: agent_genkey failed: Inappropriate ioctl for device" >&2
echo "gpg: key generation failed: Inappropriate ioctl for device" >&2
exit 2
''');
      await expectLater(
        generator().generate(name: 'stubkey'),
        throwsA(isA<KeyGenerationException>()
            .having((e) => e.message, 'message', contains('pinentry'))),
      );
    });

    test('no key in keyring after gen => cancellation message', () async {
      // gen-key succeeds (stub exit 0) but list is empty.
      installGpgStub('''#!/usr/bin/env bash
if [[ "\$*" == *"--list-secret-keys"* ]]; then exit 0; fi
cat > /dev/null
exit 0
''');
      await expectLater(
        generator().generate(name: 'stubkey'),
        throwsA(isA<KeyGenerationException>()
            .having((e) => e.message, 'message',
                contains('no key was found'))),
      );
    });

    test('spec check runs: non-RSA listing is rejected', () async {
      installGpgStub('''#!/usr/bin/env bash
if [[ "\$*" == *"--list-secret-keys"* ]]; then
  printf '%s\\n' \\
    "sec:u:256:16:E57FCDC816DBDD4B:1792363345:::u:::escarESCA:::+:::23::0:" \\
    "fpr:::::::::879876185CAF9C6893B9FCC5E57FCDC816DBDD4B:" \\
    "uid:u::::1792363345::003E64CE9460FE899E4383C462E::stubkey::::::::::0:"
  exit 0
fi
cat > /dev/null
exit 0
''');
      await expectLater(
        generator().generate(name: 'stubkey'),
        throwsA(isA<KeyGenerationException>()
            .having((e) => e.message, 'message', contains('not an RSA key'))),
      );
    });
  });

  group('RustKeyService.createKey (wiring)', () {
    test('delegates to the generator with the key name', () async {
      final gen = _RecordingGenerator();
      final svc = RustKeyService(keyGenerator: gen);
      await svc.createKey('my-key');
      expect(gen.called, isTrue);
      expect(gen.lastName, 'my-key');
    });

    test('wraps KeyGenerationException into KeyException', () async {
      final gen =
          _RecordingGenerator(failure: const KeyGenerationException('nope'));
      final svc = RustKeyService(keyGenerator: gen);
      await expectLater(
        svc.createKey('k'),
        throwsA(isA<KeyException>()
            .having((e) => e.message, 'message', contains('nope'))),
      );
    });

    test('wraps unexpected errors into KeyException', () async {
      final gen = _RecordingGenerator(failure: StateError('boom'));
      final svc = RustKeyService(keyGenerator: gen);
      await expectLater(
        svc.createKey('k'),
        throwsA(isA<KeyException>()),
      );
    });
  });
}

class _RecordingGenerator extends GpgKeyGenerator {
  final Object? failure;

  _RecordingGenerator({this.failure}) : super(gpgBinary: 'unused-gpg');

  bool called = false;
  String? lastName;

  @override
  Future<CreatedKey> generate({
    required String name,
    Duration timeout = const Duration(seconds: 90),
  }) async {
    called = true;
    lastName = name;
    if (failure != null) throw failure!;
    return CreatedKey(name: name, fingerprint: 'STUB-FP');
  }
}
