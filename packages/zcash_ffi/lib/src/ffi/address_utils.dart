import 'dart:async';

import 'package:zcash/zcash.dart';

import 'compact_block_request.dart';
import 'ironwood_build_request.dart';
import 'native_result.dart';
import 'orchard_build_request.dart';
import 'sapling_build_request.dart';
import 'transparent_build_request.dart';
import 'zcash_ffi_bindings.dart';

enum ZcashNetwork {
  mainnet,
  testnet,
  regtest;

  String get ffiLabel => switch (this) {
    ZcashNetwork.mainnet => 'main',
    ZcashNetwork.testnet => 'test',
    ZcashNetwork.regtest => 'regtest',
  };

  String get _ffiParam => ffiLabel;
}

enum AddressType {
  unknown,
  transparent,
  sapling,
  unified;

  static AddressType fromInt(int v) => switch (v) {
    1 => transparent,
    2 => sapling,
    3 => unified,
    _ => unknown,
  };
}

class UnifiedAddressSet {
  final String ua;

  final String? saplingAddress;

  final String? orchardAddress;

  final String? transparentAddress;

  final String? addressEncoding;

  const UnifiedAddressSet({
    required this.ua,
    this.saplingAddress,
    this.orchardAddress,
    this.transparentAddress,
    this.addressEncoding,
  });

  @override
  String toString() =>
      'UnifiedAddressSet(ua: $ua, sapling: $saplingAddress, '
      'orchard: $orchardAddress, transparent: $transparentAddress, '
      'encoding: $addressEncoding)';
}

/// [seedHex] is the 64-byte BIP 39 seed in hex, not the phrase.
Future<UnifiedAddressSet> deriveAddress({
  required String seedHex,
  required ZcashNetwork network,
  int accountIndex = 0,
  int diversifierIndex = 0,
}) async {
  _checkUint32Index(diversifierIndex, 'diversifierIndex');
  final ffi = ZcashFfiBindings.instance;

  final ufvkJson = ffi.seedToAccountUfvk(
    seedHex,
    network._ffiParam,
    accountIndex,
  );
  final ufvk = requiredNativeString(
    ufvkJson,
    'ufvk',
    context: 'seed_to_account_ufvk/DynamicLibrary',
    redactSensitive: [seedHex],
  );

  final addrJson = ffi.ufvkToAddress(ufvk, network._ffiParam, diversifierIndex);
  final addrMap = parseNativeJsonObject(
    addrJson,
    context: 'ufvk_to_address/DynamicLibrary',
    redactSensitive: [ufvk],
  );
  final addressMap = addrMap['addresses'] is Map
      ? (addrMap['addresses'] as Map).cast<String, dynamic>()
      : addrMap;

  return UnifiedAddressSet(
    ua: requiredNativeStringFromObject(
      addressMap,
      'ua',
      context: 'ufvk_to_address/DynamicLibrary',
    ),
    saplingAddress: optionalNativeStringFromObject(
      addressMap,
      'sapling',
      context: 'ufvk_to_address/DynamicLibrary',
    ),
    orchardAddress: optionalNativeStringFromObject(
      addressMap,
      'orchard',
      context: 'ufvk_to_address/DynamicLibrary',
    ),
    transparentAddress: optionalNativeStringFromObject(
      addressMap,
      'transparent',
      context: 'ufvk_to_address/DynamicLibrary',
    ),
    addressEncoding: optionalNativeStringFromObject(
      addrMap,
      'address_encoding',
      context: 'ufvk_to_address/DynamicLibrary',
    ),
  );
}

ZcashDiversifierSearchResult deriveNativeDiversifierSearch({
  required String ufvk,
  required ZcashNetwork network,
  int diversifierIndex = 0,
  ZcashFfiBindings? bindings,
}) {
  _checkUint32Index(diversifierIndex, 'diversifierIndex');
  final ffi = bindings ?? ZcashFfiBindings.instance;
  final raw = ffi.ufvkToAddress(ufvk, network._ffiParam, diversifierIndex);
  final json = parseNativeJsonObject(
    raw,
    context: 'ufvk_to_address/DynamicLibrary',
    redactSensitive: [ufvk],
  );
  return ZcashDiversifierSearchResult.fromJson(json);
}

