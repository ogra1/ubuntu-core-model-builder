import 'package:process_run/process_run.dart';

class ToolStatus {
  final bool hasSnap;
  final bool hasSnapcraft;
  final bool hasPinentry;
  final String? snapPath;
  final String? snapcraftPath;

  ToolStatus({
    required this.hasSnap,
    required this.hasSnapcraft,
    required this.hasPinentry,
    this.snapPath,
    this.snapcraftPath,
  });

  bool get ready => hasSnap && hasSnapcraft;
}

class ToolLocator {
  static Future<ToolStatus> check() async {
    final shell = Shell(throwOnError: false);

    Future<String?> which(String tool) async {
      final r = await shell.run('which $tool');
      if (r.first.exitCode != 0) return null;
      final out = r.outText.trim();
      return out.isEmpty ? null : out;
    }

    final snapPath = await which('snap');
    final snapcraftPath = await which('snapcraft');
    final pinentry = await which('pinentry-gnome3') ??
        await which('pinentry-gtk-2') ??
        await which('pinentry');

    return ToolStatus(
      hasSnap: snapPath != null,
      hasSnapcraft: snapcraftPath != null,
      hasPinentry: pinentry != null,
      snapPath: snapPath,
      snapcraftPath: snapcraftPath,
    );
  }

  static Future<void> installSnapcraft() async {
    final shell = Shell(throwOnError: false);
    await shell.run('snap install snapcraft --classic');
  }
}
