import 'dart:ffi';
import 'dart:io';

import 'sd_types.dart';

bool probeBackend(Backend backend) {
  if (backend == Backend.cpu) return true;
  if (!Platform.isAndroid) return false;
  try {
    DynamicLibrary.open(backend.libraryName);
    return true;
  } catch (_) {
    return false;
  }
}
