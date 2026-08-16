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

  final List<TextEditingController> _idControllers = [];
  final List<TextEditingController> _serialControllers = [];

  @override
  void initState() {
    super.initState();
    _syncControllers();
    _syncSerialControllers();
  }

  @override
  void dispose() {
    for (final c in _idControllers) {
      c.dispose();
    }
    for (final c in _serialControllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _syncControllers() {
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

  void _syncSerialControllers() {
    while (_serialControllers.length < model.serialAuthorityIds.length) {
      _serialControllers.add(TextEditingController(
          text: model.serialAuthorityIds[_serialControllers.length]));
    }
    while (_serialControllers.length > model.serialAuthorityIds.length) {
      _serialControllers.removeLast().dispose();
    }
    for (var i = 0; i < _serialControllers.length; i++) {
      final want = model.serialAuthorityIds[i];
      if (_serialControllers[i].text != want) {
        _serialControllers[i].text = want;
      }
    }
  }

  void _setMode(SystemUserAuthorityMode mode) {
    setState(() {
      model.systemUserAuthorityMode = mode;
      if (mode == SystemUserAuthorityMode.specificIds &&
          model.systemUserAuthorityIds.isEmpty) {
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

  // --- serial-authority handlers ---

  void _addSerialId() {
    setState(() {
      model.serialAuthorityIds = [...model.serialAuthorityIds, ''];
      _syncSerialControllers();
    });
    widget.onChanged();
  }

  void _removeSerialId(int index) {
    setState(() {
      final list = [...model.serialAuthorityIds]..removeAt(index);
      model.serialAuthorityIds = list;
      _syncSerialControllers();
    });
    widget.onChanged();
  }

  void _updateSerialId(int index, String value) {
    final list = [...model.serialAuthorityIds];
    list[index] = value;
    model.serialAuthorityIds = list;
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    _syncControllers();
    _syncSerialControllers();
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
                if (mode == SystemUserAuthorityMode.specificIds)
                  Padding(
                    padding: const EdgeInsets.only(left: 32, top: 4, bottom: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
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
                    ),
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
                if (mode == SystemUserAuthorityMode.anyone)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Container(
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
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        _buildSerialAuthoritySection(context),
        const SizedBox(height: 24),
        _buildValidationSetsSection(context),
        const SizedBox(height: 24),
        _buildStorageSafetySection(context),
      ],
    );
  }

  Widget _buildSerialAuthoritySection(BuildContext context) {
    return YaruSection(
      headline: const Text('Serial authority'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Account IDs allowed to sign serial assertions (device '
              'identities) for this model, in addition to your brand. Leave '
              'empty so only your brand can sign serials (the default).',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).hintColor,
                  ),
            ),
            const SizedBox(height: 12),
            if (_serialControllers.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('Brand only (default).',
                    style: Theme.of(context).textTheme.bodyMedium),
              )
            else
              ..._buildSerialEditors(context),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _addSerialId,
                icon: const Icon(Icons.add),
                label: const Text('Add serial-authority account ID'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildSerialEditors(BuildContext context) {
    final widgets = <Widget>[];
    for (var i = 0; i < _serialControllers.length; i++) {
      widgets.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _serialControllers[i],
                decoration: InputDecoration(
                  labelText: 'Account ID ${i + 1}',
                  isDense: true,
                ),
                onChanged: (v) => _updateSerialId(i, v),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Remove',
              onPressed: () => _removeSerialId(i),
            ),
          ],
        ),
      ));
    }
    return widgets;
  }

  Widget _buildStorageSafetySection(BuildContext context) {
    return YaruSection(
      headline: const Text('Storage safety'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Controls disk encryption for the device data partition. '
              'Leave at the default to use the grade-based behaviour '
              '(secured grade encrypts; otherwise it prefers encryption '
              'when the hardware supports it).',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).hintColor,
                  ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<StorageSafety>(
              value: model.storageSafety,
              decoration: const InputDecoration(labelText: 'storage-safety'),
              items: const [
                DropdownMenuItem(
                  value: StorageSafety.unset,
                  child: Text('Default (based on grade)'),
                ),
                DropdownMenuItem(
                  value: StorageSafety.encrypted,
                  child: Text('encrypted (require encryption)'),
                ),
                DropdownMenuItem(
                  value: StorageSafety.preferEncrypted,
                  child: Text('prefer-encrypted'),
                ),
                DropdownMenuItem(
                  value: StorageSafety.preferUnencrypted,
                  child: Text('prefer-unencrypted'),
                ),
              ],
              onChanged: (v) {
                setState(() =>
                    model.storageSafety = v ?? StorageSafety.unset);
                widget.onChanged();
              },
            ),
            if (model.grade == ModelGrade.secured &&
                model.storageSafety != StorageSafety.unset &&
                model.storageSafety != StorageSafety.encrypted) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline,
                        color: Theme.of(context).colorScheme.onErrorContainer),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'A "secured" grade model must not have storage-safety '
                        'overridden; only "encrypted" is valid. Signing will '
                        'fail. Choose "encrypted" or "Default (based on '
                        'grade)", or change the grade on the Metadata page.',
                        style: TextStyle(
                          color:
                              Theme.of(context).colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (model.storageSafety == StorageSafety.encrypted) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .primaryContainer
                      .withOpacity(0.4),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline,
                        color: Theme.of(context)
                            .colorScheme
                            .onPrimaryContainer),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'The image will require hardware-backed encryption '
                        '(TPM/secure boot). Devices without it will fail to '
                        'install.',
                        style: TextStyle(
                          color: Theme.of(context)
                              .colorScheme
                              .onPrimaryContainer,
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
    );
  }

  Widget _buildValidationSetsSection(BuildContext context) {
    final vsets = model.validationSets;
    return YaruSection(
      headline: const Text('Validation sets'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Optionally enforce one or more validation sets on the device. '
              'Each entry pins/constrains snaps per the set. Leave empty if '
              'not needed.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).hintColor,
                  ),
            ),
            const SizedBox(height: 12),
            if (vsets.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('No validation sets.',
                    style: Theme.of(context).textTheme.bodyMedium),
              )
            else
              for (var i = 0; i < vsets.length; i++)
                _buildValidationSetRow(context, i),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _addValidationSet,
                icon: const Icon(Icons.add),
                label: const Text('Add validation set'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildValidationSetRow(BuildContext context, int index) {
    final v = model.validationSets[index];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextFormField(
                  key: ValueKey('vset-account-$index-${v.accountId}'),
                  initialValue: v.accountId,
                  decoration: const InputDecoration(
                    labelText: 'Account ID',
                    isDense: true,
                  ),
                  onChanged: (val) {
                    v.accountId = val;
                    widget.onChanged();
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 3,
                child: TextFormField(
                  key: ValueKey('vset-name-$index-${v.name}'),
                  initialValue: v.name,
                  decoration: const InputDecoration(
                    labelText: 'Set name',
                    isDense: true,
                  ),
                  onChanged: (val) {
                    v.name = val;
                    widget.onChanged();
                  },
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Remove',
                onPressed: () => _removeValidationSet(index),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              SizedBox(
                width: 200,
                child: DropdownButtonFormField<String>(
                  value: v.mode,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Mode',
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem(
                        value: 'enforce', child: Text('enforce')),
                    DropdownMenuItem(
                        value: 'prefer-enforce',
                        child: Text('prefer-enforce')),
                  ],
                  onChanged: (val) {
                    setState(() => v.mode = val ?? 'enforce');
                    widget.onChanged();
                  },
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 160,
                child: TextFormField(
                  key: ValueKey('vset-seq-$index-${v.sequence}'),
                  initialValue: v.sequence?.toString() ?? '',
                  decoration: const InputDecoration(
                    labelText: 'Sequence (optional)',
                    isDense: true,
                  ),
                  keyboardType: TextInputType.number,
                  onChanged: (val) {
                    final t = val.trim();
                    v.sequence = t.isEmpty ? null : int.tryParse(t);
                    widget.onChanged();
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _addValidationSet() {
    setState(() {
      model.validationSets.add(ValidationSetRef(
        accountId: model.brandId ?? '',
        name: '',
        mode: 'enforce',
      ));
    });
    widget.onChanged();
  }

  void _removeValidationSet(int index) {
    setState(() => model.validationSets.removeAt(index));
    widget.onChanged();
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
              onPressed:
                  _idControllers.length > 1 ? () => _removeId(i) : null,
            ),
          ],
        ),
      ));
    }
    return widgets;
  }
}
