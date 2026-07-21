import 'package:flutter/material.dart';
import 'package:yaru/yaru.dart';
import '../models/model_assertion.dart';
import '../models/snap_entry.dart';
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
  String? _seedError;

  String get _arch => widget.model.architecture.name;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _seedRequiredSnaps());
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

  Future<void> _seedOne({
    required String name,
    required SnapType type,
    String? preferTrack,
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
    _addSnap(SnapEntry(
      name: info.name,
      id: info.snapId,
      type: type,
      defaultChannel: channel,
    ));
  }

  void _addSnap(SnapEntry entry) {
    widget.model.snaps.removeWhere((s) => s.name == entry.name);
    widget.model.snaps.add(entry);
    widget.onChanged();
    if (mounted) setState(() {});
  }

  void _removeSnap(SnapEntry entry) {
    widget.model.snaps.remove(entry);
    widget.onChanged();
    setState(() {});
  }

  bool _hasType(SnapType t) => widget.model.snaps.any((s) => s.type == t);

  bool get _baseMatches {
    final baseName = widget.model.base;
    return baseName != null &&
        widget.model.snaps
            .any((s) => s.type == SnapType.base && s.name == baseName);
  }

  @override
  Widget build(BuildContext context) {
    final snaps = widget.model.snaps;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Snaps', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(
          'Searching the store for architecture "$_arch". A model requires '
          'a kernel, gadget, snapd, and a base snap. The base and snapd '
          'snaps are added automatically; you can remove them to pick a '
          'different channel.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).hintColor,
              ),
        ),
        const SizedBox(height: 16),
        _buildRequirementChips(context),
        const SizedBox(height: 16),
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
                    color: Theme.of(context).colorScheme.onErrorContainer),
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
          onSnapSelected: _addSnap,
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
              children: snaps
                  .map((s) => YaruTile(
                        leading: _typeChip(context, s.type),
                        title: Text(s.name),
                        subtitle: Text(
                          'id: ${s.id}\nchannel: ${s.defaultChannel}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _removeSnap(s),
                        ),
                      ))
                  .toList(),
            ),
          ),
      ],
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
