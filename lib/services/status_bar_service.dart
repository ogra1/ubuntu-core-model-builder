import 'dart:async';

import 'package:flutter/material.dart';
import 'package:yaru_icons/yaru_icons.dart';

/// Severity of a [StatusMessage].
enum StatusSeverity { info, success, error }

/// One user-facing notification shown in the app's status bar.
class StatusMessage {
  final String text;
  final StatusSeverity severity;

  /// Bumped on every posted message so the bar's fade animation re-triggers
  /// even when the same text is reported twice in a row.
  final int token;

  const StatusMessage({
    required this.text,
    required this.severity,
    required this.token,
  });
}

/// App-wide replacement for [ScaffoldMessenger] snackbars.
///
/// Floating toasts are out of place on a desktop surface: they cover
/// whatever the user is reading and vanish on a fixed timer, so real errors
/// are often missed. Instead this service keeps the most recent message in
/// the app's footer bar.
///
/// Message lifetime:
///  * **info / success** — auto-clear after [autoClearDuration] (long enough
///    to read, short enough not to linger);
///  * **error** — stays visible, in its error color, until the user
///    dismisses it (close button or the Escape key), navigates to another
///    wizard step, or a newer message replaces it.
class StatusBarService extends ChangeNotifier {
  StatusBarService._();

  static final StatusBarService instance = StatusBarService._();

  /// How long info/success messages stay visible before auto-clearing.
  static const Duration autoClearDuration = Duration(seconds: 5);

  StatusMessage? _current;
  int _token = 0;
  Timer? _autoClear;

  StatusMessage? get current => _current;
  bool get hasCurrent => _current != null;

  void show(
    String text, {
    StatusSeverity severity = StatusSeverity.info,
  }) {
    _cancelAutoClear();
    _current = StatusMessage(
      text: text,
      severity: severity,
      token: ++_token,
    );
    notifyListeners();
    if (severity != StatusSeverity.error) {
      _autoClear = Timer(autoClearDuration, clear);
    }
  }

  void error(String text) => show(text, severity: StatusSeverity.error);

  void success(String text) => show(text, severity: StatusSeverity.success);

  /// Dismiss the current message, if any.
  void clear() {
    _cancelAutoClear();
    if (_current == null) return;
    _current = null;
    notifyListeners();
  }

  void _cancelAutoClear() {
    _autoClear?.cancel();
    _autoClear = null;
  }
}

/// Convenience for call sites that already hold a [BuildContext].
extension StatusBarContext on BuildContext {
  void postStatus(
    String text, {
    StatusSeverity severity = StatusSeverity.info,
  }) =>
      StatusBarService.instance.show(text, severity: severity);

  void postError(String text) => StatusBarService.instance.error(text);

  void postSuccess(String text) => StatusBarService.instance.success(text);
}

/// Inline status content: a severity icon, the current message, and — for
/// errors — a close button.
///
/// It is meant to be embedded in a host row (the app's footer bar) rather
/// than occupying its own: it supplies no padding or height of its own, so
/// it sizes to the row around it and the bar never grows. Renders nothing
/// while the [StatusBarService] holds no message.
class StatusBarContent extends StatelessWidget {
  const StatusBarContent({super.key});

  @override
  Widget build(BuildContext context) {
    final current = StatusBarService.instance.current;
    if (current == null) return const SizedBox.shrink();
    return _MessageRow(
      key: ValueKey(current.token),
      message: current,
      onDismiss: StatusBarService.instance.clear,
    );
  }
}

class _MessageRow extends StatelessWidget {
  final StatusMessage message;
  final VoidCallback onDismiss;

  const _MessageRow({
    super.key,
    required this.message,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final (icon, iconColor, textColor) = switch (message.severity) {
      StatusSeverity.error => (
          YaruIcons.warning,
          scheme.error,
          scheme.error,
        ),
      StatusSeverity.success => (
          YaruIcons.checkmark,
          _successColor,
          _successColor,
        ),
      StatusSeverity.info => (
          YaruIcons.information,
          theme.hintColor,
          null,
        ),
    };

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: iconColor),
        const SizedBox(width: 8),
        Flexible(
          child: TruncatingTooltipText(
            message.text,
            style: theme.textTheme.bodySmall?.copyWith(color: textColor),
          ),
        ),
        if (message.severity == StatusSeverity.error)
          IconButton(
            icon: const Icon(Icons.close, size: 14),
            tooltip: 'Dismiss (Esc)',
            onPressed: onDismiss,
            iconSize: 14,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }
}

/// Single-line text that ellipsizes when it doesn't fit and — only then —
/// gains a [Tooltip] revealing the full text on hover.
///
/// The decision is based on actual rendering (measured with a
/// [TextPainter] at the available width and the ambient text scaler), not
/// on the string's length: short messages never get a tooltip, long ones
/// always do, regardless of window width.
class TruncatingTooltipText extends StatelessWidget {
  final String text;
  final TextStyle? style;

  const TruncatingTooltipText(this.text, {super.key, this.style});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final ellipsized = Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: _styleOf(context),
        );
        final width = constraints.maxWidth;
        if (width <= 0 || width.isInfinite) return ellipsized;

        final painter = TextPainter(
          text: TextSpan(text: text, style: _styleOf(context)),
          textDirection: TextDirection.ltr,
          maxLines: 1,
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: double.infinity);
        if (painter.width <= width) return ellipsized;

        // The status bar sits at the bottom of the window: open above.
        // Keep the tooltip up long after the pointer drifts off (10s) so a
        // long error can actually be read.
        return Tooltip(
          message: text,
          preferBelow: false,
          showDuration: const Duration(seconds: 10),
          child: ellipsized,
        );
      },
    );
  }

  TextStyle? _styleOf(BuildContext context) =>
      style ?? Theme.of(context).textTheme.bodySmall;
}

const _successColor = Color(0xFF0E8420);
