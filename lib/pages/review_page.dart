import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
  static const _prefAlsoSaveJson = 'review.alsoSaveJson';
  static const _prefLastSaveDir = 'review.lastSaveDir';

  VerificationReport? _report;
  String? _savedPath;
  String? _jsonHeader; // the unsigned JSON that was signed
  bool _alsoSaveJson = false; // default unchecked; overridden by saved pref
  String? _lastSaveDir; // remembered across sessions

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getBool(_prefAlsoSaveJson);
      final dir = prefs.getString(_prefLastSaveDir);
      if (mounted) {
        setState(() {
          if (saved != null) _alsoSaveJson = saved;
          if (dir != null && dir.isNotEmpty) _lastSaveDir = dir;
        });
      }
    } catch (_) {
      // If prefs are unavailable, keep the default (false).
    }
  }

  Future<void> _setAlsoSaveJson(bool value) async {
    setState(() => _alsoSaveJson = value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefAlsoSaveJson, value);
    } catch (_) {
      // Non-fatal: the choice just won't persist this time.
    }
  }

  Future<void> _rememberSaveDir(String savedPath) async {
    final dir = _dirOf(savedPath);
    if (dir == null || dir.isEmpty) return;
    _lastSaveDir = dir;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefLastSaveDir, dir);
    } catch (_) {
      // Non-fatal; the directory just won't persist this time.
    }
  }

  /// Returns the directory portion of a file path, or null if none.
  String? _dirOf(String path) {
    final idx = path.lastIndexOf(RegExp(r'[/\\]'));
    if (idx <= 0) return null;
    return path.substring(0, idx);
  }

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
        _jsonHeader = result.jsonHeader;
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

    final modelName = widget.state.model.model ?? 'model';
    final suggested = '$modelName.model';
    final location = await getSaveLocation(
      suggestedName: suggested,
      initialDirectory: _lastSaveDir,
      acceptedTypeGroups: [
        const XTypeGroup(label: 'Model assertion', extensions: ['model']),
      ],
    );
    if (location == null) return;

    final svc = SnapcraftService();
    await svc.saveToFile(signed, location.path);
    setState(() => _savedPath = location.path);

    // Remember the directory for next time.
    await _rememberSaveDir(location.path);

    String? jsonPath;
    if (_alsoSaveJson && _jsonHeader != null) {
      jsonPath = _jsonSiblingPath(location.path);
      try {
        await svc.saveToFile(_jsonHeader!, jsonPath);
      } catch (e) {
        jsonPath = null;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              behavior: SnackBarBehavior.floating,
              backgroundColor: Theme.of(context).colorScheme.errorContainer,
              content: Text('Saved .model but failed to save JSON: $e'),
            ),
          );
        }
      }
    }

    if (mounted) {
      final msg = jsonPath != null
          ? 'Saved ${location.path}\nand $jsonPath'
          : 'Saved ${location.path}';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  String _jsonSiblingPath(String modelPath) {
    final dot = modelPath.lastIndexOf('.');
    final slash = modelPath.lastIndexOf(RegExp(r'[/\\]'));
    if (dot > slash) {
      return '${modelPath.substring(0, dot)}.json';
    }
    return '$modelPath.json';
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
            const SizedBox(width: 12),
            InkWell(
              onTap: (_jsonHeader == null)
                  ? null
                  : () => _setAlsoSaveJson(!_alsoSaveJson),
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      value: _alsoSaveJson,
                      onChanged: (_jsonHeader == null)
                          ? null
                          : (v) => _setAlsoSaveJson(v ?? false),
                    ),
                    Text(
                      'Also save unsigned .json',
                      style: TextStyle(
                        color: _jsonHeader == null
                            ? Theme.of(context).disabledColor
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
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
