import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:zcash/zcash.dart';
import 'native_result.dart';
import 'native_string.dart';

@Native<Pointer<Utf8> Function()>(symbol: 'zcash_ffi_version')
external Pointer<Utf8> _zcashFfiVersion();

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
