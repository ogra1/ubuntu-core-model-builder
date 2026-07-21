import 'dart:io';

import 'package:flutter/material.dart';
import 'package:yaru/yaru.dart';
import 'package:file_selector/file_selector.dart';

import '../theme/status_colors.dart';
import '../models/wizard_step.dart';
import '../services/cancel_token.dart';
import '../services/store_service.dart';
import '../services/tool_locator.dart';

class AccountPage extends StatelessWidget {
  final WizardState state;
  final Future<void> Function() onRetry;

  const AccountPage({
    super.key,
    required this.state,
    required this.onRetry,
  });

  Future<void> _login(BuildContext context) async {
    final cancelToken = CancelToken();
    Process? terminal;

    void cancel() {
      cancelToken.cancel();
      final t = terminal;
      if (t != null) {
        // Fire-and-forget kill of the terminal + snapcraft child.
        StoreService().killTerminal(t);
      }
    }

    state.setBusy(true, message: 'Opening login terminal...');
    try {
      try {
        terminal = await StoreService().loginInTerminal();
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Complete login in the opened terminal (including any 2FA). '
                'It will be detected automatically.',
              ),
              duration: Duration(seconds: 8),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      } on NoTerminalException {
        if (context.mounted) {
          await _showManualLoginDialog(context);
        }
      }

      state.setBusy(
        true,
        message: 'Waiting for login to complete...',
        onCancel: cancel,
      );
      final acct = await StoreService().waitForLogin(cancelToken: cancelToken);
      state.setAccount(acct);

      // If login succeeded (or timed out without cancel), close the terminal
      // window we opened so it does not linger.
      final t = terminal;
      if (t != null && !cancelToken.isCancelled) {
        await StoreService().killTerminal(t);
      }

      if (acct == null && !cancelToken.isCancelled && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Login not detected. Press "Refresh" to retry.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      state.busy = false;
    }
  }

  Future<void> _logout(BuildContext context) async {
    state.setBusy(true, message: 'Signing out...');
    try {
      await StoreService().logout();
      state.setAccount(null);
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
      final acct = await StoreService().importCredentials(creds);
      state.setAccount(acct);
      if (acct == null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Credentials imported but no account detected.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else if (acct != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Signed in as ${acct.email}.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } on CredentialImportException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Import failed: ${e.message}'),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Theme.of(context).colorScheme.errorContainer,
          ),
        );
      }
    } finally {
      state.busy = false;
    }
  }

  Future<void> _installTools() async {
    state.setBusy(true, message: 'Installing snapcraft...');
    try {
      await ToolLocator.installSnapcraft();
      state.toolStatus = await ToolLocator.check();
      state.refresh();
    } finally {
      state.busy = false;
    }
  }

  Future<void> _showManualLoginDialog(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Sign in required'),
        content: const SelectableText(
          'No terminal emulator was found to run the interactive login.\n\n'
          'Please open a terminal yourself and run:\n\n'
          '    snapcraft login\n\n'
          'Complete the login (including any 2FA), then return here. '
          'It will be detected automatically, or press "Refresh".',
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
              YaruTile(
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
              YaruTile(
                leading: Icon(
                  (tools?.hasSnapcraft ?? false)
                      ? Icons.check_circle
                      : Icons.cancel,
                  color: (tools?.hasSnapcraft ?? false)
                      ? StatusColors.success
                      : Theme.of(context).colorScheme.error,
                ),
                title: const Text('snapcraft'),
                subtitle: Text(tools?.snapcraftPath ?? 'Not found'),
                trailing: (tools?.hasSnapcraft ?? true)
                    ? null
                    : OutlinedButton(
                        onPressed: _installTools,
                        child: const Text('Install'),
                      ),
              ),
              YaruTile(
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
              ? YaruTile(
                  title: const Text('Not signed in'),
                  subtitle: const Text(
                      'Sign in to auto-fill your brand and authority ID.'),
                  trailing: Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      OutlinedButton.icon(
                        onPressed: (tools?.hasSnapcraft ?? false)
                            ? () => _importCredentials(context)
                            : null,
                        icon: const Icon(Icons.key_outlined),
                        label: const Text('Import credentials'),
                      ),
                      ElevatedButton.icon(
                        onPressed: (tools?.ready ?? false)
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
                    YaruTile(
                      leading: const Icon(Icons.account_circle),
                      title: Text(account.email),
                      subtitle: Text('Account ID: ${account.accountId}'),
                    ),
                    if (account.username != null)
                      YaruTile(
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
