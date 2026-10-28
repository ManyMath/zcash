import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:zcash/zcash.dart';

import 'ironwood_build_request.dart';
import 'native_result.dart';
import 'native_string.dart';
import 'orchard_build_request.dart';
import 'sapling_build_request.dart';
import 'transparent_build_request.dart';

@Native<Pointer<Utf8> Function()>(symbol: 'zcash_ffi_version')
external Pointer<Utf8> _zcashFfiVersion();

@Native<Pointer<Utf8> Function()>(symbol: 'zcash_ffi_capabilities')
external Pointer<Utf8> _zcashFfiCapabilities();

@Native<Void Function(Pointer<Utf8>)>(symbol: 'zcash_ffi_free_string')
external void _zcashFfiFreeString(Pointer<Utf8> ptr);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint32)>(
  symbol: 'zcash_ffi_seed_to_account_ufvk',
)
external Pointer<Utf8> _zcashFfiSeedToAccountUfvk(
  Pointer<Utf8> seedHex,
  Pointer<Utf8> network,
  int accountIndex,
);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint32)>(
  symbol: 'zcash_ffi_seed_to_account_metadata',
)
external Pointer<Utf8> _zcashFfiSeedToAccountMetadata(
  Pointer<Utf8> seedHex,
  Pointer<Utf8> network,
  int accountIndex,
);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint32)>(
  symbol: 'zcash_ffi_seed_to_viewing_keys',
)
external Pointer<Utf8> _zcashFfiSeedToViewingKeys(
  Pointer<Utf8> seedHex,
  Pointer<Utf8> network,
  int accountIndex,
);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>)>(
  symbol: 'zcash_ffi_validate_key',
)
external Pointer<Utf8> _zcashFfiValidateKey(
  Pointer<Utf8> key,
  Pointer<Utf8> network,
  Pointer<Utf8> keyType,
);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint32)>(
  symbol: 'zcash_ffi_seed_to_sapling_spending_key',
)
external Pointer<Utf8> _zcashFfiSeedToSaplingSpendingKey(
  Pointer<Utf8> seedHex,
  Pointer<Utf8> network,
  int accountIndex,
);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint32)>(
  symbol: 'zcash_ffi_seed_to_transparent_xpub',
)
external Pointer<Utf8> _zcashFfiSeedToTransparentXpub(
  Pointer<Utf8> seedHex,
  Pointer<Utf8> network,
  int accountIndex,
);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint32)>(
  symbol: 'zcash_ffi_ufvk_to_address',
)
external Pointer<Utf8> _zcashFfiUfvkToAddress(
  Pointer<Utf8> ufvk,
  Pointer<Utf8> network,
  int diversifierIndex,
);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint32)>(
  symbol: 'zcash_ffi_transparent_address',
)
external Pointer<Utf8> _zcashFfiTransparentAddress(
  Pointer<Utf8> xpub,
  Pointer<Utf8> network,
  int childIndex,
);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>(
  symbol: 'zcash_ffi_decode_address',
)
external Pointer<Utf8> _zcashFfiDecodeAddress(
  Pointer<Utf8> address,
  Pointer<Utf8> network,
);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>(
  symbol: 'zcash_ffi_decode_transaction',
)
external Pointer<Utf8> _zcashFfiDecodeTransaction(
  Pointer<Utf8> txHex,
  Pointer<Utf8> network,
);

@Native<Pointer<Utf8> Function(Pointer<Utf8>)>(
  symbol: 'zcash_ffi_transaction_txid',
)
external Pointer<Utf8> _zcashFfiTransactionTxid(Pointer<Utf8> txHex);

@Native<Pointer<Utf8> Function(Pointer<Utf8>)>(
  symbol: 'zcash_ffi_build_transparent_transaction',
)
external Pointer<Utf8> _zcashFfiBuildTransparentTransaction(
  Pointer<Utf8> requestJson,
);

