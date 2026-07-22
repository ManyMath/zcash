import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:zcash/zcash.dart';

import 'native_asset_symbols.dart';
import 'native_result.dart';
import 'native_string.dart';

class ZcashFfiBindings {
  final Pointer<T> Function<T extends NativeType>(String symbol) _symbol;
  final String _libraryPath;

  ZcashFfiBindings._(this._symbol, this._libraryPath);

  factory ZcashFfiBindings.open(String path) =>
      ZcashFfiBindings._(DynamicLibrary.open(path).lookup, path);

  factory ZcashFfiBindings.nativeAssets() =>
      ZcashFfiBindings._(nativeAssetSymbol, nativeAssetsLibraryLabel);

  static const nativeAssetsLibraryLabel =
      'the zcash_ffi code asset (package:zcash_ffi/src/ffi/'
      'zcash_native_assets.dart)';

  late final _version = _symbol<NativeFunction<Pointer<Utf8> Function()>>(
    'zcash_ffi_version',
  ).asFunction<Pointer<Utf8> Function()>();

  late final _networkConstants =
      _symbol<NativeFunction<Pointer<Utf8> Function(Pointer<Utf8>)>>(
        'zcash_ffi_network_constants',
      ).asFunction<Pointer<Utf8> Function(Pointer<Utf8>)>();

  late final _freeString =
      _symbol<NativeFunction<Void Function(Pointer<Utf8>)>>(
        'zcash_ffi_free_string',
      ).asFunction<void Function(Pointer<Utf8>)>();

  late final _mnemonicFromEntropy =
      _symbol<NativeFunction<Pointer<Utf8> Function(Pointer<Utf8>)>>(
        'zcash_ffi_mnemonic_from_entropy',
      ).asFunction<Pointer<Utf8> Function(Pointer<Utf8>)>();

  late final _mnemonicToSeed =
      _symbol<
            NativeFunction<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>
          >('zcash_ffi_mnemonic_to_seed')
          .asFunction<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>();