ZcashAccountMetadata deriveNativeAccountMetadata({
  required String seedHex,
  required ZcashNetwork network,
  int accountIndex = 0,
  ZcashFfiBindings? bindings,
}) {
  final ffi = bindings ?? ZcashFfiBindings.instance;
  final raw = ffi.seedToAccountMetadata(
    seedHex,
    network._ffiParam,
    accountIndex,
  );
  final json = parseNativeJsonObject(
    raw,
    context: 'seed_to_account_metadata/DynamicLibrary',
    redactSensitive: [seedHex],
  );
  return ZcashAccountMetadata.fromJson(json);
}

ZcashViewingKeys deriveNativeViewingKeys({
  required String seedHex,
  required ZcashNetwork network,
  int accountIndex = 0,
  ZcashFfiBindings? bindings,
}) {
  final ffi = bindings ?? ZcashFfiBindings.instance;
  final raw = ffi.seedToViewingKeys(seedHex, network._ffiParam, accountIndex);
  final json = parseNativeJsonObject(
    raw,
    context: 'seed_to_viewing_keys/DynamicLibrary',
    redactSensitive: [seedHex],
  );
  return ZcashViewingKeys.fromJson(json);
}

ZcashKeyValidation validateNativeKey({
  required String key,
  required ZcashKeyType keyType,
  required ZcashNetwork network,
  ZcashFfiBindings? bindings,
}) {
  final ffi = bindings ?? ZcashFfiBindings.instance;
  final raw = ffi.validateKey(key, network._ffiParam, keyType.label);
  final json = parseNativeJsonObject(
    raw,
    context: 'validate_key/DynamicLibrary',
    redactSensitive: [key],
  );
  return ZcashKeyValidation.fromJson(json);
}

Future<String> deriveSaplingSpendingKey({
  required String seedHex,
  required ZcashNetwork network,
  int accountIndex = 0,
}) async {
  final ffi = ZcashFfiBindings.instance;

  final keyJson = ffi.seedToSaplingSpendingKey(
    seedHex,
    network._ffiParam,
    accountIndex,
  );
  return requiredNativeString(
    keyJson,
    'sapling_spending_key',
    context: 'seed_to_sapling_spending_key/DynamicLibrary',
    redactSensitive: [seedHex],
  );
}

Future<String> deriveTransparentAddress({
  required String seedHex,
  required ZcashNetwork network,
  int accountIndex = 0,
  int childIndex = 0,
}) async {
  final ffi = ZcashFfiBindings.instance;

  final xpubJson = ffi.seedToTransparentXpub(
    seedHex,
    network._ffiParam,
    accountIndex,
  );
  final xpub = requiredNativeString(
    xpubJson,
    'xpub',
    context: 'seed_to_transparent_xpub/DynamicLibrary',
    redactSensitive: [seedHex],
  );

  final addrJson = ffi.transparentAddress(xpub, network._ffiParam, childIndex);
  return requiredNativeString(
    addrJson,
    'address',
    context: 'transparent_address/DynamicLibrary',
    redactSensitive: [xpub],
  );
}

bool isValidAddress(String addr, ZcashNetwork network) {
  try {
    decodeNativeAddress(address: addr, network: network);
    return true;
  } on StateError {
    return false;
  } on FormatException {
    return false;
  }
}

AddressType classifyAddress(String addr) {
  return AddressType.fromInt(ZcashFfiBindings.instance.addressType(addr));
}

