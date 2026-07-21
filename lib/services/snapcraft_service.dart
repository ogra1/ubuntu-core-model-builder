import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/model_assertion.dart';
import 'assertion_builder.dart';

class SignResult {
  final String signedAssertion;
  final String jsonHeader;
  SignResult({required this.signedAssertion, required this.jsonHeader});
}

class SnapcraftService {
  Future<SignResult> signModel(
    ModelAssertion model,
    String keyName, {
    Duration timeout = const Duration(minutes: 2),
  }) async {
    if (keyName.trim().isEmpty) {
      throw SignException('No signing key selected.');
    }

    final jsonHeader = AssertionBuilder.buildJson(model);

    final Process process;
    try {
      process = await Process.start('snap', ['sign', '-k', keyName]);
    } on ProcessException catch (e) {
      throw SignException(
        'Could not run "snap sign". Is snapd installed?\n${e.message}',
      );
    }

    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    final stderrFuture = process.stderr.transform(utf8.decoder).join();

    process.stdin.write(jsonHeader);
    await process.stdin.flush();
    await process.stdin.close();

    final int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigterm);
      throw SignException(
        'Signing timed out. If your key has a passphrase, snap sign may be '
        'waiting for input it cannot prompt for here. Consider using a key '
        'without a passphrase, or ensure a graphical pinentry is available.',
      );
    }

    final signed = await stdoutFuture;
    final errText = await stderrFuture;

    if (exitCode != 0) {
      throw SignException(_friendlyError(errText, signed, keyName));
    }
    if (signed.trim().isEmpty) {
      throw SignException('snap sign produced no output.\n$errText');
    }

    if (!_looksLikeSignedAssertion(signed)) {
      throw SignException(
        'Unexpected output from snap sign - it does not look like a '
        'signed assertion.\n\n--- stdout ---\n$signed\n'
        '${errText.trim().isNotEmpty ? "\n--- stderr ---\n$errText" : ""}',
      );
    }

    return SignResult(signedAssertion: signed, jsonHeader: jsonHeader);
  }

  /// A signed assertion begins with header lines (including "type: model")
  /// and ends with a base64 signature block separated by a blank line.
  bool _looksLikeSignedAssertion(String output) {
    final text = output.replaceAll('\r\n', '\n').trim();

    // Must contain the type header.
    if (!text.contains('type: model')) return false;

    // Must have a blank-line separator before a trailing signature block.
    final blankIdx = text.indexOf('\n\n');
    if (blankIdx < 0) return false;

    final signatureBlock = text.substring(blankIdx).trim();
    if (signatureBlock.isEmpty) return false;

    // The signature block is base64-ish: mostly [A-Za-z0-9+/=] and newlines,
    // and reasonably long. Accept if it's substantial and mostly base64.
    final compact = signatureBlock.replaceAll(RegExp(r'\s'), '');
    if (compact.length < 40) return false;

    final base64ish = RegExp(r'^[A-Za-z0-9+/=_-]+$');
    return base64ish.hasMatch(compact);
  }

  Future<File> saveToFile(String signedAssertion, String path) async {
    final file = File(path);
    await file.writeAsString(signedAssertion);
    return file;
  }

  String _friendlyError(String stderr, String stdout, String keyName) {
    final blob = '$stderr\n$stdout'.toLowerCase();

    if (blob.contains('cannot find key pair') ||
        blob.contains('no such key') ||
        blob.contains('cannot use') && blob.contains('key')) {
      return 'Key "$keyName" was not found in the local keyring. '
          'Create it in the Signing Key step.';
    }
    if (blob.contains('bad passphrase') || blob.contains('passphrase')) {
      return 'Incorrect or missing passphrase for key "$keyName". '
          'snap sign cannot prompt for a passphrase here.';
    }
    if (blob.contains('inappropriate ioctl') || blob.contains('pinentry')) {
      return 'snap sign needs to prompt for the key passphrase but has no '
          'terminal. Use a key without a passphrase, or ensure a graphical '
          'pinentry (pinentry-gnome3) is installed and configured.';
    }
    if (blob.contains('json') || blob.contains('parse') ||
        blob.contains('cannot process')) {
      return 'The assertion data was rejected by snap sign. Please review '
          'the metadata.\n\n${stderr.trim()}\n${stdout.trim()}';
    }
    final combined = [stderr.trim(), stdout.trim()]
        .where((s) => s.isNotEmpty)
        .join('\n');
    return 'Signing failed:\n$combined';
  }
}

class SignException implements Exception {
  final String message;
  SignException(this.message);
  @override
  String toString() => message;
}