  late final _seedToAccountUfvk =
      _symbol<
            NativeFunction<
              Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint32)
            >
          >('zcash_ffi_seed_to_account_ufvk')
          .asFunction<
            Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, int)
          >();

  late final _seedToAccountMetadata =
      _symbol<
            NativeFunction<
              Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint32)
            >
          >('zcash_ffi_seed_to_account_metadata')
          .asFunction<
            Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, int)
          >();

  late final _seedToViewingKeys =
      _symbol<
            NativeFunction<
              Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint32)
            >
          >('zcash_ffi_seed_to_viewing_keys')
          .asFunction<
            Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, int)
          >();

  late final _validateKey =
      _symbol<
            NativeFunction<
              Pointer<Utf8> Function(
                Pointer<Utf8>,
                Pointer<Utf8>,
                Pointer<Utf8>,
              )
            >
          >('zcash_ffi_validate_key')
          .asFunction<
            Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>)
          >();

  late final _seedToSaplingSpendingKey = _lookupSeedToSaplingSpendingKey();

  Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, int)
  _lookupSeedToSaplingSpendingKey() {
    const symbol = 'zcash_ffi_seed_to_sapling_spending_key';
    try {
      return _symbol<
            NativeFunction<
              Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint32)
            >
          >(symbol)
          .asFunction<
            Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, int)
          >();
    } on ArgumentError catch (e) {
      throw StateError(
        'zcash-ffi missing native symbol $symbol in $_libraryPath: $e',
      );
    }
  }

  late final _seedToTransparentXpub =
      _symbol<
            NativeFunction<
              Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint32)
            >
          >('zcash_ffi_seed_to_transparent_xpub')
          .asFunction<
            Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, int)
          >();

  late final _ufvkToAddress =
      _symbol<
            NativeFunction<
              Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint32)
            >
          >('zcash_ffi_ufvk_to_address')
          .asFunction<
            Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, int)
          >();

  late final _transparentAddress =
      _symbol<
            NativeFunction<
              Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint32)
            >
          >('zcash_ffi_transparent_address')
          .asFunction<
            Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, int)
          >();

  late final _decodeAddress =
      _symbol<
            NativeFunction<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>
          >('zcash_ffi_decode_address')
          .asFunction<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>();

  late final _unifiedAddressReceivers =
      _symbol<
            NativeFunction<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>
          >('zcash_ffi_unified_address_receivers')
          .asFunction<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>();

  late final _decodeTransaction =
      _symbol<
            NativeFunction<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>
          >('zcash_ffi_decode_transaction')
          .asFunction<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>();

  late final _transactionTxid =
      _symbol<NativeFunction<Pointer<Utf8> Function(Pointer<Utf8>)>>(
        'zcash_ffi_transaction_txid',
      ).asFunction<Pointer<Utf8> Function(Pointer<Utf8>)>();

  late final _buildTransparentTransaction =
      _symbol<NativeFunction<Pointer<Utf8> Function(Pointer<Utf8>)>>(
        'zcash_ffi_build_transparent_transaction',
      ).asFunction<Pointer<Utf8> Function(Pointer<Utf8>)>();

  late final _classifyTransparentAddress =
      _symbol<
            NativeFunction<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>
          >('zcash_ffi_classify_transparent_address')
          .asFunction<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>();

  late final _classifyTransparentScript =
      _symbol<NativeFunction<Pointer<Utf8> Function(Pointer<Utf8>)>>(
        'zcash_ffi_classify_transparent_script',
      ).asFunction<Pointer<Utf8> Function(Pointer<Utf8>)>();

  late final _addressType =
      _symbol<NativeFunction<Int32 Function(Pointer<Utf8>)>>(
        'zcash_ffi_address_type',
      ).asFunction<int Function(Pointer<Utf8>)>();

  late final _isTransparentAddress =
      _symbol<NativeFunction<Bool Function(Pointer<Utf8>)>>(
        'zcash_ffi_is_transparent_address',
      ).asFunction<bool Function(Pointer<Utf8>)>();

  late final _isShieldedAddress =
      _symbol<NativeFunction<Bool Function(Pointer<Utf8>)>>(
        'zcash_ffi_is_shielded_address',
      ).asFunction<bool Function(Pointer<Utf8>)>();

  late final _solveEquihash =
      _symbol<NativeFunction<Pointer<Utf8> Function(Pointer<Uint8>, IntPtr)>>(
        'zcash_ffi_solve_equihash',
      ).asFunction<Pointer<Utf8> Function(Pointer<Uint8>, int)>();

  late final _scanCompactBlocks = _lookupScanCompactBlocks();

  Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>)
  _lookupScanCompactBlocks() {
    const symbol = 'zcash_ffi_scan_compact_blocks';
    try {
      return _symbol<
            NativeFunction<
              Pointer<Utf8> Function(
                Pointer<Utf8>,
                Pointer<Utf8>,
                Pointer<Utf8>,
              )
            >
          >(symbol)
          .asFunction<
            Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>)
          >();
    } on ArgumentError catch (e) {
      throw StateError(
        'zcash-ffi missing native symbol $symbol in $_libraryPath: $e',
      );
    }
  }

  String version() {
    final ptr = _version();
    return _takeString(ptr);
  }

  String networkConstantsRaw(String network) {
    final netPtr = network.toNativeUtf8();
    try {
      return _takeString(_networkConstants(netPtr));
    } finally {
      calloc.free(netPtr);
    }
  }

  void freeString(Pointer<Utf8> ptr) => _freeString(ptr);

  String seedToAccountUfvk(String seedHex, String network, int account) {
    final seedPtr = seedHex.toNativeUtf8();
    final netPtr = network.toNativeUtf8();
    try {
      return _takeString(_seedToAccountUfvk(seedPtr, netPtr, account));
    } finally {
      calloc.free(seedPtr);
      calloc.free(netPtr);
    }
  }

  String mnemonicFromEntropyRaw(String entropyHex) {
    final entropyPtr = entropyHex.toNativeUtf8();
    try {
      return _takeString(_mnemonicFromEntropy(entropyPtr));
    } finally {
      calloc.free(entropyPtr);
    }
  }

  String mnemonicToSeedRaw(String phrase, String passphrase) {
    final phrasePtr = phrase.toNativeUtf8();
    final passphrasePtr = passphrase.toNativeUtf8();
    try {
      return _takeString(_mnemonicToSeed(phrasePtr, passphrasePtr));
    } finally {
      calloc.free(phrasePtr);
      calloc.free(passphrasePtr);
    }
  }

  String seedToAccountMetadata(String seedHex, String network, int account) {
    final seedPtr = seedHex.toNativeUtf8();
    final netPtr = network.toNativeUtf8();
    try {
      return _takeString(_seedToAccountMetadata(seedPtr, netPtr, account));
    } finally {
      calloc.free(seedPtr);
      calloc.free(netPtr);
    }
  }

  String seedToViewingKeys(String seedHex, String network, int account) {
    final seedPtr = seedHex.toNativeUtf8();
    final netPtr = network.toNativeUtf8();
    try {
      return _takeString(_seedToViewingKeys(seedPtr, netPtr, account));
    } finally {
      calloc.free(seedPtr);
      calloc.free(netPtr);
    }
  }

  String validateKey(String key, String network, String keyType) {
    final keyPtr = key.toNativeUtf8();
    final netPtr = network.toNativeUtf8();
    final keyTypePtr = keyType.toNativeUtf8();
    try {
      return _takeString(_validateKey(keyPtr, netPtr, keyTypePtr));
    } finally {
      calloc.free(keyPtr);
      calloc.free(netPtr);
      calloc.free(keyTypePtr);
    }
  }

  String seedToSaplingSpendingKey(String seedHex, String network, int account) {
    final seedPtr = seedHex.toNativeUtf8();
    final netPtr = network.toNativeUtf8();
    try {
      return _takeString(_seedToSaplingSpendingKey(seedPtr, netPtr, account));
    } finally {
      calloc.free(seedPtr);
      calloc.free(netPtr);
    }
  }

  String seedToTransparentXpub(String seedHex, String network, int account) {
    final seedPtr = seedHex.toNativeUtf8();
    final netPtr = network.toNativeUtf8();
    try {
      return _takeString(_seedToTransparentXpub(seedPtr, netPtr, account));
    } finally {
      calloc.free(seedPtr);
      calloc.free(netPtr);
    }
  }

  String ufvkToAddress(String ufvk, String network, int diversifierIndex) {
    final ufvkPtr = ufvk.toNativeUtf8();
    final netPtr = network.toNativeUtf8();
    try {
      return _takeString(_ufvkToAddress(ufvkPtr, netPtr, diversifierIndex));
    } finally {
      calloc.free(ufvkPtr);
      calloc.free(netPtr);
    }
  }

  String transparentAddress(String xpub, String network, int childIndex) {
    final xpubPtr = xpub.toNativeUtf8();
    final netPtr = network.toNativeUtf8();
    try {
      return _takeString(_transparentAddress(xpubPtr, netPtr, childIndex));
    } finally {
      calloc.free(xpubPtr);
      calloc.free(netPtr);
    }
  }

  String decodeAddress(String addr, String network) {
    final addrPtr = addr.toNativeUtf8();
    final netPtr = network.toNativeUtf8();
    try {
      return _takeString(_decodeAddress(addrPtr, netPtr));
    } finally {
      calloc.free(addrPtr);
      calloc.free(netPtr);
    }
  }

  String decodeTransaction(String txHex, String network) {
    final txPtr = txHex.toNativeUtf8();
    final netPtr = network.toNativeUtf8();
    try {
      return _takeString(_decodeTransaction(txPtr, netPtr));
    } finally {
      calloc.free(txPtr);
      calloc.free(netPtr);
    }
  }

  String transactionTxid(String txHex) {
    final txPtr = txHex.toNativeUtf8();
    try {
      return _takeString(_transactionTxid(txPtr));
    } finally {
      calloc.free(txPtr);
    }
  }

  String buildTransparentTransaction(String requestJson) {
    final requestPtr = requestJson.toNativeUtf8();
    try {
      return _takeString(_buildTransparentTransaction(requestPtr));
    } finally {
      calloc.free(requestPtr);
    }
  }

  String unifiedAddressReceivers(String addr, String network) {
    final addrPtr = addr.toNativeUtf8();
    final netPtr = network.toNativeUtf8();
    try {
      return _takeString(_unifiedAddressReceivers(addrPtr, netPtr));
    } finally {
      calloc.free(addrPtr);
      calloc.free(netPtr);
    }
  }

  String classifyTransparentAddress(String addr, String network) {
    final addrPtr = addr.toNativeUtf8();
    final netPtr = network.toNativeUtf8();
    try {
      return _takeString(_classifyTransparentAddress(addrPtr, netPtr));
    } finally {
      calloc.free(addrPtr);
      calloc.free(netPtr);
    }
  }

  String classifyTransparentScript(String scriptHex) {
    final scriptPtr = scriptHex.toNativeUtf8();
    try {
      return _takeString(_classifyTransparentScript(scriptPtr));
    } finally {
      calloc.free(scriptPtr);
    }
  }

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

  String solveEquihash(List<int> headerPrefix) {
    final len = headerPrefix.length;
    final ptr = calloc<Uint8>(len);
    try {
      ptr.asTypedList(len).setAll(0, headerPrefix);
      return _takeString(_solveEquihash(ptr, len));
    } finally {
      calloc.free(ptr);
    }
  }

  String scanCompactBlocksRaw(String ufvk, String network, String blocksJson) {
    final ufvkPtr = ufvk.toNativeUtf8();
    final netPtr = network.toNativeUtf8();
    final blocksPtr = blocksJson.toNativeUtf8();
    try {
      return _takeString(_scanCompactBlocks(ufvkPtr, netPtr, blocksPtr));
    } finally {
      calloc.free(ufvkPtr);
      calloc.free(netPtr);
      calloc.free(blocksPtr);
    }
  }

  String _takeString(Pointer<Utf8> ptr) {
    return takeNativeString(
      ptr,
      free: freeString,
      context: 'zcash-ffi/DynamicLibrary',
    );
  }

  static ZcashFfiBindings? _instance;

  static ZcashFfiBindings get instance {
    return _instance ??= resolve(Platform.environment);
  }

  static ZcashFfiBindings resolve(Map<String, String> environment) {
    final envPath = environment['ZCASH_FFI_LIB'];
    if (envPath != null && envPath.isNotEmpty) {
      return ZcashFfiBindings.open(envPath);
    }

    try {
      final bindings = ZcashFfiBindings.nativeAssets();
      bindings.version();
      return bindings;
    } on ArgumentError {
      // No search path to fall back on there; the asset load error is the
      // only useful one.
      if (Platform.isAndroid || Platform.isIOS) rethrow;
    }

    if (Platform.isLinux) return ZcashFfiBindings.open('libzcash_ffi.so');
    if (Platform.isMacOS) return ZcashFfiBindings.open('libzcash_ffi.dylib');
    if (Platform.isWindows) return ZcashFfiBindings.open('zcash_ffi.dll');
    throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
  }
}

