import 'dart:async';
import 'package:flutter/material.dart';
import '../models/store_snap.dart';
import '../models/snap_entry.dart';
import '../services/store_api_service.dart';
import '../services/surl_service.dart';

class SnapSearchField extends StatefulWidget {
  final void Function(SnapEntry entry, String? base) onSnapSelected;
  final String? modelBase;
  final String architecture;
  final String? storeId;

  /// For a brand store: the pre-fetched catalog to filter client-side. When
  /// null, remote find (global store) is used instead.
  final List<StoreCatalogSnap>? catalog;

  const SnapSearchField({
    super.key,
    required this.onSnapSelected,
    required this.architecture,
    this.modelBase,
    this.storeId,
    this.catalog,
  });

  @override
  State<SnapSearchField> createState() => _SnapSearchFieldState();
}

class _SnapSearchFieldState extends State<SnapSearchField> {
  final _store = StoreApiService();
  final _searchController = TextEditingController();
  final _manualNameController = TextEditingController();

  Timer? _debounce;
  List<StoreSnap> _results = [];
  bool _searching = false;

  StoreSnap? _selected;
  List<String> _availableChannels = [];
  String? _channel;
  SnapType _type = SnapType.app;
  bool _loadingChannels = false;
  bool _adding = false;

  // Manual "add by exact name" (for snaps unlisted from search).
  bool _showManualAdd = false;
  bool _resolvingManual = false;