@Native<Pointer<Utf8> Function(Pointer<Utf8>)>(
  symbol: 'zcash_ffi_build_sapling_transaction',
)
external Pointer<Utf8> _zcashFfiBuildSaplingTransaction(
  Pointer<Utf8> requestJson,
);

@Native<Pointer<Utf8> Function(Pointer<Utf8>)>(
  symbol: 'zcash_ffi_build_orchard_transaction',
)
external Pointer<Utf8> _zcashFfiBuildOrchardTransaction(
  Pointer<Utf8> requestJson,
);

@Native<Pointer<Utf8> Function(Pointer<Utf8>)>(
  symbol: 'zcash_ffi_build_ironwood_transaction',
)
external Pointer<Utf8> _zcashFfiBuildIronwoodTransaction(
  Pointer<Utf8> requestJson,
);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>)>(
  symbol: 'zcash_ffi_scan_compact_blocks',
)
external Pointer<Utf8> _zcashFfiScanCompactBlocks(
  Pointer<Utf8> ufvk,
  Pointer<Utf8> network,
  Pointer<Utf8> blocksJson,
);

class ZcashNativeAddressSet {
  const ZcashNativeAddressSet({
    required this.ua,
    required this.sapling,
    required this.orchard,
    required this.transparent,
    this.addressEncoding,
  });

  final String ua;
  final String? sapling;
  final String? orchard;
  final String? transparent;

  final String? addressEncoding;
}

String zcashNativeVersion() => _takeString(_zcashFfiVersion());

NativeCapabilitySnapshot zcashNativeCapabilities() {
  final raw = _takeString(_zcashFfiCapabilities());
  final json = parseNativeJsonObject(raw, context: 'native_capabilities');
  return NativeCapabilitySnapshot.fromJson(json);
}

String zcashNativeSeedToAccountUfvk({
  required String seedHex,
  required String network,
  int accountIndex = 0,
}) {
  final raw = _callSeedNetworkAccount(
    seedHex: seedHex,
    network: network,
    index: accountIndex,
    call: _zcashFfiSeedToAccountUfvk,
  );
  return requiredNativeString(
    raw,
    'ufvk',
    context: 'seed_to_account_ufvk',
    redactSensitive: [seedHex],
  );
}

ZcashAccountMetadata zcashNativeSeedToAccountMetadata({
  required String seedHex,
  required String network,
  int accountIndex = 0,
}) {
  final raw = _callSeedNetworkAccount(
    seedHex: seedHex,
    network: network,
    index: accountIndex,
    call: _zcashFfiSeedToAccountMetadata,
  );
  final json = parseNativeJsonObject(
    raw,
    context: 'seed_to_account_metadata',
    redactSensitive: [seedHex],
  );
  return ZcashAccountMetadata.fromJson(json);
}

ZcashViewingKeys zcashNativeSeedToViewingKeys({
  required String seedHex,
  required String network,
  int accountIndex = 0,
}) {
  final raw = _callSeedNetworkAccount(
    seedHex: seedHex,
    network: network,
    index: accountIndex,
    call: _zcashFfiSeedToViewingKeys,
  );
  final json = parseNativeJsonObject(
    raw,
    context: 'seed_to_viewing_keys',
    redactSensitive: [seedHex],
  );
  return ZcashViewingKeys.fromJson(json);
}

ZcashKeyValidation zcashNativeValidateKey({
  required String key,
  required String network,
  required ZcashKeyType keyType,
}) {
  final keyPtr = key.toNativeUtf8();
  final networkPtr = network.toNativeUtf8();
  final keyTypePtr = keyType.label.toNativeUtf8();
  final String raw;
  try {
    raw = _takeString(_zcashFfiValidateKey(keyPtr, networkPtr, keyTypePtr));
  } finally {
    calloc.free(keyPtr);
    calloc.free(networkPtr);
    calloc.free(keyTypePtr);
  }
  final json = parseNativeJsonObject(
    raw,
    context: 'validate_key',
    redactSensitive: [key],
  );
  return ZcashKeyValidation.fromJson(json);
}