ZcashAddressMetadata decodeNativeAddress({
  required String address,
  required ZcashNetwork network,
  ZcashFfiBindings? bindings,
}) {
  final ffi = bindings ?? ZcashFfiBindings.instance;
  final raw = ffi.decodeAddress(address, network._ffiParam);
  final json = parseNativeJsonObject(
    raw,
    context: 'decode_address/DynamicLibrary',
    redactSensitive: [address],
  );
  return ZcashAddressMetadata.fromJson(json);
}

ZcashUnifiedAddressReceiverInventory inventoryUnifiedAddressReceivers({
  required String address,
  required ZcashNetwork network,
  ZcashFfiBindings? bindings,
}) {
  final ffi = bindings ?? ZcashFfiBindings.instance;
  final raw = ffi.unifiedAddressReceivers(address, network._ffiParam);
  final json = parseNativeJsonObject(
    raw,
    context: 'unified_address_receivers/DynamicLibrary',
    redactSensitive: [address],
  );
  return ZcashUnifiedAddressReceiverInventory.fromJson(json);
}

ZcashTransparentClassification classifyNativeTransparentAddress({
  required String address,
  required ZcashNetwork network,
  ZcashFfiBindings? bindings,
}) {
  final ffi = bindings ?? ZcashFfiBindings.instance;
  final raw = ffi.classifyTransparentAddress(address, network._ffiParam);
  final json = parseNativeJsonObject(
    raw,
    context: 'classify_transparent_address/DynamicLibrary',
    redactSensitive: [address],
  );
  return ZcashTransparentClassification.fromJson(json);
}

ZcashTransparentClassification classifyNativeTransparentScript({
  required String scriptHex,
  ZcashFfiBindings? bindings,
}) {
  final ffi = bindings ?? ZcashFfiBindings.instance;
  final raw = ffi.classifyTransparentScript(scriptHex);
  final json = parseNativeJsonObject(
    raw,
    context: 'classify_transparent_script/DynamicLibrary',
    redactSensitive: [scriptHex],
  );
  return ZcashTransparentClassification.fromJson(json);
}

ZcashTransactionSummary decodeNativeTransaction({
  required String txHex,
  required ZcashNetwork network,
  ZcashFfiBindings? bindings,
}) {
  final ffi = bindings ?? ZcashFfiBindings.instance;
  final raw = ffi.decodeTransaction(txHex, network._ffiParam);
  final json = parseNativeJsonObject(
    raw,
    context: 'decode_transaction/DynamicLibrary',
    redactSensitive: [txHex],
  );
  return ZcashTransactionSummary.fromJson(json);
}

ZcashTransactionId transactionTxid({
  required String txHex,
  ZcashFfiBindings? bindings,
}) {
  final ffi = bindings ?? ZcashFfiBindings.instance;
  final raw = ffi.transactionTxid(txHex);
  final json = parseNativeJsonObject(
    raw,
    context: 'transaction_txid/DynamicLibrary',
    redactSensitive: [txHex],
  );
  return ZcashTransactionId.fromJson(json);
}

TransparentBuildResult buildNativeTransparentTransaction({
  required ZcashNetwork network,
  required int targetHeight,
  required int feeZatoshis,
  required Iterable<TransparentBuildInput> inputs,
  required Iterable<TransparentBuildOutput> outputs,
  bool allowExperimentalTransparentBuild = false,
  ZcashFfiBindings? bindings,
}) {
  if (!allowExperimentalTransparentBuild) {
    throw StateError(
      'buildNativeTransparentTransaction is experimental and native-backed; '
      'set allowExperimentalTransparentBuild: true to opt in. It requires a '
      'native library built with the off-by-default transparent-tx-build feature.',
    );
  }
  final ffi = bindings ?? ZcashFfiBindings.instance;
  final requestJson = encodeTransparentBuildRequest(
    network: network._ffiParam,
    targetHeight: targetHeight,
    feeZatoshis: feeZatoshis,
    inputs: inputs,
    outputs: outputs,
  );
  final raw = ffi.buildTransparentTransaction(requestJson);
  final json = parseNativeJsonObject(
    raw,
    context: 'build_transparent_transaction/DynamicLibrary',
    redactSensitive: [for (final input in inputs) input.secretKeyHex],
  );
  return TransparentBuildResult.fromJson(json);
}

