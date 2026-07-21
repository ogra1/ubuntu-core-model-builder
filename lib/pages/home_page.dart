import 'package:flutter/material.dart';
import 'package:yaru/yaru.dart';

import '../theme/status_colors.dart';
import '../models/wizard_step.dart';
import '../services/store_service.dart';
import '../services/tool_locator.dart';
import 'account_page.dart';
import 'metadata_page.dart';
import 'snaps_page.dart';
import 'keys_page.dart';
import 'review_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final WizardState _state = WizardState();
  WizardStep _current = WizardStep.account;
  bool _extendedRail = true;

  @override
  void initState() {
    super.initState();
    _state.addListener(_onStateChanged);
    _bootstrap();
  }

  @override
  void dispose() {
    _state.removeListener(_onStateChanged);
    _state.dispose();
    super.dispose();
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _bootstrap() async {
    _state.busy = true;
    try {
      final tools = await ToolLocator.check();
      _state.toolStatus = tools;
      if (tools.ready) {
        final account = await StoreService().getCurrentAccount();
        _state.setAccount(account);
      }
    } finally {
      _state.busy = false;
    }
  }

  void _goTo(WizardStep step) {
    if (_state.isStepEnabled(step)) {
      setState(() => _current = step);
    } else {
      _showBlockedSnackBar(step);
    }
  }

  void _showBlockedSnackBar(WizardStep step) {
    for (final s in WizardStep.values) {
      if (s.index >= step.index) break;
      if (!_state.isStepComplete(s)) {
        final errors = _state.validationErrors(s);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Complete "${s.label}" first: '
              '${errors.isNotEmpty ? errors.first : ""}',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }
    }
  }

  bool get _canGoNext =>
      _state.isStepComplete(_current) &&
      _current.index < WizardStep.values.length - 1;

  bool get _canGoBack => _current.index > 0;

  void _next() {
    if (_canGoNext) _goTo(WizardStep.values[_current.index + 1]);
  }

  void _back() {
    if (_canGoBack) {
      setState(() => _current = WizardStep.values[_current.index - 1]);
    }
  }

  Widget _buildBody() {
    switch (_current) {
      case WizardStep.account:
        return AccountPage(state: _state, onRetry: _bootstrap);
      case WizardStep.metadata:
        return MetadataPage(model: _state.model, onChanged: _state.refresh);
      case WizardStep.snaps:
        return SnapsPage(model: _state.model, onChanged: _state.refresh);
      case WizardStep.keys:
        return KeysPage(state: _state);
      case WizardStep.review:
        return ReviewPage(state: _state);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const YaruWindowTitleBar(
        title: Text('Ubuntu Core Model Builder'),
      ),
      body: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                _buildNavigationRail(),
                const VerticalDivider(width: 1),
                Expanded(
                  child: Stack(
                    children: [
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        child: KeyedSubtree(
                          key: ValueKey(_current),
                          child: _buildBody(),
                        ),
                      ),
                      if (_state.busy) _buildBusyOverlay(),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          _buildFooterBar(),
        ],
      ),
    );
  }

  Widget _buildBusyOverlay() {
    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0x33000000),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              if (_state.busyMessage != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(_state.busyMessage!),
                ),
              ],
              if (_state.busyCancelCallback != null) ...[
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _state.busyCancelCallback,
                  icon: const Icon(Icons.close),
                  label: const Text('Cancel'),
                  style: OutlinedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.surface,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNavigationRail() {
    return NavigationRail(
      extended: _extendedRail,
      minExtendedWidth: 220,
      selectedIndex: _current.index,
      onDestinationSelected: (i) => _goTo(WizardStep.values[i]),
      leading: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: IconButton(
          icon: Icon(_extendedRail ? Icons.menu_open : Icons.menu),
          tooltip: _extendedRail ? 'Collapse' : 'Expand',
          onPressed: () => setState(() => _extendedRail = !_extendedRail),
        ),
      ),
      destinations: WizardStep.values.map((step) {
        final complete = _state.isStepComplete(step);
        final enabled = _state.isStepEnabled(step);
        return NavigationRailDestination(
          disabled: !enabled,
          icon: _StepIcon(icon: step.icon, complete: complete, enabled: enabled),
          selectedIcon: _StepIcon(
            icon: step.selectedIcon,
            complete: complete,
            enabled: enabled,
            selected: true,
          ),
          label: Text(step.label),
        );
      }).toList(),
    );
  }

  Widget _buildFooterBar() {
    final errors = _state.validationErrors(_current);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Row(
        children: [
          if (errors.isNotEmpty && _current != WizardStep.review)
            Expanded(
              child: Row(
                children: [
                  Icon(Icons.info_outline,
                      size: 18, color: Theme.of(context).colorScheme.error),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      errors.first,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.error,
                          ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            )
          else
            const Spacer(),
          const SizedBox(width: 16),
          OutlinedButton(
            onPressed: _canGoBack ? _back : null,
            child: const Text('Back'),
          ),
          const SizedBox(width: 12),
          if (_current != WizardStep.review)
            ElevatedButton(
              onPressed: _canGoNext ? _next : null,
              child: const Text('Next'),
            ),
        ],
      ),
    );
  }
}

class _StepIcon extends StatelessWidget {
  final IconData icon;
  final bool complete;
  final bool enabled;
  final bool selected;

  const _StepIcon({
    required this.icon,
    required this.complete,
    required this.enabled,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final baseColor = enabled
        ? (selected ? theme.colorScheme.primary : null)
        : theme.disabledColor;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(icon, color: baseColor),
        if (complete)
          Positioned(
            right: -4,
            top: -4,
            child: Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_circle,
                  size: 14, color: StatusColors.success),
            ),
          ),
      ],
    );
  }
}
