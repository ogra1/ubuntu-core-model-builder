import 'snap_entry.dart';

enum ModelGrade { dangerous, signed, secured }

enum ModelArchitecture { amd64, arm64, armhf, i386, riscv64 }

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
