import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Every string the library returns must be released with [freeString].
class ZcashFfiBindings {
  final DynamicLibrary _lib;

  ZcashFfiBindings._(this._lib);

  late final _version = _lib.lookupFunction<
      Pointer<Utf8> Function(),
      Pointer<Utf8> Function()>('zcash_ffi_version');

  late final _freeString = _lib.lookupFunction<
      Void Function(Pointer<Utf8>),
      void Function(Pointer<Utf8>)>('zcash_ffi_free_string');

  late final _seedToAccountUfvk = _lib.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint32),
      Pointer<Utf8> Function(
          Pointer<Utf8>, Pointer<Utf8>, int)>('zcash_ffi_seed_to_account_ufvk');

  late final _seedToTransparentXpub = _lib.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint32),
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>,
          int)>('zcash_ffi_seed_to_transparent_xpub');

  late final _ufvkToAddress = _lib.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint32),
      Pointer<Utf8> Function(
          Pointer<Utf8>, Pointer<Utf8>, int)>('zcash_ffi_ufvk_to_address');

  late final _transparentAddress = _lib.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint32),
      Pointer<Utf8> Function(
          Pointer<Utf8>, Pointer<Utf8>, int)>('zcash_ffi_transparent_address');

  late final _addressType = _lib.lookupFunction<
      Int32 Function(Pointer<Utf8>),
      int Function(Pointer<Utf8>)>('zcash_ffi_address_type');

  late final _isTransparentAddress = _lib.lookupFunction<
      Bool Function(Pointer<Utf8>),
      bool Function(Pointer<Utf8>)>('zcash_ffi_is_transparent_address');

  late final _isShieldedAddress = _lib.lookupFunction<
      Bool Function(Pointer<Utf8>),
      bool Function(Pointer<Utf8>)>('zcash_ffi_is_shielded_address');

  String version() {
    final ptr = _version();
    final s = ptr.toDartString();
    freeString(ptr);
    return s;
  }

  void freeString(Pointer<Utf8> ptr) => _freeString(ptr);

  String seedToAccountUfvk(String seedHex, String network, int account) {
    final seedPtr = seedHex.toNativeUtf8();
    final netPtr = network.toNativeUtf8();
    try {
      final result = _seedToAccountUfvk(seedPtr, netPtr, account);
      final json = result.toDartString();
      freeString(result);
      return json;
    } finally {
      calloc.free(seedPtr);
      calloc.free(netPtr);
    }
  }

  String seedToTransparentXpub(String seedHex, String network, int account) {
    final seedPtr = seedHex.toNativeUtf8();
    final netPtr = network.toNativeUtf8();
    try {
      final result = _seedToTransparentXpub(seedPtr, netPtr, account);
      final json = result.toDartString();
      freeString(result);
      return json;
    } finally {
      calloc.free(seedPtr);
      calloc.free(netPtr);
    }
  }

  String ufvkToAddress(String ufvk, String network, int diversifierIndex) {
    final ufvkPtr = ufvk.toNativeUtf8();
    final netPtr = network.toNativeUtf8();
    try {
      final result = _ufvkToAddress(ufvkPtr, netPtr, diversifierIndex);
      final json = result.toDartString();
      freeString(result);
      return json;
    } finally {
      calloc.free(ufvkPtr);
      calloc.free(netPtr);
    }
  }

  String transparentAddress(String xpub, String network, int childIndex) {
    final xpubPtr = xpub.toNativeUtf8();
    final netPtr = network.toNativeUtf8();
    try {
      final result = _transparentAddress(xpubPtr, netPtr, childIndex);
      final json = result.toDartString();
      freeString(result);
      return json;
    } finally {
      calloc.free(xpubPtr);
      calloc.free(netPtr);
    }
  }

  /// 0 unknown, 1 transparent, 2 Sapling, 3 unified.
  int addressType(String addr) {
    final ptr = addr.toNativeUtf8();
    try {
      return _addressType(ptr);
    } finally {
      calloc.free(ptr);
    }
  }

  bool isTransparentAddress(String addr) {
    final ptr = addr.toNativeUtf8();
    try {
      return _isTransparentAddress(ptr);
    } finally {
      calloc.free(ptr);
    }
  }

  bool isShieldedAddress(String addr) {
    final ptr = addr.toNativeUtf8();
    try {
      return _isShieldedAddress(ptr);
    } finally {
      calloc.free(ptr);
    }
  }

  static ZcashFfiBindings? _instance;

  /// `ZCASH_FFI_LIB` overrides the library path.
  static ZcashFfiBindings get instance {
    return _instance ??= ZcashFfiBindings._(
      DynamicLibrary.open(_defaultLibPath()),
    );
  }

  static String _defaultLibPath() {
    final envPath = Platform.environment['ZCASH_FFI_LIB'];
    if (envPath != null && envPath.isNotEmpty) return envPath;

    if (Platform.isLinux) return 'libzcash_ffi.so';
    if (Platform.isMacOS) return 'libzcash_ffi.dylib';
    if (Platform.isWindows) return 'zcash_ffi.dll';
    throw UnsupportedError(
        'Unsupported platform: ${Platform.operatingSystem}');
  }
}
