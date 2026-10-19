import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ubuntu_core_model_builder/models/model_assertion.dart';
import 'package:ubuntu_core_model_builder/models/snap_entry.dart';
import 'package:ubuntu_core_model_builder/services/sign_service.dart';

/// A base64-ish signature block (>= 40 chars, valid base64 charset) that
/// `snap sign` would emit after the blank-line separator.
const String kSig = 'MEUCIQDx3Jp2oQnL5k9mR7vT1wZ4yU6aB8cE0fGhIjKlMnOpQIg';

ModelAssertion validModel() {
  return ModelAssertion()
    ..authorityId = 'abc123'
    ..brandId = 'abc123'
    ..model = 'my-device'
    ..base = 'core24'
    ..snaps = [
      SnapEntry(
          name: 'pc-kernel',
          id: 'y' * 32,
          type: SnapType.kernel,
          defaultChannel: '24/stable'),
      SnapEntry(
          name: 'pc',
          id: 'z' * 32,
          type: SnapType.gadget,
          defaultChannel: '24/stable'),
    ];
}

void main() {
  late Directory tmp;
  late File fakeSnap;

  /// Installs a bash stub as the "snap" executable. [script] is the stub
  /// body; [sig] is baked in as the shell variable [extracted] (default SIG)
  /// so stubs can reference the signature value.
  void installStub(String script, {String sig = kSig}) {
    // The real `snap sign` reads ALL of stdin before doing anything
    // (cmd_sign.go: io.ReadAll(Stdin) precedes the key lookup). A stub that
    // never consumes stdin would exit while the service writes the JSON
    // header, racing a broken pipe (SocketException EPIPE). Prepend a drain
    // unless the stub already consumes stdin (the header-capture stub uses
    // `cat > "$3"`).
    final body =
        script.contains('cat >') ? script : 'cat > /dev/null\n$script';
    fakeSnap.writeAsStringSync('#!/usr/bin/env bash\nSIG="$sig"\n$body\n');
    Process.runSync('chmod', ['+x', fakeSnap.path]);
  }

  SignService service() => SignService(snapExecutable: fakeSnap.path);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sign_service_test.');
    fakeSnap = File('${tmp.path}/snap');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('signModel validation', () {
    test('rejects a blank key name before spawning anything', () async {
      // A non-existent executable would throw a "Could not run" message if
      // the process were started; the blank-key guard must fire first.
      final svc = SignService(snapExecutable: '${tmp.path}/does-not-exist');
      for (final key in ['', '   ', '\t']) {
        expect(
          () => svc.signModel(validModel(), key),
          throwsA(isA<SignException>()
              .having((e) => e.message, 'message',
                  'No signing key selected.')),
          reason: 'key "$key"',
        );
      }
    });

    test('throws SignException when the executable is missing', () async {
      final svc = SignService(snapExecutable: '${tmp.path}/does-not-exist');
      expect(
        () => svc.signModel(validModel(), 'my-key'),
        throwsA(isA<SignException>()
            .having((e) => e.message, 'message', contains('Could not run'))),
      );
    });
  });

  group('signModel happy path', () {
    test('returns the signed assertion and the JSON header it sent',
        () async {
      // Capture the JSON header the service feeds on stdin by routing it
      // through the key-name argument ($3): the stub writes stdin there.
      final capture = '${tmp.path}/captured-stdin';
      installStub('''
cat > "\$3"
printf 'type: model\\n'
printf 'authority-id: abc123\\n'
printf 'brand-id: abc123\\n'
printf 'model: my-device\\n'
printf 'sign-key-sha3-384: a1b2c3d4e5f6\\n'
printf '\\n'
printf '%s\\n' "\$SIG"
''');
      final result = await service().signModel(validModel(), capture);

      // Output is the flat signed-assertion format.
      expect(result.signedAssertion, contains('type: model'));
      expect(result.signedAssertion.trim().endsWith(kSig), isTrue);

      // The header the service sent is the buildJson of the model.
      final header = jsonDecode(result.jsonHeader) as Map<String, dynamic>;
      expect(header['model'], 'my-device');
      expect(header['brand-id'], 'abc123');

      // The service must have fed exactly that JSON header to the tool.
      expect(File(capture).readAsStringSync(), result.jsonHeader);
    });

    test('accepts a CRLF-terminated signature', () async {
      installStub(
          'printf "type: model\\r\\nmodel: my-device\\r\\n\\r\\n%s\\r\\n" "\$SIG"');
      final result = await service().signModel(validModel(), 'k');
      expect(result.signedAssertion, contains(kSig));
    });
  });

  group('signModel output validation', () {
    test('rejects output without a "type: model" header', () async {
      installStub('printf "some random output\\n\\n%s\\n" "\$SIG"');
      await expectLater(
        service().signModel(validModel(), 'k'),
        throwsA(isA<SignException>().having(
            (e) => e.message,
            'message',
            contains('does not look like a signed assertion'))),
      );
    });

    test('rejects output with no blank-line separator', () async {
      installStub('printf "type: model\\nmodel: my-device\\n"');
      await expectLater(
        service().signModel(validModel(), 'k'),
        throwsA(isA<SignException>().having(
            (e) => e.message,
            'message',
            contains('does not look like a signed assertion'))),
      );
    });

    test('rejects a blank signature block', () async {
      installStub('printf "type: model\\nmodel: my-device\\n\\n\\n"');
      await expectLater(
        service().signModel(validModel(), 'k'),
        throwsA(isA<SignException>().having(
            (e) => e.message,
            'message',
            contains('does not look like a signed assertion'))),
      );
    });

    test('rejects a too-short signature block', () async {
      installStub('printf "type: model\\n\\nshort\\n"');
      await expectLater(
        service().signModel(validModel(), 'k'),
        throwsA(isA<SignException>().having(
            (e) => e.message,
            'message',
            contains('does not look like a signed assertion'))),
      );
    });

    test('rejects a non-base64 signature block', () async {
      // 45 chars (passes the length floor) but full of invalid base64 chars.
      installStub(
          'printf "type: model\\n\\n%s\\n" "!!!not-base64-at-all-xxxxxxxxxxxxxxxxxxxxxxxx"');
      await expectLater(
        service().signModel(validModel(), 'k'),
        throwsA(isA<SignException>().having(
            (e) => e.message,
            'message',
            contains('does not look like a signed assertion'))),
      );
    });

    test('treats a non-zero exit as failure before validating output',
        () async {
      installStub('''
echo "cannot find key pair: no such key: k" >&2
exit 1
''');
      await expectLater(
        service().signModel(validModel(), 'k'),
        throwsA(isA<SignException>().having(
            (e) => e.message,
            'message',
            contains('was not found in the local keyring'))),
      );
    });
  });

  group('signModel error mapping', () {
    test('maps a missing key', () async {
      installStub('''
echo "cannot find key pair" >&2
exit 1
''');
      await expectLater(
        service().signModel(validModel(), 'missing'),
        throwsA(isA<SignException>().having((e) => e.message, 'message',
            contains('not found in the local keyring'))),
      );
    });

    test('maps a bad passphrase', () async {
      installStub('''
echo "gpg: bad passphrase" >&2
exit 1
''');
      await expectLater(
        service().signModel(validModel(), 'k'),
        throwsA(isA<SignException>()
            .having((e) => e.message, 'message', contains('passphrase'))),
      );
    });

    test('maps a missing pinentry (no tty)', () async {
      installStub('''
echo "gpg: pinentry: Inappropriate ioctl for device" >&2
exit 1
''');
      await expectLater(
        service().signModel(validModel(), 'k'),
        throwsA(isA<SignException>()
            .having((e) => e.message, 'message', contains('pinentry'))),
      );
    });

    test('maps rejected assertion data (json error)', () async {
      installStub('''
echo "error: cannot process json input" >&2
exit 1
''');
      await expectLater(
        service().signModel(validModel(), 'k'),
        throwsA(isA<SignException>().having(
            (e) => e.message, 'message', contains('rejected by snap sign'))),
      );
    });

    test('falls back to the combined tool output for unknown errors',
        () async {
      const marker = 'weird-tool-failure-xyz';
      installStub('''
echo "some obscure failure"
echo "$marker" >&2
exit 3
''');
      await expectLater(
        service().signModel(validModel(), 'k'),
        throwsA(isA<SignException>().having(
            (e) => e.message,
            'message',
            allOf(contains('Signing failed'), contains(marker)))),
      );
    });
  });

  group('signModel timeout', () {
    test('throws the timeout error and kills the process', () async {
      // Sleep keeps the process alive past the (short) deadline so the
      // timeout path fires and the process is killed.
      installStub('exec sleep 30');
      await expectLater(
        service().signModel(validModel(), 'k',
            timeout: const Duration(milliseconds: 300)),
        throwsA(isA<SignException>()
            .having((e) => e.message, 'message', contains('timed out'))),
      );
    });
  });

  group('saveToFile', () {
    test('writes the assertion and returns the file', () async {
      final path = '${tmp.path}/out.model';
      final file = await service().saveToFile('signed-content', path);
      expect(file.path, path);
      expect(await file.readAsString(), 'signed-content');
    });
  });

  group('SignException', () {
    test('toString returns the message', () {
      expect(SignException('boom').toString(), 'boom');
    });
  });
}
