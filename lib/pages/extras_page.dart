import 'package:flutter/material.dart';
import 'package:yaru/yaru.dart';

import '../models/model_assertion.dart';
import '../models/wizard_step.dart';

class ExtrasPage extends StatefulWidget {
  final WizardState state;
  final VoidCallback onChanged;
  const ExtrasPage({
    super.key,
    required this.state,
    required this.onChanged,
  });

  @override
  State<ExtrasPage> createState() => _ExtrasPageState();
}

class _ExtrasPageState extends State<ExtrasPage> {
  ModelAssertion get model => widget.state.model;

  // Controllers for the specific-IDs list. Rebuilt when the ids list changes
  // in a way that adds/removes rows.
  final List<TextEditingController> _idControllers = [];

  @override
  void initState() {
    super.initState();
    _syncControllers();
  }

  @override
  void dispose() {
    for (final c in _idControllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _syncControllers() {
    // Ensure one controller per id, preserving existing text.
    while (_idControllers.length < model.systemUserAuthorityIds.length) {
      _idControllers.add(TextEditingController(
          text: model.systemUserAuthorityIds[_idControllers.length]));
    }
    while (_idControllers.length > model.systemUserAuthorityIds.length) {
      _idControllers.removeLast().dispose();
    }
    for (var i = 0; i < _idControllers.length; i++) {
      final want = model.systemUserAuthorityIds[i];
      if (_idControllers[i].text != want) {
        _idControllers[i].text = want;
      }
    }
  }

  void _setMode(SystemUserAuthorityMode mode) {
    setState(() {
      model.systemUserAuthorityMode = mode;
      if (mode == SystemUserAuthorityMode.specificIds &&
          model.systemUserAuthorityIds.isEmpty) {
        // Start with one empty row for convenience.
        model.systemUserAuthorityIds = [''];
        _syncControllers();
      }
    });
    widget.onChanged();
  }

  void _addId() {
    setState(() {
      model.systemUserAuthorityIds = [...model.systemUserAuthorityIds, ''];
      _syncControllers();
    });
    widget.onChanged();
  }

  void _removeId(int index) {
    setState(() {
      final list = [...model.systemUserAuthorityIds]..removeAt(index);
      model.systemUserAuthorityIds = list;
      _syncControllers();
    });
    widget.onChanged();
  }

  void _updateId(int index, String value) {
    final list = [...model.systemUserAuthorityIds];
    list[index] = value;
    model.systemUserAuthorityIds = list;
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    _syncControllers();
    final mode = model.systemUserAuthorityMode;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Extras', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(
          'Optional model settings. Leave these at their defaults if you '
          'do not need them.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).hintColor,
              ),
        ),
        const SizedBox(height: 24),
        YaruSection(
          headline: const Text('System-user authority'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Controls who may sign the system-user assertions this '
                  'device will accept (used for creating local users).',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).hintColor,
                      ),
                ),
                const SizedBox(height: 16),
                RadioListTile<SystemUserAuthorityMode>(
                  contentPadding: EdgeInsets.zero,
                  value: SystemUserAuthorityMode.brandOnly,
                  groupValue: mode,
                  onChanged: (v) => _setMode(v!),
                  title: const Text('Brand only (default)'),
                  subtitle: const Text(
                      'Only your brand account can sign system-user '
                      'assertions. Nothing is added to the model.'),
                ),
                RadioListTile<SystemUserAuthorityMode>(
                  contentPadding: EdgeInsets.zero,
                  value: SystemUserAuthorityMode.specificIds,
                  groupValue: mode,
                  onChanged: (v) => _setMode(v!),
                  title: const Text('Specific account IDs'),
                  subtitle: const Text(
                      'Allow one or more account IDs to sign system-user '
                      'assertions for this device.'),
                ),
                RadioListTile<SystemUserAuthorityMode>(
                  contentPadding: EdgeInsets.zero,
                  value: SystemUserAuthorityMode.anyone,
                  groupValue: mode,
                  onChanged: (v) => _setMode(v!),
                  title: const Text('Anyone'),
                  subtitle: const Text(
                      'Any account may sign system-user assertions (uses "*").'),
                ),
                if (mode == SystemUserAuthorityMode.specificIds) ...[
                  const SizedBox(height: 8),
                  ..._buildIdEditors(context),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _addId,
                      icon: const Icon(Icons.add),
                      label: const Text('Add account ID'),
                    ),
                  ),
                ],
                if (mode == SystemUserAuthorityMode.anyone) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .errorContainer
                          .withOpacity(0.5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.warning_amber,
                            color: Theme.of(context)
                                .colorScheme
                                .onErrorContainer),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Allowing anyone to sign system-user assertions '
                            'is a significant security relaxation. Only use '
                            'this if you understand the implications.',
                            style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onErrorContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildIdEditors(BuildContext context) {
    final widgets = <Widget>[];
    for (var i = 0; i < _idControllers.length; i++) {
      widgets.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _idControllers[i],
                decoration: InputDecoration(
                  labelText: 'Account ID ${i + 1}',
                  isDense: true,
                ),
                onChanged: (v) => _updateId(i, v),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Remove',
              onPressed: _idControllers.length > 1
                  ? () => _removeId(i)
                  : null,
            ),
          ],
        ),
      ));
    }
    return widgets;
  }
}
