import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'sd_types.dart';

export 'sd_types.dart';

// Enums and backend availability live in sd_types.dart so Flutter web can
// import them without dart:ffi.

enum SampleMethod {
  euler,
  eulerA,
  heun,
  dpm2,
  dpmpp2sA,
  dpmpp2m,
  dpmpp2mv2,
  ipndm,
  ipndmV,
  lcm,
  ddimTrailing,
  tcd,
  resMultistep,
  res2s,
  erSde,
}

enum Schedule {
  discrete,
  karras,
  exponential,
  ays,
  gits,
  sgmUniform,
  simple,
  smoothstep,
  klOptimal,
  lcm,
  bongTangent,
}

// ---------------------------------------------------------------------------
// Native typedefs
// ---------------------------------------------------------------------------

typedef ProgressCallbackNative = Void Function(
    Int32 step, Int32 steps, Float time);
typedef LogCallbackNative = Void Function(Int32 level, Pointer<Utf8> text);

typedef SdFfiSetProgressCallbackNative = Void Function(
    Pointer<NativeFunction<ProgressCallbackNative>> cb);
typedef SdFfiSetProgressCallback = void Function(
    Pointer<NativeFunction<ProgressCallbackNative>> cb);

typedef SdFfiSetLogCallbackNative = Void Function(
    Pointer<NativeFunction<LogCallbackNative>> cb);
typedef SdFfiSetLogCallback = void Function(
    Pointer<NativeFunction<LogCallbackNative>> cb);

typedef SdFfiInitNative = Pointer<Void> Function(
  Pointer<Utf8> modelPath,
  Int32 nThreads,
  Bool flashAttn,
  Bool vaeTiling,
  Pointer<Utf8> taesdPath,
  Int32 wtype,
  Int32 backend,
);
typedef SdFfiInit = Pointer<Void> Function(
  Pointer<Utf8> modelPath,
  int nThreads,
  bool flashAttn,
  bool vaeTiling,
  Pointer<Utf8> taesdPath,
  int wtype,
  int backend,
);

// Extended init exposing full sd_ctx_params_t fields
typedef SdFfiInitExNative = Pointer<Void> Function(
  Pointer<Utf8> modelPath,
  Int32 nThreads,
  Bool flashAttn,
  Bool vaeTiling,
  Pointer<Utf8> taesdPath,
  Pointer<Utf8> vaePath,
  Pointer<Utf8> clipLPath,
  Int32 wtype,
  Int32 backend,
  Bool offloadParamsToCpu,
  Bool enableMmap,
  Bool keepVaeOnCpu,
  Float maxVram,
);
typedef SdFfiInitEx = Pointer<Void> Function(
  Pointer<Utf8> modelPath,
  int nThreads,
  bool flashAttn,
  bool vaeTiling,
  Pointer<Utf8> taesdPath,
  Pointer<Utf8> vaePath,
  Pointer<Utf8> clipLPath,
  int wtype,
  int backend,
  bool offloadParamsToCpu,
  bool enableMmap,
  bool keepVaeOnCpu,
  double maxVram,
);

typedef SdFfiFreeNative = Void Function(Pointer<Void> ctx);
typedef SdFfiFree = void Function(Pointer<Void> ctx);

typedef SdFfiGenerateNative = Pointer<Uint8> Function(
  Pointer<Void> ctx,
  Pointer<Utf8> prompt,
  Pointer<Utf8> negativePrompt,
  Int32 width,
  Int32 height,
  Int32 steps,
  Int64 seed,
  Float cfgScale,
  Int32 sampleMethod,
  Int32 schedule,
  Bool vaeTiling,
  Pointer<IntPtr> outSize,
);
typedef SdFfiGenerate = Pointer<Uint8> Function(
  Pointer<Void> ctx,
  Pointer<Utf8> prompt,
  Pointer<Utf8> negativePrompt,
  int width,
  int height,
  int steps,
  int seed,
  double cfgScale,
  int sampleMethod,
  int schedule,
  bool vaeTiling,
  Pointer<IntPtr> outSize,
);

typedef SdFfiGetCoresNative = Int32 Function();
typedef SdFfiGetCores = int Function();

// ---------------------------------------------------------------------------
// Global isolate communication
// ---------------------------------------------------------------------------

