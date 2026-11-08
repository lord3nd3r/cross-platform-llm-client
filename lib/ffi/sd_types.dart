import 'sd_backend_probe.dart'
    if (dart.library.html) 'sd_backend_probe_web.dart';

// Shared image-backend types. No dart:ffi here, so Flutter web can import them.
// ignore_for_file: constant_identifier_names

enum QuantizationType {
  f32,
  f16,
  q4_0,
  q4_1,
  q5_0,
  q5_1,
  q8_0,
  q8_1,
  q2_k,
  q3_k,
  q4_k,
  q5_k,
  q6_k,
  q8_k,
}

extension QuantizationTypeExtension on QuantizationType {
  String get displayName {
    switch (this) {
      case QuantizationType.f32:
        return 'FP32';
      case QuantizationType.f16:
        return 'FP16';
      case QuantizationType.q4_0:
        return 'Q4_0 (fastest)';
      case QuantizationType.q4_1:
        return 'Q4_1';
      case QuantizationType.q5_0:
        return 'Q5_0';
      case QuantizationType.q5_1:
        return 'Q5_1';
      case QuantizationType.q8_0:
        return 'Q8_0 (balanced)';
      case QuantizationType.q8_1:
        return 'Q8_1';
      case QuantizationType.q2_k:
        return 'Q2_K (smallest)';
      case QuantizationType.q3_k:
        return 'Q3_K';
      case QuantizationType.q4_k:
        return 'Q4_K (recommended)';
      case QuantizationType.q5_k:
        return 'Q5_K';
      case QuantizationType.q6_k:
        return 'Q6_K (near-lossless)';
      case QuantizationType.q8_k:
        return 'Q8_K';
    }
  }

  /// Values from stable-diffusion.h. Gaps match the C enum.
  int get nativeValue {
    switch (this) {
      case QuantizationType.f32:
        return 0;
      case QuantizationType.f16:
        return 1;
      case QuantizationType.q4_0:
        return 2;
      case QuantizationType.q4_1:
        return 3;
      case QuantizationType.q5_0:
        return 6;
      case QuantizationType.q5_1:
        return 7;
      case QuantizationType.q8_0:
        return 8;
      case QuantizationType.q8_1:
        return 9;
      case QuantizationType.q2_k:
        return 10;
      case QuantizationType.q3_k:
        return 11;
      case QuantizationType.q4_k:
        return 12;
      case QuantizationType.q5_k:
        return 13;
      case QuantizationType.q6_k:
        return 14;
      case QuantizationType.q8_k:
        return 15;
    }
  }
}

enum Backend {
  cpu,
  vulkan,
  opencl,
  metal,
}

extension BackendExtension on Backend {
  String get displayName {
    switch (this) {
      case Backend.cpu:
        return 'CPU';
      case Backend.vulkan:
        return 'Vulkan (GPU)';
      case Backend.opencl:
        return 'OpenCL (GPU)';
      case Backend.metal:
        return 'Apple NPU';
    }
  }

  String get libraryName {
    switch (this) {
      case Backend.cpu:
        return 'libsd_jni.so';
      case Backend.vulkan:
        return 'libsd_jni_vulkan.so';
      case Backend.opencl:
        return 'libsd_jni_opencl.so';
      case Backend.metal:
        return 'libsd_metal.dylib';
    }
  }

  /// CPU is always available. GPU backends are available only when this
  /// Android build actually ships the matching native library.
  bool get isAvailable => probeBackend(this);
}
