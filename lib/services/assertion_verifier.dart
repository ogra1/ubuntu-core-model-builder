import 'dart:io';

import '../models/model_assertion.dart';
import 'assertion_parser.dart';
import 'host_env.dart';
import 'key_service.dart';

enum CheckStatus { pass, warn, fail }

class VerificationCheck {
  final String label;
  final CheckStatus status;
  final String detail;

  VerificationCheck(this.label, this.status, this.detail);
}

class VerificationReport {
  final List<VerificationCheck> checks;

  VerificationReport(this.checks);

  bool get allPassed => checks.every((c) => c.status != CheckStatus.fail);
  bool get hasWarnings => checks.any((c) => c.status == CheckStatus.warn);
}

class AssertionVerifier {
  final KeyService _keyService;

  AssertionVerifier({KeyService? keyService})
      : _keyService = keyService ?? KeyService();

  Future<VerificationReport> verify({
    required String signedAssertion,
    required ModelAssertion originalModel,
    required String signingKeyName,
  }) async {
    final checks = <VerificationCheck>[];

    ParsedAssertion parsed;
    try {
      parsed = AssertionParser.parse(signedAssertion);
      checks.add(VerificationCheck(
        'Structure',
        CheckStatus.pass,
        'Assertion parsed successfully with a signature block.',
      ));
    } on AssertionParseException catch (e) {
      checks.add(VerificationCheck('Structure', CheckStatus.fail, e.message));
      return VerificationReport(checks);
    }

    _checkEqual(checks, 'Type', 'model', parsed.type);
    _checkEqual(checks, 'Model name', originalModel.model, parsed.model);
    _checkEqual(
        checks, 'Authority ID', originalModel.authorityId, parsed.authorityId);
    _checkEqual(checks, 'Brand ID', originalModel.brandId, parsed.brandId);

    await _checkSigningKey(checks, parsed, signingKeyName);

    if (parsed.signature.length < 32) {
      checks.add(VerificationCheck(
        'Signature',
        CheckStatus.fail,
        'Signature block is suspiciously short.',
      ));
    } else {
      checks.add(VerificationCheck(
        'Signature',
        CheckStatus.pass,
        'Signature block present (${parsed.signature.length} chars).',
      ));
    }

    return VerificationReport(checks);
  }

  void _checkEqual(
    List<VerificationCheck> checks,
    String label,
    String? expected,
    String? actual,
  ) {
    if (expected == null) return;
    if (expected == actual) {
      checks.add(VerificationCheck(label, CheckStatus.pass, actual!));
    } else {
      checks.add(VerificationCheck(
        label,
        CheckStatus.fail,
        'Expected "$expected" but assertion contains "$actual".',
      ));
    }
  }

  Future<void> _checkSigningKey(
    List<VerificationCheck> checks,
    ParsedAssertion parsed,
    String signingKeyName,
  ) async {
    final signKeyHash = parsed.signKeySha3384;
    if (signKeyHash == null || signKeyHash.isEmpty) {
      checks.add(VerificationCheck(
        'Signing key',
        CheckStatus.warn,
        'Assertion has no sign-key-sha3-384 header to cross-check.',
      ));
      return;
    }

    final keys = await _keyService.listKeys();
    SigningKey? local;
    for (final k in keys) {
      if (k.name == signingKeyName) {
        local = k;
        break;
      }
    }

    if (local == null) {
      checks.add(VerificationCheck(
        'Signing key',
        CheckStatus.warn,
        'Local key "$signingKeyName" not found to compare hashes.',
      ));
      return;
    }

    if (local.sha3384 == signKeyHash) {
      checks.add(VerificationCheck(
        'Signing key',
        CheckStatus.pass,
        'Signed by "$signingKeyName" (hash matches local key).',
      ));
    } else {
      checks.add(VerificationCheck(
        'Signing key',
        CheckStatus.fail,
        'Assertion was signed by a different key than expected.\n'
        'Expected: ${local.sha3384}\nFound:    $signKeyHash',
      ));
    }

    if (!local.registered) {
      checks.add(VerificationCheck(
        'Key registration',
        CheckStatus.warn,
        'Signing key is not registered with the store; the assertion '
        'may be rejected when deployed.',
      ));
    } else {
      checks.add(VerificationCheck(
        'Key registration',
        CheckStatus.pass,
        'Signing key is registered with the store.',
      ));
    }
  }

  Future<VerificationCheck> verifyViaSnapAck(String assertionFilePath) async {
    final result = await Process.run(
      'snap',
      ['ack', assertionFilePath],
      environment: HostEnv.sanitized,
      includeParentEnvironment: false,
    );
    if (result.exitCode == 0) {
      return VerificationCheck(
        'snapd acknowledgement',
        CheckStatus.pass,
        'snapd cryptographically verified and accepted the assertion.',
      );
    }
    return VerificationCheck(
      'snapd acknowledgement',
      CheckStatus.fail,
      'snapd rejected the assertion:\n${result.stderr}',
    );
  }
}
