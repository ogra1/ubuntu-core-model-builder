import 'snap_entry.dart';

enum ModelGrade { dangerous, signed, secured }

enum ModelArchitecture { amd64, arm64, armhf, i386, riscv64 }

/// Controls who may sign system-user assertions the device accepts.
/// brandOnly => omit the field (default: only the brand can sign).
/// specificIds => a list of account IDs allowed to sign.
/// anyone => the literal '*' (any account may sign).
enum SystemUserAuthorityMode { brandOnly, specificIds, anyone }

/// storage-safety: controls disk encryption. `unset` omits the field, letting
/// the grade-based default apply (secured => encrypted; otherwise
/// prefer-encrypted).
enum StorageSafety { unset, encrypted, preferEncrypted, preferUnencrypted }

/// A reference to a validation set the model enforces.
/// mode is 'enforce' or 'prefer-enforce'; sequence is optional (pins a
/// specific sequence, else the latest is used).
class ValidationSetRef {
  String accountId;
  String name;
  String mode;
  int? sequence;

  ValidationSetRef({
    required this.accountId,
    required this.name,
    this.mode = 'enforce',
    this.sequence,
  });

  ValidationSetRef clone() => ValidationSetRef(
        accountId: accountId,
        name: name,
        mode: mode,
        sequence: sequence,
      );
}

class ModelAssertion {
  String type = 'model';
  String? authorityId;
  String? brandId;
  String? series = '16';
  String? model;
  ModelArchitecture architecture = ModelArchitecture.amd64;
  String? base;
  ModelGrade grade = ModelGrade.signed;
  String? store; // optional brand store ID; null/empty => global store
  SystemUserAuthorityMode systemUserAuthorityMode =
      SystemUserAuthorityMode.brandOnly;
  List<String> systemUserAuthorityIds = [];
  List<ValidationSetRef> validationSets = [];
  StorageSafety storageSafety = StorageSafety.unset;
  List<String> serialAuthorityIds = []; // empty => brand only (omit)
  List<SnapEntry> snaps = [];
  DateTime timestamp = DateTime.now().toUtc();

  Map<String, dynamic> toAssertionMap() {
    return {
      'type': type,
      'authority-id': authorityId,
      'series': series,
      'brand-id': brandId,
      'model': model,
      'architecture': architecture.name,
      'base': base,
      'grade': grade.name,
      'store': store,
      'snaps': snaps.map((s) => s.toMap()).toList(),
      'timestamp': timestamp.toIso8601String(),
    };
  }
}
