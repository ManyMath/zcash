import 'dart:ffi';

import 'package:ffi/ffi.dart';

typedef NativeStringFree = void Function(Pointer<Utf8> ptr);

/// Frees [ptr] after reading it.
String takeNativeString(
  Pointer<Utf8> ptr, {
  required NativeStringFree free,
  String context = 'zcash-ffi',
}) {
  if (ptr == nullptr) {
    throw StateError('$context returned a null string pointer');
  }
  try {
    return ptr.toDartString();
  } finally {
    free(ptr);
  }
}
