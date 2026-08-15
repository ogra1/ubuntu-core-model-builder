import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yaru/yaru.dart';

import '../models/model_assertion.dart';
import '../models/snap_entry.dart';
import '../models/wizard_step.dart';
import '../services/model_import_service.dart';
import '../services/host_env.dart';
import '../services/store_api_service.dart';
import '../services/surl_service.dart';

class MetadataPage extends StatefulWidget {
  final WizardState state;
  final VoidCallback onChanged;
  const MetadataPage({
    super.key,
    required this.state,
    required this.onChanged,
  });

  @override
  State<MetadataPage> createState() => _MetadataPageState();
}

class _MetadataPageState extends State<MetadataPage> {
  static const _prefLastImportDir = 'metadata.lastImportDir';
  static const _prefRecentStores = 'metadata.recentStores';

  final _nameController = TextEditingController();
  final _storeController = TextEditingController();
  final _storeFocus = FocusNode();
  final _store = StoreApiService();

  List<String> _recentStores = [];

  WizardState get state => widget.state;
  ModelAssertion get model => state.model;

  @override
  void initState() {
    super.initState();
    _nameController.text = model.model ?? '';
    _storeController.text = model.store ?? '';
    _loadRecentStores();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _storeController.dispose();
    _storeFocus.dispose();
    super.dispose();
  }

  void _syncControllersFromModel() {
    final wantName = model.model ?? '';
    if (_nameController.text != wantName) {
      _nameController.text = wantName;
      _nameController.selection =
          TextSelection.collapsed(offset: _nameController.text.length);
    }
    final wantStore = model.store ?? '';
    if (_storeController.text != wantStore) {
      _storeController.text = wantStore;
      _storeController.selection =
          TextSelection.collapsed(offset: _storeController.text.length);
    }
  }

