import '../theme/status_colors.dart';
import 'package:flutter/material.dart';
import 'package:yaru/yaru.dart';

import '../models/wizard_step.dart';
import '../services/key_service.dart';

class KeysPage extends StatefulWidget {
  final WizardState state;
  const KeysPage({super.key, required this.state});

  @override
  State<KeysPage> createState() => _KeysPageState();
}

class _KeysPageState extends State<KeysPage> {
  final KeyService _keyService = KeyService();

  List<SigningKey> _keys = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadKeys();
  }

  Future<void> _loadKeys() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final keys = await _keyService.listKeys();
      if (!mounted) return;
      setState(() => _keys = keys);

      final selected = widget.state.selectedKeyName;
      if (selected != null && !keys.any((k) => k.name == selected)) {
        widget.state.selectedKeyName = null;
        widget.state.refresh();
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _selectKey(SigningKey key) {
    if (!key.registered) {
      _promptRegister(key);
      return;
    }
    widget.state.selectedKeyName = key.name;
    widget.state.refresh();
    setState(() {});
  }

  Future<void> _promptRegister(SigningKey key) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Register "${key.name}"?'),
        content: const Text(
          'This key exists locally but is not registered with the '
          'Snap Store. It must be registered before it can sign a '
          'model the store will accept.\n\n'
          'You may be prompted for the key passphrase.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Register'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _runKeyOp(() => _keyService.registerKey(key.name));
  }

  Future<void> _createKey() async {
    final result = await showDialog<_NewKeyResult>(
      context: context,
      builder: (_) => const _CreateKeyDialog(),
    );
    if (result == null) return;

    await _runKeyOp(() async {
      if (result.register) {
        await _keyService.createAndRegister(result.name);
      } else {
        await _keyService.createKey(result.name);
      }
    });
  }

  Future<void> _runKeyOp(Future<void> Function() op) async {
    widget.state.busy = true;
    try {
      await op();
      await _loadKeys();
    } on KeyException catch (e) {
      _showError(e.message);
    } catch (e) {
      _showError(e.toString());
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

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Text('Signing Key',
                style: Theme.of(context).textTheme.headlineSmall),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: _loading ? null : _loadKeys,
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh'),
            ),
            const SizedBox(width: 12),
            ElevatedButton.icon(
              onPressed: _loading ? null : _createKey,
              icon: const Icon(Icons.add),
              label: const Text('New key'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Select a registered key to sign your model. '
          'Only registered keys can produce store-valid assertions.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).hintColor,
              ),
        ),
        const SizedBox(height: 24),
        if (_loading)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(48),
              child: CircularProgressIndicator(),
            ),
          )
        else if (_error != null)
          _ErrorBanner(message: _error!, onRetry: _loadKeys)
        else if (_keys.isEmpty)
          _EmptyState(onCreate: _createKey)
        else
          _buildKeyList(),
      ],
    );
  }

  Widget _buildKeyList() {
    final selectedName = widget.state.selectedKeyName;
    return YaruSection(
      headline: const Text('Available keys'),
      child: Column(
        children: _keys
            .map((key) => _KeyTile(
                  key: ValueKey(key.name),
                  signingKey: key,
                  selected: key.name == selectedName,
                  onSelect: () => _selectKey(key),
                  onRegister: () => _promptRegister(key),
                ))
            .toList(),
      ),
    );
  }
}

class _KeyTile extends StatelessWidget {
  final SigningKey signingKey;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onRegister;

  const _KeyTile({
    super.key,
    required this.signingKey,
    required this.selected,
    required this.onSelect,
    required this.onRegister,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tile = YaruTile(
      leading: Radio<bool>(
        value: true,
        groupValue: selected ? true : null,
        onChanged: signingKey.registered ? (_) => onSelect() : null,
      ),
      title: Row(
        children: [
          Text(signingKey.name),
          const SizedBox(width: 8),
          _StatusChip(registered: signingKey.registered),
        ],
      ),
      subtitle: Text(
        signingKey.sha3384,
        style: theme.textTheme.bodySmall?.copyWith(
          fontFamily: 'monospace',
          color: theme.hintColor,
        ),
        overflow: TextOverflow.ellipsis,
      ),
      trailing: signingKey.registered
          ? null
          : OutlinedButton(
              onPressed: onRegister,
              child: const Text('Register'),
            ),
    );

    return InkWell(
      onTap: signingKey.registered ? onSelect : onRegister,
      child: tile,
    );
  }
}

class _StatusChip extends StatelessWidget {
  final bool registered;
  const _StatusChip({required this.registered});

  @override
  Widget build(BuildContext context) {
    final color = registered ? StatusColors.success : StatusColors.orange;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        registered ? 'Registered' : 'Local only',
        style: TextStyle(
            color: color, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onCreate;
  const _EmptyState({required this.onCreate});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(48),
        child: Column(
          children: [
            Icon(Icons.vpn_key_outlined,
                size: 48, color: Theme.of(context).hintColor),
            const SizedBox(height: 16),
            const Text('No signing keys found'),
            const SizedBox(height: 8),
            Text('Create a key to sign your model assertion.',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add),
              label: const Text('Create key'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorBanner({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: theme.colorScheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(message,
                style: TextStyle(color: theme.colorScheme.onErrorContainer)),
          ),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class _NewKeyResult {
  final String name;
  final bool register;
  _NewKeyResult(this.name, this.register);
}

class _CreateKeyDialog extends StatefulWidget {
  const _CreateKeyDialog();

  @override
  State<_CreateKeyDialog> createState() => _CreateKeyDialogState();
}

class _CreateKeyDialogState extends State<_CreateKeyDialog> {
  final _controller = TextEditingController();
  bool _register = true;
  String? _error;

  void _submit() {
    final name = _controller.text.trim();
    final error = KeyService.validateKeyName(name);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(context, _NewKeyResult(name, _register));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create signing key'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Key name',
                helperText: 'Lowercase letters, digits and dashes',
                errorText: _error,
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _register,
              onChanged: (v) => setState(() => _register = v ?? true),
              title: const Text('Register with the Snap Store'),
              subtitle: const Text(
                  'Required before the key can sign a store-valid model.'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }
}