String zcashNativeSeedToSaplingSpendingKey({
  required String seedHex,
  required String network,
  int accountIndex = 0,
}) {
  final raw = _callSeedNetworkAccount(
    seedHex: seedHex,
    network: network,
    index: accountIndex,
    call: _zcashFfiSeedToSaplingSpendingKey,
  );
  return requiredNativeString(
    raw,
    'sapling_spending_key',
    context: 'seed_to_sapling_spending_key',
    redactSensitive: [seedHex],
  );
}

String zcashNativeSeedToTransparentXpub({
  required String seedHex,
  required String network,
  int accountIndex = 0,
}) {
  final raw = _callSeedNetworkAccount(
    seedHex: seedHex,
    network: network,
    index: accountIndex,
    call: _zcashFfiSeedToTransparentXpub,
  );
  return requiredNativeString(
    raw,
    'xpub',
    context: 'seed_to_transparent_xpub',
    redactSensitive: [seedHex],
  );
}

ZcashNativeAddressSet zcashNativeUfvkToAddress({
  required String ufvk,
  required String network,
  int diversifierIndex = 0,
}) {
  _checkUint32Index(diversifierIndex, 'diversifierIndex');
  final raw = _callStringNetworkIndex(
    value: ufvk,
    network: network,
    index: diversifierIndex,
    call: _zcashFfiUfvkToAddress,
  );
  final json = parseNativeJsonObject(
    raw,
    context: 'ufvk_to_address',
    redactSensitive: [ufvk],
  );
  final addressJson = json['addresses'] is Map
      ? (json['addresses'] as Map).cast<String, dynamic>()
      : json;
  return ZcashNativeAddressSet(
    ua: requiredNativeStringFromObject(
      addressJson,
      'ua',
      context: 'ufvk_to_address',
    ),
    sapling: optionalNativeStringFromObject(
      addressJson,
      'sapling',
      context: 'ufvk_to_address',
    ),
    orchard: optionalNativeStringFromObject(
      addressJson,
      'orchard',
      context: 'ufvk_to_address',
    ),
    transparent: optionalNativeStringFromObject(
      addressJson,
      'transparent',
      context: 'ufvk_to_address',
    ),
    addressEncoding: optionalNativeStringFromObject(
      json,
      'address_encoding',
      context: 'ufvk_to_address',
    ),
  );
}

ZcashDiversifierSearchResult zcashNativeUfvkToDiversifierSearch({
  required String ufvk,
  required String network,
  int diversifierIndex = 0,
}) {
  _checkUint32Index(diversifierIndex, 'diversifierIndex');
  final raw = _callStringNetworkIndex(
    value: ufvk,
    network: network,
    index: diversifierIndex,
    call: _zcashFfiUfvkToAddress,
  );
  final json = parseNativeJsonObject(
    raw,
    context: 'ufvk_to_address',
    redactSensitive: [ufvk],
  );
  return ZcashDiversifierSearchResult.fromJson(json);
}

String zcashNativeTransparentAddress({
  required String xpub,
  required String network,
  int childIndex = 0,
}) {
  final raw = _callStringNetworkIndex(
    value: xpub,
    network: network,
    index: childIndex,
    call: _zcashFfiTransparentAddress,
  );
  return requiredNativeString(
    raw,
    'address',
    context: 'transparent_address',
    redactSensitive: [xpub],
  );
}

ZcashAddressMetadata zcashNativeDecodeAddress({
  required String address,
  required String network,
}) {
  final raw = _callStringNetwork(
    value: address,
    network: network,
    call: _zcashFfiDecodeAddress,
  );
  final json = parseNativeJsonObject(
    raw,
    context: 'decode_address/native-assets',
    redactSensitive: [address],
  );
  return ZcashAddressMetadata.fromJson(json);
}

ZcashTransactionSummary zcashNativeDecodeTransaction({
  required String txHex,
  required String network,
}) {
  final raw = _callStringNetwork(
    value: txHex,
    network: network,
    call: _zcashFfiDecodeTransaction,
  );
  final json = parseNativeJsonObject(
    raw,
    context: 'decode_transaction/native-assets',
    redactSensitive: [txHex],
  );
  return ZcashTransactionSummary.fromJson(json);
}