SaplingBuildResult buildNativeSaplingTransaction({
  required ZcashNetwork network,
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
  ZcashFfiBindings? bindings,
}) {
  if (!allowExperimentalSaplingBuild) {
    throw StateError(
      'buildNativeSaplingTransaction is experimental and native-backed; set '
      'allowExperimentalSaplingBuild: true to opt in. It requires a native '
      'library built with the off-by-default sapling-spend-build feature, and '
      'even then produces placeholder (non-consensus-valid) proofs.',
    );
  }
  final ffi = bindings ?? ZcashFfiBindings.instance;
  final requestJson = encodeSaplingBuildRequest(
    network: network._ffiParam,
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
  final raw = ffi.buildSaplingTransaction(requestJson);
  final json = parseNativeJsonObject(
    raw,
    context: 'build_sapling_transaction/DynamicLibrary',
    redactSensitive: [seedHex, for (final input in inputs) input.secretKeyHex],
  );
  return SaplingBuildResult.fromJson(json);
}

SaplingFeeQuote quoteNativeSaplingFee({
  required ZcashNetwork network,
  required int targetHeight,
  int? feeZatoshis,
  required String seedHex,
  int account = 0,
  Iterable<SaplingBuildSpendNote> spendNotes = const [],
  Iterable<TransparentBuildInput> inputs = const [],
  required Iterable<SaplingBuildOutput> outputs,
  int? regtestNu63ActivationHeight,
  bool allowExperimentalSaplingBuild = false,
  ZcashFfiBindings? bindings,
}) {
  if (!allowExperimentalSaplingBuild) {
    throw StateError(
      'quoteNativeSaplingFee is experimental and native-backed; set '
      'allowExperimentalSaplingBuild: true to opt in. It requires a native '
      'library built with the off-by-default sapling-spend-build feature, '
      'behind the same gate as the build it prices.',
    );
  }
  final ffi = bindings ?? ZcashFfiBindings.instance;
  final requestJson = encodeSaplingBuildRequest(
    network: network._ffiParam,
    targetHeight: targetHeight,
    feeZatoshis: feeZatoshis,
    quoteOnly: true,
    seedHex: seedHex,
    account: account,
    spendNotes: spendNotes,
    inputs: inputs,
    outputs: outputs,
    regtestNu63ActivationHeight: regtestNu63ActivationHeight,
  );
  final raw = ffi.buildSaplingTransaction(requestJson);
  final json = parseNativeJsonObject(
    raw,
    context: 'build_sapling_transaction/DynamicLibrary',
    redactSensitive: [seedHex, for (final input in inputs) input.secretKeyHex],
  );
  return SaplingFeeQuote.fromJson(json);
}

ZcashCompactBlockConversion convertNativeRawBlocks({
  required String network,
  required Iterable<String> rawBlockHex,
  int priorSaplingSize = 0,
  int priorOrchardSize = 0,
  int priorIronwoodSize = 0,
  int? regtestNu63ActivationHeight,
  ZcashFfiBindings? bindings,
}) {
  final ffi = bindings ?? ZcashFfiBindings.instance;
  final raw = ffi.compactBlocksFromRawBlocks(
    encodeCompactBlockRequest(
      network: network,
      rawBlockHex: rawBlockHex,
      priorSaplingSize: priorSaplingSize,
      priorOrchardSize: priorOrchardSize,
      priorIronwoodSize: priorIronwoodSize,
      regtestNu63ActivationHeight: regtestNu63ActivationHeight,
    ),
  );
  final json = parseNativeJsonObject(
    raw,
    context: 'compact_blocks_from_raw_blocks/DynamicLibrary',
  );
  return ZcashCompactBlockConversion.fromJson(json);
}

OrchardBuildResult buildNativeOrchardTransaction({
  required ZcashNetwork network,
  required int targetHeight,
  required OrchardAnchorSource anchor,
  required Iterable<TransparentBuildInput> inputs,
  required OrchardBuildOutput orchardOutput,
  Iterable<TransparentBuildOutput> outputs = const [],
  int? expiryHeight,
  int? regtestNu63ActivationHeight,
  int? feeZatoshis,
  String? rngSeedHex,
  bool allowExperimentalOrchardBuild = false,
  ZcashFfiBindings? bindings,
}) {
  if (!allowExperimentalOrchardBuild) {
    throw StateError(
      'buildNativeOrchardTransaction is experimental and native-backed; set '
      'allowExperimentalOrchardBuild: true to opt in. It requires a native '
      'library built with the off-by-default orchard-tx-build feature, it only '
      'works below the NU6.3 activation height, and the caller remains '
      'responsible for supplying a real Orchard anchor.',
    );
  }
  final ffi = bindings ?? ZcashFfiBindings.instance;
  final requestJson = encodeOrchardBuildRequest(
    network: network._ffiParam,
    targetHeight: targetHeight,
    anchor: anchor,
    inputs: inputs,
    orchardOutput: orchardOutput,
    outputs: outputs,
    expiryHeight: expiryHeight,
    regtestNu63ActivationHeight: regtestNu63ActivationHeight,
    feeZatoshis: feeZatoshis,
    rngSeedHex: rngSeedHex,
  );
  final raw = ffi.buildOrchardTransaction(requestJson);
  final json = parseNativeJsonObject(
    raw,
    context: 'build_orchard_transaction/DynamicLibrary',
    redactSensitive: [
      for (final input in inputs) input.secretKeyHex,
      if (orchardOutput.outgoingViewingKeyHex != null)
        orchardOutput.outgoingViewingKeyHex!,
    ],
  );
  return OrchardBuildResult.fromJson(json);
}

IronwoodBuildResult buildNativeIronwoodTransaction({
  required ZcashNetwork network,
  required int targetHeight,
  required IronwoodAnchorSource anchor,
  required Iterable<TransparentBuildInput> inputs,
  required IronwoodBuildOutput ironwoodOutput,
  Iterable<TransparentBuildOutput> outputs = const [],
  Iterable<IronwoodBuildSpendNote> saplingSpends = const [],
  Iterable<IronwoodBuildOrchardSpendNote> orchardSpends = const [],
  Iterable<IronwoodBuildIronwoodSpendNote> ironwoodSpends = const [],
  int? orchardChangeZatoshis,
  int? ironwoodChangeZatoshis,
  int? expiryHeight,
  int? regtestNu63ActivationHeight,
  String? seedHex,
  int account = 0,
  String? spendParamsPath,
  String? outputParamsPath,
  int? feeZatoshis,
  String? rngSeedHex,
  bool allowExperimentalIronwoodBuild = false,
  ZcashFfiBindings? bindings,
}) {
  if (!allowExperimentalIronwoodBuild) {
    throw StateError(
      'buildNativeIronwoodTransaction is experimental and native-backed; set '
      'allowExperimentalIronwoodBuild: true to opt in. It requires a native '
      'library built with the off-by-default ironwood-tx-build feature, and the '
      'caller remains responsible for supplying a real Ironwood anchor.',
    );
  }
  final ffi = bindings ?? ZcashFfiBindings.instance;
  final requestJson = encodeIronwoodBuildRequest(
    network: network._ffiParam,
    targetHeight: targetHeight,
    anchor: anchor,
    inputs: inputs,
    ironwoodOutput: ironwoodOutput,
    outputs: outputs,
    saplingSpends: saplingSpends,
    orchardSpends: orchardSpends,
    ironwoodSpends: ironwoodSpends,
    orchardChangeZatoshis: orchardChangeZatoshis,
    ironwoodChangeZatoshis: ironwoodChangeZatoshis,
    expiryHeight: expiryHeight,
    regtestNu63ActivationHeight: regtestNu63ActivationHeight,
    seedHex: seedHex,
    account: account,
    spendParamsPath: spendParamsPath,
    outputParamsPath: outputParamsPath,
    feeZatoshis: feeZatoshis,
    rngSeedHex: rngSeedHex,
  );
  final raw = ffi.buildIronwoodTransaction(requestJson);
  final json = parseNativeJsonObject(
    raw,
    context: 'build_ironwood_transaction/DynamicLibrary',
    redactSensitive: [
      for (final input in inputs) input.secretKeyHex,
      if (ironwoodOutput.outgoingViewingKeyHex != null)
        ironwoodOutput.outgoingViewingKeyHex!,
      ?seedHex,
    ],
  );
  return IronwoodBuildResult.fromJson(json);
}

IronwoodFeeQuote quoteNativeIronwoodFee({
  required ZcashNetwork network,
  required int targetHeight,
  required IronwoodAnchorSource anchor,
  required Iterable<TransparentBuildInput> inputs,
  required IronwoodBuildOutput ironwoodOutput,
  Iterable<TransparentBuildOutput> outputs = const [],
  Iterable<IronwoodBuildSpendNote> saplingSpends = const [],
  Iterable<IronwoodBuildOrchardSpendNote> orchardSpends = const [],
  Iterable<IronwoodBuildIronwoodSpendNote> ironwoodSpends = const [],
  int? orchardChangeZatoshis,
  int? ironwoodChangeZatoshis,
  int? expiryHeight,
  int? regtestNu63ActivationHeight,
  String? seedHex,
  int account = 0,
  String? spendParamsPath,
  String? outputParamsPath,
  int? feeZatoshis,
  bool allowExperimentalIronwoodBuild = false,
  ZcashFfiBindings? bindings,
}) {
  if (!allowExperimentalIronwoodBuild) {
    throw StateError(
      'quoteNativeIronwoodFee is experimental and native-backed; set '
      'allowExperimentalIronwoodBuild: true to opt in. It requires a native '
      'library built with the off-by-default ironwood-tx-build feature.',
    );
  }
  final ffi = bindings ?? ZcashFfiBindings.instance;
  final requestJson = encodeIronwoodBuildRequest(
    network: network._ffiParam,
    targetHeight: targetHeight,
    anchor: anchor,
    inputs: inputs,
    ironwoodOutput: ironwoodOutput,
    outputs: outputs,
    saplingSpends: saplingSpends,
    orchardSpends: orchardSpends,
    ironwoodSpends: ironwoodSpends,
    orchardChangeZatoshis: orchardChangeZatoshis,
    ironwoodChangeZatoshis: ironwoodChangeZatoshis,
    expiryHeight: expiryHeight,
    regtestNu63ActivationHeight: regtestNu63ActivationHeight,
    seedHex: seedHex,
    account: account,
    spendParamsPath: spendParamsPath,
    outputParamsPath: outputParamsPath,
    feeZatoshis: feeZatoshis,
    quoteOnly: true,
  );
  final raw = ffi.buildIronwoodTransaction(requestJson);
  final json = parseNativeJsonObject(
    raw,
    context: 'quote_ironwood_fee/DynamicLibrary',
    redactSensitive: [
      for (final input in inputs) input.secretKeyHex,
      if (ironwoodOutput.outgoingViewingKeyHex != null)
        ironwoodOutput.outgoingViewingKeyHex!,
      ?seedHex,
    ],
  );
  return IronwoodFeeQuote.fromJson(json);
}

void _checkUint32Index(int value, String name) {
  if (value < 0 || value > 0xffffffff) {
    throw RangeError.range(value, 0, 0xffffffff, name);
  }
}