  bool get _brandMode => widget.catalog != null;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _manualNameController.dispose();
    super.dispose();
  }

  static SnapType _mapStoreType(String? storeType) {
    switch (storeType) {
      case 'kernel':
        return SnapType.kernel;
      case 'gadget':
        return SnapType.gadget;
      case 'base':
        return SnapType.base;
      case 'snapd':
        return SnapType.snapd;
      case 'os':
        return SnapType.base;
      default:
        return SnapType.app;
    }
  }

  String? get _baseTrack {
    final b = widget.modelBase;
    if (b == null) return null;
    final m = RegExp(r'(\d+)').firstMatch(b);
    return m?.group(1);
  }

  bool get _trackSensitive =>
      _type == SnapType.kernel ||
      _type == SnapType.gadget ||
      _type == SnapType.base;

  List<String> _filteredChannels() {
    final track = _baseTrack;
    if (!_trackSensitive || track == null) return _availableChannels;
    final filtered =
        _availableChannels.where((c) => c.startsWith('$track/')).toList();
    return filtered.isEmpty ? _availableChannels : filtered;
  }

  void _onQueryChanged(String value) {
    if (_brandMode) {
      _filterCatalog(value.trim());
      return;
    }
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      _runSearch(value.trim());
    });
  }

  void _filterCatalog(String query) {
    final cat = widget.catalog ?? const [];
    if (query.length < 2) {
      setState(() => _results = []);
      return;
    }
    final q = query.toLowerCase();
    final matches = cat
        .where((c) => c.name.toLowerCase().contains(q))
        .take(50)
        .map((c) => StoreSnap(
              name: c.name,
              snapId: c.id,
              title: c.name,
              summary: null,
              type: null,
              base: null,
              channels: const [],
            ))
        .toList();
    setState(() => _results = matches);
  }

  Future<void> _runSearch(String query) async {
    if (query.length < 2) {
      setState(() => _results = []);
      return;
    }
    setState(() => _searching = true);
    try {
      final results = await _store.findSnaps(query, widget.architecture,
          storeId: widget.storeId);
      if (!mounted) return;
      setState(() => _results = results.take(30).toList());
    } catch (_) {
      if (mounted) setState(() => _results = []);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _selectSnap(StoreSnap snap) async {
    final detectedType = _mapStoreType(snap.type);
    setState(() {
      _selected = snap;
      _type = detectedType;
      _loadingChannels = true;
      _availableChannels = [];
      _channel = null;
      _results = [];
      _searchController.text = snap.name;
    });
    try {
      final info = await _store.getSnapInfo(snap.name, widget.architecture,
          storeId: widget.storeId);
      setState(() {
        _availableChannels =
            info.channels.isEmpty ? ['latest/stable'] : info.channels;
        _selected = info;
        if (info.type != null) _type = _mapStoreType(info.type);
        _channel = _defaultChannel();
      });
    } catch (_) {
      setState(() {
        _availableChannels = ['latest/stable'];
        _channel = 'latest/stable';
      });
    } finally {
      if (mounted) setState(() => _loadingChannels = false);
    }
  }

  /// Resolves a snap by its exact name (for snaps unlisted from search) and
  /// feeds it into the normal selection flow so all channel/type/base
  /// automation still applies. The only manual step is typing the name.
  Future<void> _resolveManualName() async {
    final name = _manualNameController.text.trim();
    if (name.isEmpty) return;
    setState(() => _resolvingManual = true);
    try {
      // getSnapInfo throws if the name can't be resolved.
      final info =
          await _store.getSnapInfo(name, widget.architecture, storeId: widget.storeId);
      if (!mounted) return;
      // Feed into the same selection UI + automation as a search result.
      await _selectSnap(info);
      setState(() {
        _showManualAdd = false;
        _manualNameController.clear();
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(
              'No snap named "$name" found for '
              '"${widget.architecture}". Check the exact name.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _resolvingManual = false);
    }
  }

  String? _defaultChannel() {
    final list = _filteredChannels();
    if (list.isEmpty) return null;
    return list.firstWhere(
      (c) => c.endsWith('/stable'),
      orElse: () => list.first,
    );
  }

  Future<void> _add() async {
    final sel = _selected;
    final chan = _channel;
    if (sel == null || chan == null) return;
    setState(() => _adding = true);
    try {
      widget.onSnapSelected(
        SnapEntry(
          name: sel.name,
          id: sel.snapId,
          type: _type,
          defaultChannel: chan,
        ),
        sel.base,
      );
      setState(() {
        _selected = null;
        _availableChannels = [];
        _channel = null;
        _searchController.clear();
        _results = [];
      });
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final channels = _filteredChannels();
    final channelValue =
        (_channel != null && channels.contains(_channel)) ? _channel : null;
    final label = _brandMode
        ? 'Search brand store (${widget.architecture})'
        : 'Search snap (${widget.architecture})';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  labelText: label,
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searching
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : (_searchController.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                setState(() {
                                  _searchController.clear();
                                  _results = [];
                                  _selected = null;
                                  _availableChannels = [];
                                  _channel = null;
                                });
                              },
                            )
                          : null),
                ),
                onChanged: _onQueryChanged,
                onSubmitted: (v) =>
                    _brandMode ? _filterCatalog(v.trim()) : _runSearch(v),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 190,
              child: DropdownButtonFormField<String>(
                value: channelValue,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: 'Channel',
                  suffixIcon: _loadingChannels
                      ? const Padding(
                          padding: EdgeInsets.all(10),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : null,
                ),
                items: channels
                    .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                    .toList(),
                onChanged: _selected == null
                    ? null
                    : (v) => setState(() => _channel = v),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 150,
              child: DropdownButtonFormField<SnapType>(
                value: _selected == null ? null : _type,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Type'),
                icon: const SizedBox.shrink(),
                disabledHint: Text(
                  _selected == null ? '-' : _type.name,
                  style: TextStyle(
                    color: _selected == null
                        ? Theme.of(context).hintColor
                        : Theme.of(context).textTheme.bodyLarge?.color,
                  ),
                ),
                items: SnapType.values
                    .map((t) => DropdownMenuItem(value: t, child: Text(t.name)))
                    .toList(),
                onChanged: null,
              ),
            ),
            const SizedBox(width: 12),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ElevatedButton.icon(
                onPressed: (_selected == null || _channel == null || _adding)
                    ? null
                    : _add,
                icon: _adding
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add),
                label: const Text('Add'),
              ),
            ),
          ],
        ),
        if (_results.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 8),
            constraints: const BoxConstraints(maxHeight: 260),
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _results.length,
              itemBuilder: (context, i) {
                final snap = _results[i];
                final selected = _selected?.name == snap.name;
                return ListTile(
                  dense: true,
                  selected: selected,
                  leading: snap.type != null
                      ? _typeBadge(context, snap.type!)
                      : null,
                  title: Text(snap.title ?? snap.name),
                  subtitle: Text(
                    snap.summary ?? snap.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => _selectSnap(snap),
                );
              },
            ),
          ),
        // Collapsible "add by exact name" for snaps unlisted from search.
        if (!_showManualAdd)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _showManualAdd = true),
              icon: const Icon(Icons.edit_note),
              label: const Text('Snap not listed? Add by exact name'),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _manualNameController,
                    decoration: const InputDecoration(
                      labelText: 'Exact snap name',
                      helperText: 'For snaps unlisted from search '
                          '(e.g. gtk-common-themes)',
                      isDense: true,
                    ),
                    onSubmitted: (_) => _resolveManualName(),
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: _resolvingManual
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : ElevatedButton(
                          onPressed: _resolveManualName,
                          child: const Text('Resolve'),
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Cancel',
                    onPressed: () => setState(() {
                      _showManualAdd = false;
                      _manualNameController.clear();
                    }),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _typeBadge(BuildContext context, String type) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withOpacity(0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(type, style: const TextStyle(fontSize: 10)),
    );
  }
}