/// The txid in display order and, from v5, the ZIP 244 auth digest.
ZcashTransactionId zcashNativeTransactionTxid({required String txHex}) {
  final txPtr = txHex.toNativeUtf8();
  final String raw;
  try {
    raw = _takeString(_zcashFfiTransactionTxid(txPtr));
  } finally {
    calloc.free(txPtr);
  }
  final json = parseNativeJsonObject(
    raw,
    context: 'transaction_txid/native-assets',
    redactSensitive: [txHex],
  );
  return ZcashTransactionId.fromJson(json);
}

TransparentBuildResult zcashNativeBuildTransparentTransaction({
  required String network,
  required int targetHeight,
  required int feeZatoshis,
  required Iterable<TransparentBuildInput> inputs,
  required Iterable<TransparentBuildOutput> outputs,
  bool allowExperimentalTransparentBuild = false,
}) {
  if (!allowExperimentalTransparentBuild) {
    throw StateError(
      'zcashNativeBuildTransparentTransaction is experimental and native-backed; '
      'set allowExperimentalTransparentBuild: true to opt in. It requires a '
      'native library built with the off-by-default transparent-tx-build feature.',
    );
  }
  final requestJson = encodeTransparentBuildRequest(
    network: network,
    targetHeight: targetHeight,
    feeZatoshis: feeZatoshis,
    inputs: inputs,
    outputs: outputs,
  );
  final requestPtr = requestJson.toNativeUtf8();
  final String raw;
  try {
    raw = _takeString(_zcashFfiBuildTransparentTransaction(requestPtr));
  } finally {
    calloc.free(requestPtr);
  }
  final json = parseNativeJsonObject(
    raw,
    context: 'build_transparent_transaction/native-assets',
    redactSensitive: [for (final input in inputs) input.secretKeyHex],
  );
  return TransparentBuildResult.fromJson(json);
}

SaplingBuildResult zcashNativeBuildSaplingTransaction({
  required String network,
  required int targetHeight,
  int? feeZatoshis,
  required String seedHex,
  int account = 0,
  Iterable<SaplingBuildSpendNote> spendNotes = const [],
  Iterable<TransparentBuildInput> inputs = const [],
  required Iterable<SaplingBuildOutput> outputs,
  String? spendParamsPath,
  String? outputParamsPath,
  int? regtestNu63ActivationHeight,
  String? rngSeedHex,
  bool allowExperimentalSaplingBuild = false,
}) {
  if (!allowExperimentalSaplingBuild) {
    throw StateError(
      'zcashNativeBuildSaplingTransaction is experimental and native-backed; '
      'set allowExperimentalSaplingBuild: true to opt in. It requires a native '
      'library built with the off-by-default sapling-spend-build feature, and '
      'without caller-supplied MPC parameters produces placeholder '
      '(non-consensus-valid) proofs.',
    );
  }
  final requestJson = encodeSaplingBuildRequest(
    network: network,
    targetHeight: targetHeight,
    feeZatoshis: feeZatoshis,
    seedHex: seedHex,
    account: account,
    spendNotes: spendNotes,
    inputs: inputs,
    outputs: outputs,
    spendParamsPath: spendParamsPath,
    outputParamsPath: outputParamsPath,
    regtestNu63ActivationHeight: regtestNu63ActivationHeight,
    rngSeedHex: rngSeedHex,
  );
  final requestPtr = requestJson.toNativeUtf8();
  final String raw;
  try {
    raw = _takeString(_zcashFfiBuildSaplingTransaction(requestPtr));
  } finally {
    calloc.free(requestPtr);
  }
  final json = parseNativeJsonObject(
    raw,
    context: 'build_sapling_transaction/native-assets',
    redactSensitive: [seedHex, for (final input in inputs) input.secretKeyHex],
  );
  return SaplingBuildResult.fromJson(json);
}