ZcashScanResult scanCompactBlocks({
  required String ufvk,
  required String network,
  required Iterable<CompactBlockScanInput> blocks,
  CompactBlockScanRange? range,
  ZcashFfiBindings? bindings,
  bool allowExperimentalOrchardNotes = false,
  bool includeSaplingWitnesses = false,
  String? priorSaplingFrontier,
  bool includeOrchardWitnesses = false,
  String? priorOrchardFrontier,
  String? priorIronwoodFrontier,
  ZcashWatchedNullifiers? watchedNullifiers,
}) {
  final ffi = bindings ?? ZcashFfiBindings.instance;
  final raw = ffi.scanCompactBlocksRaw(
    ufvk,
    network,
    encodeVersionedCompactBlocksForScan(
      blocks: blocks,
      network: network,
      range: range,
      includeSaplingWitnesses: includeSaplingWitnesses,
      priorSaplingFrontier: priorSaplingFrontier,
      includeOrchardWitnesses: includeOrchardWitnesses,
      priorOrchardFrontier: priorOrchardFrontier,
      priorIronwoodFrontier: priorIronwoodFrontier,
      watchedNullifiers: watchedNullifiers,
    ),
  );
  final json = parseNativeJsonObject(
    raw,
    context: 'scan_compact_blocks/DynamicLibrary',
    redactSensitive: [ufvk],
  );
  return ZcashScanResult.fromJson(
    json,
    context: 'scan_compact_blocks/DynamicLibrary',
    redactSensitive: [ufvk],
    allowExperimentalOrchardNotes: allowExperimentalOrchardNotes,
  );
}
