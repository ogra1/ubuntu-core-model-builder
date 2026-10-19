// The Snap Store auth FFI client now lives in the shared `snapstore_auth`
// package (the Rust backend + Dart binding moved out of this repo so other
// Flutter apps can reuse it). This file is a thin re-export kept at the
// original path so existing imports keep working unchanged.
//
// The native library is located and the full API documented in the package:
//   package:snapstore_auth/snapstore_auth.dart
//   -> lib/src/snapstore_auth_client.dart
export 'package:snapstore_auth/snapstore_auth.dart';
