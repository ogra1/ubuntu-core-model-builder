import 'package:flutter/material.dart';
import 'package:yaru/yaru.dart';
import '../models/model_assertion.dart';
import '../models/snap_entry.dart';
import '../services/assertion_builder.dart';
import '../services/store_api_service.dart';
import '../widgets/snap_search_field.dart';

class SnapsPage extends StatefulWidget {
  final ModelAssertion model;
  final VoidCallback onChanged;
  const SnapsPage({
    super.key,
    required this.model,
    required this.onChanged,
  });

  @override
  State<SnapsPage> createState() => _SnapsPageState();
}

class _SnapsPageState extends State<SnapsPage> {
  final _store = StoreApiService();
  bool _seedingBase = false;
  bool _busy = false;
  String? _seedError;

  // Cached gadget-base resolution for the persistent inline indicator.
  String? _gadgetBase; // resolved base of the current gadget (per channel)
  String? _gadgetBaseFor; // "name|channel" the cached base was resolved for
  bool _resolvingGadgetBase = false;

  String get _arch => widget.model.architecture.name;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _seedRequiredSnaps();
      _resolveGadgetBase();
    });
  }

  SnapEntry? get _currentGadget {
    for (final s in widget.model.snaps) {
      if (s.type == SnapType.gadget) return s;
    }
    return null;
  }

  /// Async-resolves the current gadget's per-channel base and caches it for
  /// the inline indicator. Safe to call repeatedly; it no-ops if already
  /// resolved for the same gadget+channel.
  Future<void> _resolveGadgetBase() async {
    final gadget = _currentGadget;
    if (gadget == null) {
      if (_gadgetBase != null || _gadgetBaseFor != null) {
        setState(() {
          _gadgetBase = null;
          _gadgetBaseFor = null;
        });
      }
      return;
    }

    final key = '${gadget.name}|${gadget.defaultChannel}';
    if (key == _gadgetBaseFor) return; // already resolved for this combo
    if (_resolvingGadgetBase) return;

    _resolvingGadgetBase = true;
    try {
      final base = await _store.getBaseForChannel(
          gadget.name, _arch, gadget.defaultChannel);
      if (!mounted) return;
      setState(() {
        _gadgetBase = base;
        _gadgetBaseFor = key;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _gadgetBase = null; // couldn't resolve; no false indicator
          _gadgetBaseFor = key;
        });
      }
    } finally {
      _resolvingGadgetBase = false;
    }
  }

  Future<void> _seedRequiredSnaps() async {
    setState(() {
      _seedingBase = true;
      _seedError = null;
    });
    final errors = <String>[];
    try {
      final baseName = widget.model.base;
      final hasBase =
          widget.model.snaps.any((s) => s.type == SnapType.base);
      if (baseName != null && !hasBase) {
        try {
          await _seedOne(
            name: baseName,
            type: SnapType.base,
            preferTrack: RegExp(r'(\d+)').firstMatch(baseName)?.group(1),
          );
        } catch (e) {
          errors.add('base snap "$baseName": $e');
        }
      }

      final hasSnapd =
          widget.model.snaps.any((s) => s.type == SnapType.snapd);
      if (!hasSnapd) {
        try {
          await _seedOne(name: 'snapd', type: SnapType.snapd);
        } catch (e) {
          errors.add('snapd snap: $e');
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _seedingBase = false;
          _seedError = errors.isEmpty
              ? null
              : 'Could not auto-add: ${errors.join('; ')}';
        });
      }
    }
  }

  Future<SnapEntry> _seedOne({
    required String name,
    required SnapType type,
    String? preferTrack,
    bool autoAdded = false,
  }) async {
    final info = await _store.getSnapInfo(name, _arch);
    String channel = 'latest/stable';
    if (preferTrack != null) {
      channel = info.channels.firstWhere(
        (c) => c.startsWith('$preferTrack/stable'),
        orElse: () => info.channels.firstWhere(
          (c) => c.startsWith('$preferTrack/'),
          orElse: () => info.channels.isNotEmpty
              ? info.channels.first
              : 'latest/stable',
        ),
      );
    } else if (info.channels.isNotEmpty) {
      channel = info.channels.firstWhere(
        (c) => c.endsWith('/stable'),
        orElse: () => info.channels.first,
      );
    }
    final entry = SnapEntry(
      name: info.name,
      id: info.snapId,
      type: type,
      defaultChannel: channel,
      autoAdded: autoAdded,
    );
    _insertSnap(entry);
    return entry;
  }

  void _insertSnap(SnapEntry entry) {
    widget.model.snaps.removeWhere((s) => s.name == entry.name);
    widget.model.snaps.add(entry);
    widget.onChanged();
    if (mounted) setState(() {});
  }

  Future<void> _onSnapAdded(SnapEntry entry, String? appBase) async {
    // For app snaps, the base can differ per channel (e.g. console-conf:
    // 24/* => core24, 26/* => core26). The channel-agnostic base passed in
    // may be wrong, so resolve the base for the app's SELECTED channel.
    String? resolvedAppBase = appBase;
    if (entry.type == SnapType.app) {
      setState(() => _busy = true);
      try {
        final perChannel = await _store.getBaseForChannel(
            entry.name, _arch, entry.defaultChannel);
        if (perChannel != null) resolvedAppBase = perChannel;
      } catch (_) {
        // Fall back to the passed base if per-channel resolution fails.
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    }

    final toAdd = entry.type == SnapType.app
        ? entry.copyWith(
            presence: SnapPresence.optional,
            appBase: resolvedAppBase,
          )
        : entry;
    _insertSnap(toAdd);

    if (entry.type == SnapType.app && resolvedAppBase != null) {
      final alreadyPresent = widget.model.snaps
          .any((s) => s.type == SnapType.base && s.name == resolvedAppBase);
      final isModelBase = resolvedAppBase == widget.model.base;
      if (!alreadyPresent && !isModelBase) {
        setState(() => _busy = true);
        try {
          final track =
              RegExp(r'(\d+)').firstMatch(resolvedAppBase)?.group(1);
          await _seedOne(
            name: resolvedAppBase,
            type: SnapType.base,
            preferTrack: track,
            autoAdded: true,
          );
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 6),
                content: Text(
                  'Added base snap "$resolvedAppBase" automatically because '
                  '"${entry.name}" is built on it. It is placed before the '
                  'app so snapd processes it first during image build.',
                ),
              ),
            );
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                behavior: SnackBarBehavior.floating,
                backgroundColor:
                    Theme.of(context).colorScheme.errorContainer,
                content: Text(
                  'Could not auto-add base "$resolvedAppBase" needed by '
                  '"${entry.name}": $e',
                ),
              ),
            );
          }
        } finally {
          if (mounted) setState(() => _busy = false);
        }
      }
    }

    // Re-resolve the gadget base for the inline indicator (covers adding a
    // gadget, or replacing one).
    if (entry.type == SnapType.gadget) {
      _resolveGadgetBase();
    }

    _recomputeBasePresence();
  }

  void _removeSnap(SnapEntry entry) {
    final isDependentBase =
        entry.type == SnapType.base && entry.name != widget.model.base;
    if (isDependentBase && _baseHasDependents(entry.name)) {
      _showBaseLockedMessage(entry.name);
      return;
    }

    final removedAppBase =
        entry.type == SnapType.app ? entry.appBase : null;

    widget.model.snaps.remove(entry);

    if (removedAppBase != null && removedAppBase != widget.model.base) {
      final base = _findBase(removedAppBase);
      if (base != null &&
          base.autoAdded &&
          !_baseHasDependents(removedAppBase)) {
        widget.model.snaps.remove(base);
        _showBaseAutoRemovedMessage(removedAppBase, entry.name);
      }
    }

    widget.onChanged();
    _recomputeBasePresence();
    setState(() {});

    // If the gadget was removed, refresh the indicator.
    if (entry.type == SnapType.gadget) {
      _resolveGadgetBase();
    }
  }

  SnapEntry? _findBase(String name) {
    for (final s in widget.model.snaps) {
      if (s.type == SnapType.base && s.name == name) return s;
    }
    return null;
  }

  void _showBaseLockedMessage(String baseName) {
    final dependents = widget.model.snaps
        .where((s) => s.type == SnapType.app && s.appBase == baseName)
        .map((s) => s.name)
        .toList();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(
          'Cannot remove base "$baseName": it is required by '
          '${dependents.join(", ")}. Remove those app(s) first.',
        ),
      ),
    );
  }

  void _showBaseAutoRemovedMessage(String baseName, String appName) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(
          'Also removed auto-added base "$baseName" — no remaining snap '
          'depends on it after removing "$appName".',
        ),
      ),
    );
  }

  void _togglePresence(SnapEntry entry) {
    final idx = widget.model.snaps.indexOf(entry);
    if (idx < 0) return;
    final next = entry.presence == SnapPresence.required_
        ? SnapPresence.optional
        : SnapPresence.required_;
    widget.model.snaps[idx] = entry.copyWith(presence: next);
    widget.onChanged();
    _recomputeBasePresence();
    setState(() {});
  }

  void _recomputeBasePresence() {
    final modelBase = widget.model.base;

    bool requiredAppUses(String baseName) => widget.model.snaps.any(
          (s) =>
              s.type == SnapType.app &&
              s.presence == SnapPresence.required_ &&
              s.appBase == baseName,
        );

    var changed = false;
    for (var i = 0; i < widget.model.snaps.length; i++) {
      final s = widget.model.snaps[i];
      if (s.type != SnapType.base) continue;
      if (s.name == modelBase) {
        if (s.presence != null) {
          widget.model.snaps[i] = SnapEntry(
            name: s.name,
            id: s.id,
            type: s.type,
            defaultChannel: s.defaultChannel,
            autoAdded: s.autoAdded,
          );
          changed = true;
        }
        continue;
      }

      final desired = requiredAppUses(s.name)
          ? SnapPresence.required_
          : SnapPresence.optional;
      if (s.presence != desired) {
        widget.model.snaps[i] = s.copyWith(presence: desired);
        changed = true;
      }
    }
    if (changed) widget.onChanged();
  }

  bool _baseHasDependents(String baseName) => widget.model.snaps.any(
        (s) => s.type == SnapType.app && s.appBase == baseName,
      );

  bool _hasType(SnapType t) => widget.model.snaps.any((s) => s.type == t);

  bool get _baseMatches {
    final baseName = widget.model.base;
    return baseName != null &&
        widget.model.snaps
            .any((s) => s.type == SnapType.base && s.name == baseName);
  }

  @override
  Widget build(BuildContext context) {
    // Trigger a re-resolve if the cached gadget base is stale relative to the
    // current gadget (e.g. after navigating back with a changed model base).
    final gadget = _currentGadget;
    final currentKey =
        gadget == null ? null : '${gadget.name}|${gadget.defaultChannel}';
    if (currentKey != _gadgetBaseFor && !_resolvingGadgetBase) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _resolveGadgetBase());
    }

    final snaps = AssertionBuilder.orderedSnaps(widget.model.snaps);
    return Stack(
      children: [
        ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text('Snaps', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              'Searching the store for architecture "$_arch". A model '
              'requires a kernel, gadget, snapd, and a base snap. When you '
              'add an app snap built on a different base, that base is added '
              'automatically and removed again when no snap needs it. App '
              'snaps are optional by default; click the lock to mark one '
              'required. A dependent base becomes required only when a '
              'required app uses it.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).hintColor,
                  ),
            ),
            const SizedBox(height: 16),
            _buildRequirementChips(context),
            const SizedBox(height: 12),
            _buildGadgetBaseWarning(context),
            const SizedBox(height: 4),
            if (_seedingBase)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 12),
                    Text('Adding required snaps...'),
                  ],
                ),
              ),
            if (_seedError != null)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline,
                        color:
                            Theme.of(context).colorScheme.onErrorContainer),
                    const SizedBox(width: 12),
                    Expanded(child: Text(_seedError!)),
                    TextButton(
                      onPressed: _seedRequiredSnaps,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            SnapSearchField(
              onSnapSelected: _onSnapAdded,
              modelBase: widget.model.base,
              architecture: _arch,
            ),
            const SizedBox(height: 24),
            if (snaps.isEmpty)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text('No snaps added yet.',
                      style: Theme.of(context).textTheme.bodyMedium),
                ),
              )
            else
              YaruSection(
                headline: Text('Snaps (${snaps.length})'),
                child: Column(
                  children:
                      snaps.map((s) => _buildSnapTile(context, s)).toList(),
                ),
              ),
          ],
        ),
        if (_busy)
          const Positioned.fill(
            child: ColoredBox(
              color: Color(0x22000000),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
      ],
    );
  }

  Future<void> _changeGadgetChannel(
      SnapEntry gadget, String modelBase) async {
    setState(() => _busy = true);
    List<({String channel, String? base})> channels;
    try {
      channels = await _store.getChannelsWithBases(gadget.name, _arch);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text('Could not load channels for "${gadget.name}": $e'),
          ),
        );
      }
      return;
    }
    if (mounted) setState(() => _busy = false);
    if (!mounted) return;

    final chosen = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Choose a channel for "${gadget.name}"'),
        content: SizedBox(
          width: 460,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final c in channels)
                ListTile(
                  dense: true,
                  leading: Icon(
                    c.base == modelBase
                        ? Icons.check_circle
                        : (c.base == null
                            ? Icons.help_outline
                            : Icons.cancel),
                    color: c.base == modelBase
                        ? Theme.of(dialogContext).colorScheme.primary
                        : Theme.of(dialogContext).hintColor,
                  ),
                  title: Text(c.channel),
                  subtitle: Text(c.base == null
                      ? 'base: unknown'
                      : 'base: ${c.base}'
                          '${c.base == modelBase ? "  (matches)" : ""}'),
                  onTap: () => Navigator.pop(dialogContext, c.channel),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    if (chosen == null || chosen == gadget.defaultChannel) return;

    // Update the gadget's channel in place.
    final idx = widget.model.snaps.indexOf(gadget);
    if (idx >= 0) {
      widget.model.snaps[idx] = SnapEntry(
        name: gadget.name,
        id: gadget.id,
        type: gadget.type,
        defaultChannel: chosen,
        presence: gadget.presence,
        appBase: gadget.appBase,
        autoAdded: gadget.autoAdded,
      );
      widget.onChanged();
    }
    // Re-resolve the banner against the new channel.
    _gadgetBaseFor = null; // force re-resolution
    await _resolveGadgetBase();
    if (mounted) setState(() {});
  }

  /// Persistent inline indicator: shown when the current gadget's resolved
  /// per-channel base does not match the model base.
  Widget _buildGadgetBaseWarning(BuildContext context) {
    final modelBase = widget.model.base;
    final gadget = _currentGadget;
    if (modelBase == null || gadget == null || _gadgetBase == null) {
      return const SizedBox.shrink();
    }
    if (_gadgetBase == modelBase) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    return InkWell(
      onTap: () => _changeGadgetChannel(gadget, modelBase),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(Icons.warning_amber,
                color: theme.colorScheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Gadget base mismatch: "${gadget.name}" '
                '(${gadget.defaultChannel}) is built on "$_gadgetBase", but '
                'the model base is "$modelBase". Tap to choose a channel '
                'built on "$modelBase".',
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ),
            Icon(Icons.chevron_right,
                color: theme.colorScheme.onErrorContainer),
          ],
        ),
      ),
    );
  }

  Widget _buildSnapTile(BuildContext context, SnapEntry s) {
    final isApp = s.type == SnapType.app;
    final isDependentBase =
        s.type == SnapType.base && s.name != widget.model.base;
    final isRequired = s.presence == SnapPresence.required_;
    final baseLocked = isDependentBase && _baseHasDependents(s.name);

    final trailing = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isApp)
          IconButton(
            icon: Icon(isRequired ? Icons.lock : Icons.lock_open),
            tooltip: isRequired
                ? 'Required (click to make optional)'
                : 'Optional (click to make required)',
            color: isRequired
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).hintColor,
            onPressed: () => _togglePresence(s),
          ),
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: baseLocked
              ? 'Required by dependent app(s); remove those first'
              : 'Remove',
          onPressed: baseLocked ? null : () => _removeSnap(s),
        ),
      ],
    );

    String presenceLabel = '';
    if (isApp || isDependentBase) {
      presenceLabel = isRequired ? '  •  required' : '  •  optional';
      if (isDependentBase) presenceLabel += ' (auto)';
    }

    return YaruTile(
      leading: _typeChip(context, s.type),
      title: Row(
        children: [
          Text(s.name),
          if (presenceLabel.isNotEmpty)
            Text(
              presenceLabel,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: isRequired
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).hintColor,
                  ),
            ),
        ],
      ),
      subtitle: Text(
        'id: ${s.id}\nchannel: ${s.defaultChannel}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      trailing: trailing,
    );
  }

  Widget _buildRequirementChips(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _reqChip(context, 'kernel', _hasType(SnapType.kernel)),
        _reqChip(context, 'gadget', _hasType(SnapType.gadget)),
        _reqChip(context, 'snapd', _hasType(SnapType.snapd)),
        _reqChip(context, widget.model.base ?? 'base', _baseMatches),
      ],
    );
  }

  Widget _reqChip(BuildContext context, String label, bool satisfied) {
    final color = satisfied
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.error;
    return Chip(
      avatar: Icon(
        satisfied ? Icons.check_circle : Icons.radio_button_unchecked,
        size: 18,
        color: color,
      ),
      label: Text(label),
      side: BorderSide(color: color.withOpacity(0.4)),
    );
  }

  Widget _typeChip(BuildContext context, SnapType type) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        type.name,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