  Future<void> _loadRecentStores() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_prefRecentStores);
      if (list != null && mounted) {
        setState(() => _recentStores = list);
      }
    } catch (_) {}
  }

  Future<void> _rememberStore(String store) async {
    final v = store.trim();
    if (v.isEmpty) return;
    final updated = <String>[
      v,
      ..._recentStores.where((s) => s != v),
    ].take(10).toList();
    setState(() => _recentStores = updated);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefRecentStores, updated);
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Base change: seed the new base snap and warn on gadget mismatch
  // ---------------------------------------------------------------------------

  Future<void> _onBaseChanged(String? newBase) async {
    if (newBase == null) return;
    model.base = newBase;
    state.invalidateSignature();
    widget.onChanged();
    setState(() {});

    final arch = model.architecture.name;
    state.setBusy(true, message: 'Updating base snap...');
    try {
      // 1. Always seed the new base snap if not already present (idempotent).
      await _ensureBaseSnap(newBase, arch);

      // 2. Check the gadget: its base must match the new model base.
      await _checkGadgetBase(newBase, arch);
    } catch (e) {
      _error(context, 'Could not update base: $e');
    } finally {
      state.busy = false;
    }
  }

  /// Adds the base snap for [baseName] if the model does not already contain
  /// a base snap with that name. Idempotent; safe to call repeatedly.
  Future<void> _ensureBaseSnap(String baseName, String arch) async {
    final alreadyPresent = model.snaps
        .any((s) => s.type == SnapType.base && s.name == baseName);
    if (alreadyPresent) return;

    final info = await _store.getSnapInfo(baseName, arch);
    final track = RegExp(r'(\d+)').firstMatch(baseName)?.group(1);
    String channel = 'latest/stable';
    if (track != null) {
      channel = info.channels.firstWhere(
        (c) => c.startsWith('$track/stable'),
        orElse: () => info.channels.firstWhere(
          (c) => c.startsWith('$track/'),
          orElse: () =>
              info.channels.isNotEmpty ? info.channels.first : 'latest/stable',
        ),
      );
    } else if (info.channels.isNotEmpty) {
      channel = info.channels.firstWhere(
        (c) => c.endsWith('/stable'),
        orElse: () => info.channels.first,
      );
    }

    model.snaps.removeWhere((s) => s.name == info.name);
    model.snaps.add(SnapEntry(
      name: info.name,
      id: info.snapId,
      type: SnapType.base,
      defaultChannel: channel,
    ));
    widget.onChanged();
    if (mounted) setState(() {});
  }

  /// Warns (authoritatively, via store lookup) if the current gadget's base
  /// does not match [newBase]. The gadget must be built on the model base.
  Future<void> _checkGadgetBase(String newBase, String arch) async {
    SnapEntry? gadget;
    for (final s in model.snaps) {
      if (s.type == SnapType.gadget) {
        gadget = s;
        break;
      }
    }
    if (gadget == null) return; // no gadget yet; nothing to check

    String? gadgetBase;
    try {
      final info = await _store.getSnapInfo(gadget.name, arch);
      gadgetBase = info.base;
    } catch (_) {
      return; // can't resolve; skip the warning rather than false-alarm
    }

    if (gadgetBase != null && gadgetBase != newBase) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Gadget base mismatch'),
          content: Text(
            'The gadget snap "${gadget!.name}" is built on "$gadgetBase", '
            'which does not match the new model base "$newBase".\n\n'
            'For the image build to succeed, the gadget must be built on '
            '"$newBase". Go to the Snaps page and replace the gadget with '
            'one built on "$newBase".',
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
  }

  // ---------------------------------------------------------------------------
  // Import
  // ---------------------------------------------------------------------------

  Future<void> _openExamplesRepo() async {
    const url = 'https://github.com/canonical/models';
    try {
      await Process.run('xdg-open', [url],
          environment: HostEnv.sanitized, includeParentEnvironment: false);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text('Browse example models at: '
                'https://github.com/canonical/models'),
            duration: Duration(seconds: 8),
          ),
        );
      }
    }
  }

  Future<void> _import(BuildContext context) async {
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

    await _rememberImportDir(file.path);

    state.setBusy(true, message: 'Importing model...');
    try {
      final result = await ModelImportService()
          .importFromFile(file.path, reResolveAppBase: true);

      state.importModel(result.model);
      _syncControllersFromModel();
      if (model.store != null && model.store!.trim().isNotEmpty) {
        await _rememberStore(model.store!);
      }
      widget.onChanged();

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
      state.setAccount(state.account);
      widget.onChanged();
      setState(() {});
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
    } catch (_) {}
  }

  String? _dirOf(String path) {
    final idx = path.lastIndexOf(RegExp(r'[/\\]'));
    if (idx <= 0) return null;
    return path.substring(0, idx);
  }

  // ---------------------------------------------------------------------------
  // Store fetch / picker
  // ---------------------------------------------------------------------------

  Future<List<BrandStore>> _loadCachedStores() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(SurlService.prefCachedStores);
      if (raw == null || raw.isEmpty) return const [];
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => BrandStore.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _saveCachedStores(List<BrandStore> stores) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = jsonEncode(stores.map((s) => s.toJson()).toList());
      await prefs.setString(SurlService.prefCachedStores, raw);
    } catch (_) {}
  }

  Future<void> _fetchStores(BuildContext context) async {
    final cached = await _loadCachedStores();
    if (cached.isNotEmpty) {
      if (!context.mounted) return;
      await _showStorePicker(context, cached);
      return;
    }
    await _queryAndShowStores(context);
  }

  Future<void> _queryAndShowStores(BuildContext context) async {
    final surl = SurlService();
    state.setBusy(true, message: 'Fetching your stores...');
    try {
      List<BrandStore> stores;
      try {
        stores = await surl.listStores();
      } on SurlAuthException {
        state.setBusy(true, message: 'Opening login in your browser...');
        await surl.webLogin();
        state.setBusy(true, message: 'Fetching your stores...');
        stores = await surl.listStores();
      }
      await _saveCachedStores(stores);
      if (!context.mounted) return;
      await _showStorePicker(context, stores);
    } on SurlUnavailableException catch (e) {
      _error(context,
          'Store lookup is unavailable: $e. You can type a store ID manually.');
    } on SurlAuthException catch (e) {
      _error(context, 'Store login failed: $e');
    } catch (e) {
      _error(context, 'Could not fetch stores: $e');
    } finally {
      state.busy = false;
    }
  }

  Future<void> _showStorePicker(
      BuildContext context, List<BrandStore> stores) async {
    final sorted = [...stores]..sort((a, b) {
        if (a.isGlobal != b.isGlobal) return a.isGlobal ? -1 : 1;
        final an = (a.name ?? a.id).toLowerCase();
        final bn = (b.name ?? b.id).toLowerCase();
        return an.compareTo(bn);
      });

    const refreshSentinel = BrandStore(id: '__refresh__');

    final selected = await showDialog<BrandStore>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Select a store'),
        content: SizedBox(
          width: 480,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final st in sorted)
                ListTile(
                  title: Text(st.isGlobal
                      ? 'Global store (no store ID)'
                      : (st.name ?? st.id)),
                  subtitle: st.isGlobal
                      ? const Text('Standard Ubuntu store')
                      : Text('${st.id}'
                          '${st.roles.isNotEmpty ? "  •  ${st.roles.join(", ")}" : ""}'),
                  onTap: () => Navigator.pop(dialogContext, st),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, refreshSentinel),
            child: const Text('Refresh'),
          ),
        ],
      ),
    );

    if (selected == null) return;

    if (identical(selected, refreshSentinel) ||
        selected.id == '__refresh__') {
      if (context.mounted) await _queryAndShowStores(context);
      return;
    }

    if (selected.isGlobal) {
      model.store = null;
      _storeController.text = '';
    } else {
      model.store = selected.id;
      _storeController.text = selected.id;
      await _rememberStore(selected.id);
    }
    widget.onChanged();
    setState(() {});
  }

  // ---------------------------------------------------------------------------
  // Misc
  // ---------------------------------------------------------------------------

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

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

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
            TextButton.icon(
              onPressed: _openExamplesRepo,
              icon: const Icon(Icons.travel_explore),
              label: const Text('Browse examples'),
            ),
            const SizedBox(width: 8),
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
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: 'Model name',
                    helperText: 'Lowercase, alphanumeric and dashes',
                  ),
                  onChanged: (v) {
                    model.model = v;
                    widget.onChanged();
                  },
                ),
                const SizedBox(height: 16),
                TextField(
                  key: ValueKey('brand-${model.brandId}'),
                  controller: TextEditingController(
                    text: model.brandId ?? 'Not signed in',
                  ),
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
                    widget.onChanged();
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
                  onChanged: (v) => _onBaseChanged(v),
                ),
                const SizedBox(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _buildStoreField(context)),
                    const SizedBox(width: 12),
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: OutlinedButton.icon(
                        onPressed: () => _fetchStores(context),
                        icon: const Icon(Icons.cloud_download_outlined),
                        label: const Text('Fetch my stores'),
                      ),
                    ),
                  ],
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
                widget.onChanged();
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStoreField(BuildContext context) {
    return RawAutocomplete<String>(
      textEditingController: _storeController,
      focusNode: _storeFocus,
      optionsBuilder: (value) {
        final q = value.text.trim();
        if (_recentStores.isEmpty) return const Iterable<String>.empty();
        if (q.isEmpty) return _recentStores;
        return _recentStores
            .where((s) => s.toLowerCase().contains(q.toLowerCase()));
      },
      onSelected: (sel) {
        _storeController.text = sel;
        model.store = sel.trim().isEmpty ? null : sel.trim();
        widget.onChanged();
      },
      fieldViewBuilder: (context, controller, focusNode, onSubmit) {
        return TextField(
          controller: controller,
          focusNode: focusNode,
          decoration: const InputDecoration(
            labelText: 'Store ID (optional)',
            helperText: 'Brand store ID; leave blank for the global store',
          ),
          onChanged: (v) {
            model.store = v.trim().isEmpty ? null : v.trim();
            widget.onChanged();
          },
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            child: SizedBox(
              width: 400,
              child: ListView(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                children: options
                    .map((o) => ListTile(
                          dense: true,
                          title: Text(o),
                          onTap: () => onSelected(o),
                        ))
                    .toList(),
              ),
            ),
          ),
        );
      },
    );
  }
}
