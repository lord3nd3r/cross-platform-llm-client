import 'dart:ffi' show Abi;

/// APK ABI tag used when picking a GitHub release asset.
String abiTag() {
  switch (Abi.current()) {
    case Abi.androidArm64:
      return 'arm64-v8a';
    case Abi.androidArm:
      return 'armeabi-v7a';
    case Abi.androidX64:
      return 'x86_64';
    default:
      return 'universal';
  }
}
