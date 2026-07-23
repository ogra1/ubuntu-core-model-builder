import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yaru/yaru.dart';

import '../models/model_assertion.dart';
import '../models/wizard_step.dart';
import '../services/model_import_service.dart';

class MetadataPage extends StatelessWidget {
  final WizardState state;
  final VoidCallback onChanged;
  const MetadataPage({
    super.key,
    required this.state,
    required this.onChanged,
  });

  static const _prefLastImportDir = 'metadata.lastImportDir';

  ModelAssertion get model => state.model;

  Future<void> _import(BuildContext context) async {
    // Confirm if there is existing data to replace.
    final hasData = model.model != null || model.snaps.isNotEmpty;
    if (hasData) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Replace current model?'),
          content: const Text(
            'Importing will replace the model you are currently editing, '
            'including all snaps. This cannot be undone.',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Replace')),
          ],
        ),
      );
      if (ok != true) return;
    }

    // Open the picker at the last-used import directory, if any.
    final lastDir = await _loadLastImportDir();
    final file = await openFile(
      initialDirectory: lastDir,
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Model or JSON',
          extensions: ['model', 'json'],
        ),
      ],
    );
    if (file == null) return;

    // Remember the directory for next time.
    await _rememberImportDir(file.path);

    state.setBusy(true, message: 'Importing model...');
    try {
      final result = await ModelImportService()
          .importFromFile(file.path, reResolveAppBase: true);

      state.importModel(result.model);
      onChanged();

      final account = state.account;
      final mismatch = account != null &&
          result.importedBrandId != null &&
          result.importedBrandId != account.accountId;

      if (context.mounted && (result.warnings.isNotEmpty || mismatch)) {
        await _showImportNotes(
          context,
          warnings: result.warnings,
          mismatch: mismatch,
          importedBrandId: result.importedBrandId,
          accountId: account?.accountId,
        );
      } else if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text('Model imported.'),
          ),
        );
      }
    } on ModelImportException catch (e) {
      _error(context, e.message);
    } catch (e) {
      _error(context, 'Import failed: $e');
    } finally {
      state.busy = false;
    }
  }

  /// Shows import warnings and, on a brand-id mismatch, offers to replace the
  /// imported brand-id with the signed-in account so signing will succeed.
  Future<void> _showImportNotes(
    BuildContext context, {
    required List<String> warnings,
    required bool mismatch,
    required String? importedBrandId,
    required String? accountId,
  }) async {
    final messages = <String>[...warnings];
    if (mismatch) {
      messages.add(
        'Imported brand-id ($importedBrandId) differs from your signed-in '
        'account ($accountId). You will not be able to sign this model '
        'unless the brand-id matches. You can replace it with your account '
        'now, or keep it as imported.',
      );
    }

    final replace = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Imported with notes'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: messages
                .map((m) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text('• $m'),
                    ))
                .toList(),
          ),
        ),
        actions: [
          if (mismatch)
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep imported brand-id'),
            ),
          if (mismatch)
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Replace with my account'),
            ),
          if (!mismatch)
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('OK'),
            ),
        ],
      ),
    );

    if (replace == true && accountId != null) {
      // Overwrite brand-id AND authority-id with the current account, which
      // is what setAccount does (self-signed model: authority == brand).
      state.setAccount(state.account);
      onChanged();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text('Brand-id replaced with $accountId.'),
          ),
        );
      }
    }
  }

  Future<String?> _loadLastImportDir() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final dir = prefs.getString(_prefLastImportDir);
      return (dir != null && dir.isNotEmpty) ? dir : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _rememberImportDir(String pickedPath) async {
    final dir = _dirOf(pickedPath);
    if (dir == null || dir.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefLastImportDir, dir);
    } catch (_) {
      // Non-fatal.
    }
  }

  String? _dirOf(String path) {
    final idx = path.lastIndexOf(RegExp(r'[/\\]'));
    if (idx <= 0) return null;
    return path.substring(0, idx);
  }

  void _error(BuildContext context, String msg) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: Theme.of(context).colorScheme.errorContainer,
        content: Text(msg),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Text('Model Metadata',
                style: Theme.of(context).textTheme.headlineSmall),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: () => _import(context),
              icon: const Icon(Icons.file_open_outlined),
              label: const Text('Import model'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        YaruSection(
          headline: const Text('Model Identity'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                TextFormField(
                  key: ValueKey('model-${model.model}'),
                  initialValue: model.model,
                  decoration: const InputDecoration(
                    labelText: 'Model name',
                    helperText: 'Lowercase, alphanumeric and dashes',
                  ),
                  onChanged: (v) {
                    model.model = v;
                    onChanged();
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  key: ValueKey('brand-${model.brandId}'),
                  initialValue: model.brandId ?? 'Not signed in',
                  readOnly: true,
                  decoration: const InputDecoration(
                    labelText: 'Brand ID (auto)',
                    helperText: 'Derived from your store account',
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        YaruSection(
          headline: const Text('System'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                DropdownButtonFormField<ModelArchitecture>(
                  value: model.architecture,
                  decoration: const InputDecoration(labelText: 'Architecture'),
                  items: ModelArchitecture.values
                      .map((a) =>
                          DropdownMenuItem(value: a, child: Text(a.name)))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) model.architecture = v;
                    onChanged();
                  },
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  value: const ['core22', 'core24', 'core26']
                          .contains(model.base)
                      ? model.base
                      : null,
                  decoration: const InputDecoration(labelText: 'Base'),
                  items: const ['core22', 'core24', 'core26']
                      .map((b) => DropdownMenuItem(value: b, child: Text(b)))
                      .toList(),
                  onChanged: (v) {
                    model.base = v;
                    onChanged();
                  },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        YaruSection(
          headline: const Text('Grade'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SegmentedButton<ModelGrade>(
              segments: ModelGrade.values
                  .map((g) => ButtonSegment(value: g, label: Text(g.name)))
                  .toList(),
              selected: {model.grade},
              onSelectionChanged: (selection) {
                model.grade = selection.first;
                onChanged();
              },
            ),
          ),
        ),
      ],
    );
  }
}
