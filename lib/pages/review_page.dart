import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:yaru/yaru.dart';

import '../models/wizard_step.dart';
import '../services/assertion_builder.dart';
import '../services/assertion_verifier.dart';
import '../services/snapcraft_service.dart';
import '../widgets/verification_report_view.dart';

class ReviewPage extends StatefulWidget {
  final WizardState state;
  const ReviewPage({super.key, required this.state});

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage> {
  VerificationReport? _report;
  String? _savedPath;

  Future<void> _sign() async {
    final keyName = widget.state.selectedKeyName;
    if (keyName == null) return;

    widget.state.busy = true;
    try {
      final result =
          await SnapcraftService().signModel(widget.state.model, keyName);

      final report = await AssertionVerifier().verify(
        signedAssertion: result.signedAssertion,
        originalModel: widget.state.model,
        signingKeyName: keyName,
      );

      setState(() {
        _report = report;
        widget.state.signedAssertion =
            report.allPassed ? result.signedAssertion : null;
      });
      widget.state.refresh();

      if (!report.allPassed) {
        _showError('Signed, but verification found problems. See report.');
      }
    } on AssertionBuildException catch (e) {
      _showErrors(e.errors);
    } on SignException catch (e) {
      _showError(e.message);
    } catch (e) {
      _showError(e.toString());
    } finally {
      widget.state.busy = false;
    }
  }

  Future<void> _save() async {
    final signed = widget.state.signedAssertion;
    if (signed == null) return;

    final suggested = '${widget.state.model.model ?? "model"}.model';
    final location = await getSaveLocation(
      suggestedName: suggested,
      acceptedTypeGroups: [
        const XTypeGroup(label: 'Model assertion', extensions: ['model']),
      ],
    );
    if (location == null) return;

    await SnapcraftService().saveToFile(signed, location.path);
    setState(() => _savedPath = location.path);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Saved to ${location.path}'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _testImport() async {
    final path = _savedPath;
    if (path == null) {
      _showError('Save the assertion to a file first.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Test import into snapd?'),
        content: const Text(
          'This runs "snap ack" to cryptographically verify the full '
          'signature chain. It will add the assertion to this system '
          'assertion database.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Run snap ack')),
        ],
      ),
    );
    if (confirmed != true) return;

    widget.state.busy = true;
    try {
      final check = await AssertionVerifier().verifyViaSnapAck(path);
      setState(() {
        _report = VerificationReport([...?_report?.checks, check]);
      });
    } finally {
      widget.state.busy = false;
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Theme.of(context).colorScheme.errorContainer,
      ),
    );
  }

  void _showErrors(List<String> errors) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Cannot build assertion'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: errors.map((e) => Text('- $e')).toList(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final signed = widget.state.signedAssertion;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Review & Sign',
            style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 24),
        YaruSection(
          headline: const Text('Assertion preview'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: _buildPreview(),
          ),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            ElevatedButton.icon(
              onPressed: _sign,
              icon: const Icon(Icons.draw_outlined),
              label: const Text('Sign model'),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: signed == null ? null : _save,
              icon: const Icon(Icons.save_outlined),
              label: const Text('Save .model'),
            ),
          ],
        ),
        if (_report != null) ...[
          const SizedBox(height: 24),
          VerificationReportView(
            report: _report!,
            onTestImport: signed == null ? null : _testImport,
          ),
        ],
        if (signed != null) ...[
          const SizedBox(height: 24),
          YaruSection(
            headline: const Text('Signed assertion'),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SelectableText(
                signed,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildPreview() {
    try {
      final preview = AssertionBuilder.buildJson(widget.state.model);
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: SelectableText(
          preview,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        ),
      );
    } on AssertionBuildException catch (e) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: e.errors
            .map((err) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline,
                          size: 16,
                          color: Theme.of(context).colorScheme.error),
                      const SizedBox(width: 8),
                      Expanded(child: Text(err)),
                    ],
                  ),
                ))
            .toList(),
      );
    }
  }
}
