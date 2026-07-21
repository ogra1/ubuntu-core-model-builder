import 'package:flutter/material.dart';
import 'model_assertion.dart';
import '../services/store_service.dart';
import '../services/tool_locator.dart';

enum WizardStep { account, metadata, snaps, keys, review }

extension WizardStepInfo on WizardStep {
  String get label => switch (this) {
        WizardStep.account => 'Account',
        WizardStep.metadata => 'Metadata',
        WizardStep.snaps => 'Snaps',
        WizardStep.keys => 'Signing Key',
        WizardStep.review => 'Review & Sign',
      };

  IconData get icon => switch (this) {
        WizardStep.account => Icons.account_circle_outlined,
        WizardStep.metadata => Icons.description_outlined,
        WizardStep.snaps => Icons.widgets_outlined,
        WizardStep.keys => Icons.vpn_key_outlined,
        WizardStep.review => Icons.check_circle_outline,
      };

  IconData get selectedIcon => switch (this) {
        WizardStep.account => Icons.account_circle,
        WizardStep.metadata => Icons.description,
        WizardStep.snaps => Icons.widgets,
        WizardStep.keys => Icons.vpn_key,
        WizardStep.review => Icons.check_circle,
      };
}

class WizardState extends ChangeNotifier {
  final ModelAssertion model = ModelAssertion();

  StoreAccount? account;
  ToolStatus? toolStatus;
  String? selectedKeyName;
  String? signedAssertion;
  String? busyMessage;

  /// If non-null while [busy], the overlay shows a Cancel button that
  /// invokes this callback.
  VoidCallback? busyCancelCallback;

  bool _busy = false;
  bool get busy => _busy;
  set busy(bool value) {
    _busy = value;
    if (!value) {
      busyMessage = null;
      busyCancelCallback = null;
    }
    notifyListeners();
  }

  /// Set busy state with an optional status message and optional cancel
  /// callback shown in the overlay.
  void setBusy(bool value, {String? message, VoidCallback? onCancel}) {
    _busy = value;
    busyMessage = value ? message : null;
    busyCancelCallback = value ? onCancel : null;
    notifyListeners();
  }

  void refresh() => notifyListeners();

  void setAccount(StoreAccount? acct) {
    account = acct;
    if (acct != null) {
      model.brandId = acct.accountId;
      model.authorityId = acct.accountId;
    } else {
      model.brandId = null;
      model.authorityId = null;
    }
    notifyListeners();
  }

  bool isStepComplete(WizardStep step) => switch (step) {
        WizardStep.account =>
          account != null && (toolStatus?.ready ?? false),
        WizardStep.metadata => _metadataValid,
        WizardStep.snaps => _snapsValid,
        WizardStep.keys => selectedKeyName != null,
        WizardStep.review => signedAssertion != null,
      };

  bool isStepEnabled(WizardStep step) {
    final index = step.index;
    if (index == 0) return true;
    for (var i = 0; i < index; i++) {
      if (!isStepComplete(WizardStep.values[i])) return false;
    }
    return true;
  }

  bool get _metadataValid {
    final name = model.model;
    final nameOk = name != null &&
        RegExp(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?$').hasMatch(name);
    return nameOk && model.base != null && model.brandId != null;
  }

  bool get _snapsValid {
    final hasKernel = model.snaps.any((s) => s.type.name == 'kernel');
    final hasGadget = model.snaps.any((s) => s.type.name == 'gadget');
    final hasSnapd = model.snaps.any((s) => s.type.name == 'snapd');
    final baseName = model.base;
    final hasBase = baseName != null &&
        model.snaps.any((s) => s.type.name == 'base' && s.name == baseName);
    return hasKernel && hasGadget && hasSnapd && hasBase;
  }

  List<String> validationErrors(WizardStep step) {
    final errors = <String>[];
    switch (step) {
      case WizardStep.account:
        if (account == null) errors.add('Sign in to your Snap Store account.');
        if (!(toolStatus?.ready ?? false)) {
          errors.add('Install snap and snapcraft tooling.');
        }
      case WizardStep.metadata:
        if (model.model == null || model.model!.isEmpty) {
          errors.add('Model name is required.');
        } else if (!RegExp(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?$')
            .hasMatch(model.model!)) {
          errors.add('Model name must be lowercase alphanumeric with dashes.');
        }
        if (model.base == null) errors.add('Select a base snap.');
      case WizardStep.snaps:
        if (!model.snaps.any((s) => s.type.name == 'kernel')) {
          errors.add('Add a kernel snap.');
        }
        if (!model.snaps.any((s) => s.type.name == 'gadget')) {
          errors.add('Add a gadget snap.');
        }
        if (!model.snaps.any((s) => s.type.name == 'snapd')) {
          errors.add('Add the snapd snap.');
        }
        final baseName = model.base;
        if (baseName == null) {
          errors.add('Select a base on the Metadata step first.');
        } else if (!model.snaps.any(
            (s) => s.type.name == 'base' && s.name == baseName)) {
          errors.add('Add the "$baseName" base snap.');
        }
      case WizardStep.keys:
        if (selectedKeyName == null) {
          errors.add('Select or create a signing key.');
        }
      case WizardStep.review:
        if (signedAssertion == null) {
          errors.add('Sign the model to finish.');
        }
    }
    return errors;
  }
}
