import 'dart:async';
import 'package:flutter/material.dart';
import '../models/store_snap.dart';
import '../models/snap_entry.dart';
import '../services/snapd_service.dart';

class SnapSearchField extends StatefulWidget {
  final void Function(SnapEntry) onSnapSelected;
  final String? modelBase;

  const SnapSearchField({
    super.key,
    required this.onSnapSelected,
    this.modelBase,
  });

  @override
  State<SnapSearchField> createState() => _SnapSearchFieldState();
}

class _SnapSearchFieldState extends State<SnapSearchField> {
  final _snapd = SnapdService();
  final _searchController = TextEditingController();

  Timer? _debounce;
  List<StoreSnap> _results = [];
  bool _searching = false;

  StoreSnap? _selected;
  List<String> _availableChannels = [];
  String? _channel;
  SnapType _type = SnapType.app;
  bool _loadingChannels = false;
  bool _adding = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
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
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      _runSearch(value.trim());
    });
  }

  Future<void> _runSearch(String query) async {
    if (query.length < 2) {
      setState(() => _results = []);
      return;
    }
    setState(() => _searching = true);
    try {
      final results = await _snapd.findSnaps(query);
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
      _type = detectedType; // auto-select kernel/gadget/base/snapd/app
      _loadingChannels = true;
      _availableChannels = [];
      _channel = null;
      _results = []; // collapse the results list once picked
      _searchController.text = snap.name;
    });
    try {
      final info = await _snapd.getSnapInfo(snap.name);
      setState(() {
        _availableChannels =
            info.channels.isEmpty ? ['stable'] : info.channels;
        _selected = info;
        _channel = _defaultChannel();
      });
    } catch (_) {
      setState(() {
        _availableChannels = ['stable'];
        _channel = 'stable';
      });
    } finally {
      if (mounted) setState(() => _loadingChannels = false);
    }
  }

  String? _defaultChannel() {
    final list = _filteredChannels();
    if (list.isEmpty) return null;
    return list.firstWhere(
      (c) => c.endsWith('/stable') || c == 'stable',
      orElse: () => list.first,
    );
  }

  void _onTypeChanged(SnapType? t) {
    setState(() {
      _type = t ?? SnapType.app;
      _channel = _defaultChannel();
    });
  }

  Future<void> _add() async {
    final sel = _selected;
    final chan = _channel;
    if (sel == null || chan == null) return;

    setState(() => _adding = true);
    try {
      widget.onSnapSelected(SnapEntry(
        name: sel.name,
        id: sel.snapId,
        type: _type,
        defaultChannel: chan,
      ));
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

  /// Maps snapd's snap type string to our SnapType enum.
  /// Defaults to app when unknown.
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
      case 'os': // legacy alias sometimes seen
        return SnapType.base;
      default:
        return SnapType.app;
    }
  }

  @override
  Widget build(BuildContext context) {
    final channels = _filteredChannels();
    final channelValue =
        (_channel != null && channels.contains(_channel)) ? _channel : null;

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
                  labelText: 'Search snap',
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
                onSubmitted: _runSearch,
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
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : null,
                ),
                items: channels
                    .map((c) =>
                        DropdownMenuItem(value: c, child: Text(c)))
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
                value: _type,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Type'),
                items: SnapType.values
                    .map((t) =>
                        DropdownMenuItem(value: t, child: Text(t.name)))
                    .toList(),
                onChanged: _onTypeChanged,
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