SendPort? _globalSendPort;

void _staticProgressCallback(int step, int steps, double time) {
  _globalSendPort?.send({
    'type': 'progress',
    'step': step,
    'steps': steps,
    'time': time,
  });
}

void _staticLogCallback(int level, Pointer<Utf8> text) {
  _globalSendPort?.send({
    'type': 'log',
    'level': level,
    'message': text.toDartString(),
  });
}

// ---------------------------------------------------------------------------
// FFI Bindings singleton
// ---------------------------------------------------------------------------

class SdFfiBindings {
  static DynamicLibrary? _lib;
  static String _currentBackendLib = '';

  /// Returns the backend whose library is currently loaded,
  /// or [Backend.cpu] if nothing is loaded yet.
  static Backend get loadedBackend {
    if (_currentBackendLib.isEmpty) return Backend.cpu;
    return Backend.values.firstWhere(
      (b) => b.libraryName == _currentBackendLib,
      orElse: () => Backend.cpu,
    );
  }

  static late SdFfiSetProgressCallback setProgressCallback;
  static late SdFfiSetLogCallback setLogCallback;
  static late SdFfiInit init;
  static late SdFfiInitEx initEx;
  static late SdFfiFree freeCtx;
  static late SdFfiGenerate generate;
  static late SdFfiGetCores getCores;

  static Pointer<NativeFunction<ProgressCallbackNative>>? _progressPtr;
  static Pointer<NativeFunction<LogCallbackNative>>? _logPtr;

  /// Initialize FFI bindings for a specific backend.
  /// Call this before using any other functions.
  static void initialize([Backend backend = Backend.cpu]) {
    if (Platform.isAndroid) {
      final libName = backend.libraryName;
      if (_lib != null && _currentBackendLib == libName) return;

      print('[SdFfiBindings] Loading backend library: $libName');
      try {
        _lib = DynamicLibrary.open(libName);
        _currentBackendLib = libName;
        print('[SdFfiBindings] Loaded: $libName');
      } catch (e) {
        print('[SdFfiBindings] Failed to load $libName: $e');
        rethrow;
      }
    } else {
      throw UnsupportedError('SdFfiBindings only supports Android');
    }

    _lookupFunctions();
  }

  static void _lookupFunctions() {
    if (_lib == null) {
      throw StateError('FFI library not loaded. Call initialize() first.');
    }

    setProgressCallback = _lib!.lookupFunction<SdFfiSetProgressCallbackNative,
        SdFfiSetProgressCallback>('sd_ffi_set_progress_callback');

    setLogCallback = _lib!
        .lookupFunction<SdFfiSetLogCallbackNative, SdFfiSetLogCallback>(
            'sd_ffi_set_log_callback');

    init = _lib!.lookupFunction<SdFfiInitNative, SdFfiInit>('sd_ffi_init');
    initEx =
        _lib!.lookupFunction<SdFfiInitExNative, SdFfiInitEx>('sd_ffi_init_ex');
    // Ensure the backend library is actually available; if not, mark it unavailable
    if (_currentBackendLib != Backend.cpu.libraryName) {
      final backend =
          Backend.values.firstWhere((b) => b.libraryName == _currentBackendLib);
      print('[SdFfiBindings] Backend ${backend.displayName} loaded');
    }

    freeCtx = _lib!.lookupFunction<SdFfiFreeNative, SdFfiFree>('sd_ffi_free');

    generate = _lib!
        .lookupFunction<SdFfiGenerateNative, SdFfiGenerate>('sd_ffi_generate');

    getCores = _lib!
        .lookupFunction<SdFfiGetCoresNative, SdFfiGetCores>('sd_ffi_get_cores');
  }

  static void setupCallbacks(SendPort sendPort) {
    _globalSendPort = sendPort;

    _progressPtr ??=
        Pointer.fromFunction<ProgressCallbackNative>(_staticProgressCallback);
    _logPtr ??= Pointer.fromFunction<LogCallbackNative>(_staticLogCallback);

    setProgressCallback(_progressPtr!);
    setLogCallback(_logPtr!);
  }

  static void clearCallbacks() {
    setProgressCallback(Pointer.fromAddress(0));
    setLogCallback(Pointer.fromAddress(0));
    _globalSendPort = null;
  }
}
