import '../theme/status_colors.dart';
import 'package:flutter/material.dart';
import 'package:yaru/yaru.dart';
import '../services/assertion_verifier.dart';

class VerificationReportView extends StatelessWidget {
  final VerificationReport report;
  final VoidCallback? onTestImport;

  const VerificationReportView({
    super.key,
    required this.report,
    this.onTestImport,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return YaruSection(
      headline: Row(
        children: [
          const Text('Verification'),
          const SizedBox(width: 8),
          _summaryChip(theme),
        ],
      ),
      child: Column(
        children: [
          ...report.checks.map((c) => YaruTile(
                leading: _statusIcon(c.status),
                title: Text(c.label),
                subtitle: Text(c.detail, style: theme.textTheme.bodySmall),
              )),
          if (onTestImport != null) ...[
            const Divider(),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 18, color: theme.hintColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Optionally verify the full signature chain by '
                      'importing into snapd (modifies the local '
                      'assertion database).',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: onTestImport,
                    child: const Text('Test import'),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _summaryChip(ThemeData theme) {
    late final String label;
    late final Color color;
    if (report.allPassed) {
      if (report.hasWarnings) {
        label = 'Passed with warnings';
        color = StatusColors.orange;
      } else {
        label = 'Verified';
        color = StatusColors.success;
      }
    } else {
      label = 'Failed';
      color = theme.colorScheme.error;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: TextStyle(
            color: color, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _statusIcon(CheckStatus status) {
    return switch (status) {
      CheckStatus.pass =>
        const Icon(Icons.check_circle, color: StatusColors.success, size: 20),
      CheckStatus.warn =>
        const Icon(Icons.warning_amber, color: StatusColors.orange, size: 20),
      CheckStatus.fail =>
        const Icon(Icons.cancel, color: StatusColors.danger, size: 20),
    };
  }
}