// A recipient address may carry a ZIP 316 expiry time; the native
// builders have no clock, so they are handed this one.
int _unixSeconds(DateTime? now) =>
    (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;

OrchardBuildResult zcashNativeBuildOrchardTransaction({
  required String network,
  required int targetHeight,
  required OrchardAnchorSource anchor,
  required Iterable<TransparentBuildInput> inputs,
  required OrchardBuildOutput orchardOutput,
  Iterable<TransparentBuildOutput> outputs = const [],
  int? expiryHeight,
  int? regtestNu63ActivationHeight,
  int? feeZatoshis,
  String? rngSeedHex,
  DateTime? now,
  bool allowExperimentalOrchardBuild = false,
}) {
  if (!allowExperimentalOrchardBuild) {
    throw StateError(
      'zcashNativeBuildOrchardTransaction is experimental and native-backed; '
      'set allowExperimentalOrchardBuild: true to opt in. It requires a native '
      'library built with the off-by-default orchard-tx-build feature, it only '
      'works below the NU6.3 activation height, and the caller remains '
      'responsible for supplying a real Orchard anchor.',
    );
  }
  final requestJson = encodeOrchardBuildRequest(
    network: network,
    targetHeight: targetHeight,
    anchor: anchor,
    inputs: inputs,
    orchardOutput: orchardOutput,
    outputs: outputs,
    expiryHeight: expiryHeight,
    regtestNu63ActivationHeight: regtestNu63ActivationHeight,
    currentUnixTime: _unixSeconds(now),
    feeZatoshis: feeZatoshis,
    rngSeedHex: rngSeedHex,
  );
  final requestPtr = requestJson.toNativeUtf8();
  final String raw;
  try {
    raw = _takeString(_zcashFfiBuildOrchardTransaction(requestPtr));
  } finally {
    calloc.free(requestPtr);
  }
  final json = parseNativeJsonObject(
    raw,
    context: 'build_orchard_transaction/native-assets',
    redactSensitive: [
      for (final input in inputs) input.secretKeyHex,
      if (orchardOutput.outgoingViewingKeyHex != null)
        orchardOutput.outgoingViewingKeyHex!,
    ],
  );
  return OrchardBuildResult.fromJson(json);
}

IronwoodBuildResult zcashNativeBuildIronwoodTransaction({
  required String network,
  required int targetHeight,
  required IronwoodAnchorSource anchor,
  required Iterable<TransparentBuildInput> inputs,
  required IronwoodBuildOutput ironwoodOutput,
  Iterable<TransparentBuildOutput> outputs = const [],
  Iterable<IronwoodBuildSpendNote> saplingSpends = const [],
  Iterable<IronwoodBuildOrchardSpendNote> orchardSpends = const [],
  int? orchardChangeZatoshis,
  int? expiryHeight,
  int? regtestNu63ActivationHeight,
  String? seedHex,
  int account = 0,
  String? spendParamsPath,
  String? outputParamsPath,
  int? feeZatoshis,
  String? rngSeedHex,
  DateTime? now,
  bool allowExperimentalIronwoodBuild = false,
}) {
  if (!allowExperimentalIronwoodBuild) {
    throw StateError(
      'zcashNativeBuildIronwoodTransaction is experimental and native-backed; '
      'set allowExperimentalIronwoodBuild: true to opt in. It requires a native '
      'library built with the off-by-default ironwood-tx-build feature, and the '
      'caller remains responsible for supplying a real Ironwood anchor.',
    );
  }
  final requestJson = encodeIronwoodBuildRequest(
    network: network,
    targetHeight: targetHeight,
    anchor: anchor,
    inputs: inputs,
    ironwoodOutput: ironwoodOutput,
    outputs: outputs,
    saplingSpends: saplingSpends,
    orchardSpends: orchardSpends,
    orchardChangeZatoshis: orchardChangeZatoshis,
    expiryHeight: expiryHeight,
    regtestNu63ActivationHeight: regtestNu63ActivationHeight,
    currentUnixTime: _unixSeconds(now),
    seedHex: seedHex,
    account: account,
    spendParamsPath: spendParamsPath,
    outputParamsPath: outputParamsPath,
    feeZatoshis: feeZatoshis,
    rngSeedHex: rngSeedHex,
  );
  final requestPtr = requestJson.toNativeUtf8();
  final String raw;
  try {
    raw = _takeString(_zcashFfiBuildIronwoodTransaction(requestPtr));
  } finally {
    calloc.free(requestPtr);
  }
  final json = parseNativeJsonObject(
    raw,
    context: 'build_ironwood_transaction/native-assets',
    redactSensitive: [
      for (final input in inputs) input.secretKeyHex,
      if (ironwoodOutput.outgoingViewingKeyHex != null)
        ironwoodOutput.outgoingViewingKeyHex!,
      ?seedHex,
    ],
  );
  return IronwoodBuildResult.fromJson(json);
}

ZcashScanResult zcashNativeScanCompactBlocks({
  required String ufvk,
  required String network,
  required Iterable<CompactBlockScanInput> blocks,
  CompactBlockScanRange? range,
  bool allowExperimentalOrchardNotes = false,
  bool includeSaplingWitnesses = false,
  String? priorSaplingFrontier,
  bool includeOrchardWitnesses = false,
  String? priorOrchardFrontier,
  String? priorIronwoodFrontier,
  ZcashWatchedNullifiers? watchedNullifiers,
}) {
  final raw = _callScanCompactBlocks(
    ufvk: ufvk,
    network: network,
    blocksJson: encodeVersionedCompactBlocksForScan(
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
    context: 'scan_compact_blocks/native-assets',
    redactSensitive: [ufvk],
  );
  return ZcashScanResult.fromJson(
    json,
    context: 'scan_compact_blocks/native-assets',
    redactSensitive: [ufvk],
    allowExperimentalOrchardNotes: allowExperimentalOrchardNotes,
  );
}

typedef _NativeStringNetworkIndex =
    Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, int);

typedef _NativeStringNetwork =
    Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);

