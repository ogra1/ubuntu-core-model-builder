import 'package:flutter/material.dart';
import '../services/status_bar_service.dart';
import 'package:yaru/yaru.dart';
import 'package:file_selector/file_selector.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/status_colors.dart';
import '../models/wizard_step.dart';
import '../services/ffi/snapstore_auth_client.dart';
import '../services/rust_store_service.dart';
import '../services/store_models.dart';

class AccountPage extends StatelessWidget {
  final WizardState state;
  final Future<void> Function() onRetry;

  const AccountPage({
    super.key,
    required this.state,
    required this.onRetry,
  });

  Future<void> _login(BuildContext context) async {
    // In-app interactive login (no terminal): the Rust state machine
    // pauses at each prompt and this call blocks until the flow reaches a
    // terminal state (succeeded / cancelled / failed). The dialogs are
    // presented by RustStoreService against [context].
    final store = RustStoreService();
    state.setBusy(true, message: 'Signing in…');
    try {
      await store.loginInteractive(context: context);
      final acct = await store.getCurrentAccount();
      state.setAccount(acct);
      if (acct == null && context.mounted) {
        context.postError('Sign-in was cancelled or failed. Press "Sign in" to retry.');
      }
    } finally {
      state.busy = false;
    }
  }

  Future<void> _logout(BuildContext context) async {
    state.setBusy(true, message: 'Signing out...');
    try {
      await RustStoreService().logout();
      state.setAccount(null);
      // Clear the cached brand-store list so a different account does not see
      // the previous account's stores.
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(prefCachedStores);
      } catch (_) {}
    } finally {
      state.busy = false;
    }
  }

  Future<void> _importCredentials(BuildContext context) async {
    final creds = await showDialog<String>(
      context: context,
      builder: (_) => _ImportCredentialsDialog(),
    );
    if (creds == null || creds.trim().isEmpty) return;

    state.setBusy(true, message: 'Importing credentials...');
    try {
      final acct = await RustStoreService().importCredentials(creds);
      state.setAccount(acct);
      if (acct == null && context.mounted) {
        context.postError('Credentials imported but no account detected.');
      } else if (acct != null && context.mounted) {
        context.postSuccess('Signed in as ${acct.email}.');
      }
    } on CredentialImportException catch (e) {
      if (context.mounted) {
        context.postError('Import failed: ${e.message}');
      }
    } finally {
      state.busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tools = state.toolStatus;
    final account = state.account;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Getting Started',
            style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 24),
        YaruSection(
          headline: const Text('Required Tools'),
          child: Column(
            children: [
              YaruListTile(
                leading: Icon(
                  (tools?.hasSnap ?? false)
                      ? Icons.check_circle
                      : Icons.cancel,
                  color: (tools?.hasSnap ?? false)
                      ? StatusColors.success
                      : Theme.of(context).colorScheme.error,
                ),
                title: const Text('snap'),
                subtitle: Text(tools?.snapPath ?? 'Not found'),
              ),
              YaruListTile(
                leading: Icon(
                  (tools?.hasPinentry ?? false)
                      ? Icons.check_circle
                      : Icons.warning_amber,
                  color: (tools?.hasPinentry ?? false)
                      ? StatusColors.success
                      : StatusColors.orange,
                ),
                title: const Text('pinentry (graphical passphrase prompt)'),
                subtitle: Text((tools?.hasPinentry ?? false)
                    ? 'Available'
                    : 'Recommended: install pinentry-gnome3'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        YaruSection(
          headline: const Text('Snap Store Account'),
          child: account == null
              ? YaruListTile(
                  title: const Text('Not signed in'),
                  subtitle: const Text(
                      'Sign in to auto-fill your brand and authority ID.'),
                  trailing: Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () => _importCredentials(context),
                        icon: const Icon(Icons.key_outlined),
                        label: const Text('Import credentials'),
                      ),
                      ElevatedButton.icon(
                        onPressed: SnapstoreAuthSession.isAvailable()
                            ? () => _login(context)
                            : null,
                        icon: const Icon(Icons.login),
                        label: const Text('Sign in'),
                      ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    YaruListTile(
                      leading: const Icon(Icons.account_circle),
                      title: Text(account.email),
                      subtitle: Text('Account ID: ${account.accountId}'),
                    ),
                    if (account.username != null)
                      YaruListTile(
                        leading: const Icon(Icons.badge_outlined),
                        title: const Text('Username'),
                        subtitle: Text(account.username!),
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => _logout(context),
                            child: const Text('Sign out'),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: onRetry,
                            child: const Text('Refresh'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _ImportCredentialsDialog extends StatefulWidget {
  @override
  State<_ImportCredentialsDialog> createState() =>
      _ImportCredentialsDialogState();
}

class _ImportCredentialsDialogState extends State<_ImportCredentialsDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadFromFile() async {
    const group = XTypeGroup(
      label: 'Credentials',
      extensions: ['txt', 'json', 'creds'],
    );
    final file = await openFile(acceptedTypeGroups: [group]);
    if (file == null) return;
    final contents = await file.readAsString();
    _controller.text = contents;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Import store credentials'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SelectableText(
              'Paste the output of "snapcraft export-login <file>" produced '
              'on an already-authenticated machine, or load it from a file.\n\n'
              'This is an advanced option intended for headless or CI-style '
              'setups.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              maxLines: 10,
              minLines: 6,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Paste exported credentials here...',
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _loadFromFile,
                icon: const Icon(Icons.folder_open),
                label: const Text('Load from file...'),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('Import'),
        ),
      ],
    );
  }
}
