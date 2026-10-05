import '../models/model_assertion.dart';
import '../models/snap_entry.dart';
import 'store_api_service.dart';

class SeedSizeLine {
  final String label; // snap name, or "snap / component"
  final int bytes;
  SeedSizeLine(this.label, this.bytes);
}

class SeedSizeResult {
  final List<SeedSizeLine> lines;
  final int totalBytes;
  final List<String> warnings; // snaps whose size couldn't be resolved
  SeedSizeResult(this.lines, this.totalBytes, this.warnings);
}

/// Computes the total seeded snap size (sum of each snap's compressed
/// download size for its channel, plus any selected components). Because snaps
/// are loop-mounted squashfs, download size == on-disk footprint, so this is
/// the ubuntu-seed data size the user must account for (plus minor filesystem
/// overhead).
class SeedSizeCalculator {
  final StoreApiService _store;
  SeedSizeCalculator({StoreApiService? store})
      : _store = store ?? StoreApiService();

  Future<SeedSizeResult> calculate(ModelAssertion model) async {
    final arch = model.architecture.name;
    final storeId =
        (model.store != null && model.store!.isNotEmpty && model.store != 'ubuntu')
            ? model.store
            : null;

    final lines = <SeedSizeLine>[];
    final warnings = <String>[];
    var total = 0;

    // Resolve all snap sizes (and component sizes) in parallel.
    final futures = <Future<void>>[];
    final lineBuffer = <int, SeedSizeLine>{}; // keep order by index
    final compBuffers = <int, List<SeedSizeLine>>{};

    for (var i = 0; i < model.snaps.length; i++) {
      final s = model.snaps[i];
      futures.add(() async {
        final size = await _store.getDownloadSize(
            s.name, arch, s.defaultChannel,
            storeId: storeId);
        if (size != null) {
          lineBuffer[i] = SeedSizeLine(s.name, size);
        } else {
          warnings.add(s.name);
          lineBuffer[i] = SeedSizeLine('${s.name} (size unknown)', 0);
        }
        // Components for this snap.
        if (s.components.isNotEmpty) {
          final compSizes = await _store.getComponentSizes(
              s.name, arch, s.defaultChannel,
              storeId: storeId);
          final cl = <SeedSizeLine>[];
          for (final cname in s.components.keys) {
            final cs = compSizes[cname];
            if (cs != null) {
              cl.add(SeedSizeLine('${s.name} / $cname', cs));
            } else {
              warnings.add('$cname (component of ${s.name})');
              cl.add(SeedSizeLine('${s.name} / $cname (size unknown)', 0));
            }
          }
          compBuffers[i] = cl;
        }
      }());
    }
    await Future.wait(futures);

    // Assemble in model order: snap line then its component lines.
    for (var i = 0; i < model.snaps.length; i++) {
      final l = lineBuffer[i];
      if (l != null) {
        lines.add(l);
        total += l.bytes;
      }
      final cl = compBuffers[i];
      if (cl != null) {
        for (final c in cl) {
          lines.add(c);
          total += c.bytes;
        }
      }
    }

    return SeedSizeResult(lines, total, warnings);
  }

  /// Human-readable size (MiB/GiB).
  static String formatBytes(int bytes) {
    const mib = 1024 * 1024;
    const gib = mib * 1024;
    if (bytes >= gib) {
      return '${(bytes / gib).toStringAsFixed(2)} GiB';
    }
    return '${(bytes / mib).toStringAsFixed(1)} MiB';
  }
}