String _callSeedNetworkAccount({
  required String seedHex,
  required String network,
  required int index,
  required _NativeStringNetworkIndex call,
}) => _callStringNetworkIndex(
  value: seedHex,
  network: network,
  index: index,
  call: call,
);

String _callStringNetworkIndex({
  required String value,
  required String network,
  required int index,
  required _NativeStringNetworkIndex call,
}) {
  final valuePtr = value.toNativeUtf8();
  final networkPtr = network.toNativeUtf8();
  try {
    return _takeString(call(valuePtr, networkPtr, index));
  } finally {
    calloc.free(valuePtr);
    calloc.free(networkPtr);
  }
}

String _callStringNetwork({
  required String value,
  required String network,
  required _NativeStringNetwork call,
}) {
  final valuePtr = value.toNativeUtf8();
  final networkPtr = network.toNativeUtf8();
  try {
    return _takeString(call(valuePtr, networkPtr));
  } finally {
    calloc.free(valuePtr);
    calloc.free(networkPtr);
  }
}

String _callScanCompactBlocks({
  required String ufvk,
  required String network,
  required String blocksJson,
}) {
  final ufvkPtr = ufvk.toNativeUtf8();
  final networkPtr = network.toNativeUtf8();
  final blocksPtr = blocksJson.toNativeUtf8();
  try {
    return _takeString(
      _zcashFfiScanCompactBlocks(ufvkPtr, networkPtr, blocksPtr),
    );
  } finally {
    calloc.free(ufvkPtr);
    calloc.free(networkPtr);
    calloc.free(blocksPtr);
  }
}

String _takeString(Pointer<Utf8> ptr) {
  return takeNativeString(
    ptr,
    free: _zcashFfiFreeString,
    context: 'zcash-ffi/native-assets',
  );
}

void _checkUint32Index(int value, String name) {
  if (value < 0 || value > 0xffffffff) {
    throw RangeError.range(value, 0, 0xffffffff, name);
  }
}
