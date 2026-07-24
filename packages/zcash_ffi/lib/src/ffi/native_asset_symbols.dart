@DefaultAsset('package:zcash_ffi/src/ffi/zcash_native_assets.dart')
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

@Native<Int32 Function(Pointer<Utf8>)>(symbol: 'zcash_ffi_address_type')
external int _zcashFfiAddressType(Pointer<Utf8> p0);

@Native<Pointer<Utf8> Function(Pointer<Utf8>)>(
  symbol: 'zcash_ffi_build_sapling_transaction',
)
external Pointer<Utf8> _zcashFfiBuildSaplingTransaction(Pointer<Utf8> p0);

@Native<Pointer<Utf8> Function(Pointer<Utf8>)>(
  symbol: 'zcash_ffi_build_transparent_transaction',
)
external Pointer<Utf8> _zcashFfiBuildTransparentTransaction(Pointer<Utf8> p0);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>(
  symbol: 'zcash_ffi_classify_transparent_address',
)
external Pointer<Utf8> _zcashFfiClassifyTransparentAddress(
  Pointer<Utf8> p0,
  Pointer<Utf8> p1,
);

@Native<Pointer<Utf8> Function(Pointer<Utf8>)>(
  symbol: 'zcash_ffi_classify_transparent_script',
)
external Pointer<Utf8> _zcashFfiClassifyTransparentScript(Pointer<Utf8> p0);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>(
  symbol: 'zcash_ffi_decode_address',
)
external Pointer<Utf8> _zcashFfiDecodeAddress(
  Pointer<Utf8> p0,
  Pointer<Utf8> p1,
);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>(
  symbol: 'zcash_ffi_decode_transaction',
)
external Pointer<Utf8> _zcashFfiDecodeTransaction(
  Pointer<Utf8> p0,
  Pointer<Utf8> p1,
);

@Native<Void Function(Pointer<Utf8>)>(symbol: 'zcash_ffi_free_string')
external void _zcashFfiFreeString(Pointer<Utf8> p0);

@Native<Bool Function(Pointer<Utf8>)>(symbol: 'zcash_ffi_is_shielded_address')
external bool _zcashFfiIsShieldedAddress(Pointer<Utf8> p0);

@Native<Bool Function(Pointer<Utf8>)>(
  symbol: 'zcash_ffi_is_transparent_address',
)
external bool _zcashFfiIsTransparentAddress(Pointer<Utf8> p0);

@Native<Pointer<Utf8> Function(Pointer<Utf8>)>(
  symbol: 'zcash_ffi_network_constants',
)
external Pointer<Utf8> _zcashFfiNetworkConstants(Pointer<Utf8> p0);

@Native<Pointer<Utf8> Function(Pointer<Utf8>)>(
  symbol: 'zcash_ffi_mnemonic_from_entropy',
)
external Pointer<Utf8> _zcashFfiMnemonicFromEntropy(Pointer<Utf8> p0);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>(
  symbol: 'zcash_ffi_mnemonic_to_seed',
)
external Pointer<Utf8> _zcashFfiMnemonicToSeed(
  Pointer<Utf8> p0,
  Pointer<Utf8> p1,
);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>)>(
  symbol: 'zcash_ffi_scan_compact_blocks',
)
external Pointer<Utf8> _zcashFfiScanCompactBlocks(
  Pointer<Utf8> p0,
  Pointer<Utf8> p1,
  Pointer<Utf8> p2,
);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint32)>(
  symbol: 'zcash_ffi_seed_to_account_metadata',
)
external Pointer<Utf8> _zcashFfiSeedToAccountMetadata(
  Pointer<Utf8> p0,
  Pointer<Utf8> p1,
  int p2,
);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint32)>(
  symbol: 'zcash_ffi_seed_to_account_ufvk',
)
external Pointer<Utf8> _zcashFfiSeedToAccountUfvk(
  Pointer<Utf8> p0,
  Pointer<Utf8> p1,
  int p2,
);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint32)>(
  symbol: 'zcash_ffi_seed_to_sapling_spending_key',
)
external Pointer<Utf8> _zcashFfiSeedToSaplingSpendingKey(
  Pointer<Utf8> p0,
  Pointer<Utf8> p1,
  int p2,
);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint32)>(
  symbol: 'zcash_ffi_seed_to_transparent_xpub',
)
external Pointer<Utf8> _zcashFfiSeedToTransparentXpub(
  Pointer<Utf8> p0,
  Pointer<Utf8> p1,
  int p2,
);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint32)>(
  symbol: 'zcash_ffi_seed_to_viewing_keys',
)
external Pointer<Utf8> _zcashFfiSeedToViewingKeys(
  Pointer<Utf8> p0,
  Pointer<Utf8> p1,
  int p2,
);

@Native<Pointer<Utf8> Function(Pointer<Uint8>, IntPtr)>(
  symbol: 'zcash_ffi_solve_equihash',
)
external Pointer<Utf8> _zcashFfiSolveEquihash(Pointer<Uint8> p0, int p1);

@Native<Pointer<Utf8> Function(Pointer<Utf8>)>(
  symbol: 'zcash_ffi_transaction_txid',
)
external Pointer<Utf8> _zcashFfiTransactionTxid(Pointer<Utf8> p0);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint32)>(
  symbol: 'zcash_ffi_transparent_address',
)
external Pointer<Utf8> _zcashFfiTransparentAddress(
  Pointer<Utf8> p0,
  Pointer<Utf8> p1,
  int p2,
);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint32)>(
  symbol: 'zcash_ffi_ufvk_to_address',
)
external Pointer<Utf8> _zcashFfiUfvkToAddress(
  Pointer<Utf8> p0,
  Pointer<Utf8> p1,
  int p2,
);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>(
  symbol: 'zcash_ffi_unified_address_receivers',
)
external Pointer<Utf8> _zcashFfiUnifiedAddressReceivers(
  Pointer<Utf8> p0,
  Pointer<Utf8> p1,
);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>)>(
  symbol: 'zcash_ffi_validate_key',
)
external Pointer<Utf8> _zcashFfiValidateKey(
  Pointer<Utf8> p0,
  Pointer<Utf8> p1,
  Pointer<Utf8> p2,
);

@Native<Pointer<Utf8> Function()>(symbol: 'zcash_ffi_version')
external Pointer<Utf8> _zcashFfiVersion();

final Map<String, Pointer<Void> Function()> _addresses = {
  'zcash_ffi_address_type': () =>
      Native.addressOf<NativeFunction<Int32 Function(Pointer<Utf8>)>>(
        _zcashFfiAddressType,
      ).cast(),
  'zcash_ffi_build_sapling_transaction': () =>
      Native.addressOf<NativeFunction<Pointer<Utf8> Function(Pointer<Utf8>)>>(
        _zcashFfiBuildSaplingTransaction,
      ).cast(),
  'zcash_ffi_build_transparent_transaction': () =>
      Native.addressOf<NativeFunction<Pointer<Utf8> Function(Pointer<Utf8>)>>(
        _zcashFfiBuildTransparentTransaction,
      ).cast(),
  'zcash_ffi_classify_transparent_address': () =>
      Native.addressOf<
            NativeFunction<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>
          >(_zcashFfiClassifyTransparentAddress)
          .cast(),
  'zcash_ffi_classify_transparent_script': () =>
      Native.addressOf<NativeFunction<Pointer<Utf8> Function(Pointer<Utf8>)>>(
        _zcashFfiClassifyTransparentScript,
      ).cast(),
  'zcash_ffi_decode_address': () =>
      Native.addressOf<
            NativeFunction<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>
          >(_zcashFfiDecodeAddress)
          .cast(),
  'zcash_ffi_decode_transaction': () =>
      Native.addressOf<
            NativeFunction<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>
          >(_zcashFfiDecodeTransaction)
          .cast(),
  'zcash_ffi_free_string': () =>
      Native.addressOf<NativeFunction<Void Function(Pointer<Utf8>)>>(
        _zcashFfiFreeString,
      ).cast(),
  'zcash_ffi_is_shielded_address': () =>
      Native.addressOf<NativeFunction<Bool Function(Pointer<Utf8>)>>(
        _zcashFfiIsShieldedAddress,
      ).cast(),
  'zcash_ffi_is_transparent_address': () =>
      Native.addressOf<NativeFunction<Bool Function(Pointer<Utf8>)>>(
        _zcashFfiIsTransparentAddress,
      ).cast(),
  'zcash_ffi_network_constants': () =>
      Native.addressOf<NativeFunction<Pointer<Utf8> Function(Pointer<Utf8>)>>(
        _zcashFfiNetworkConstants,
      ).cast(),
  'zcash_ffi_mnemonic_from_entropy': () =>
      Native.addressOf<NativeFunction<Pointer<Utf8> Function(Pointer<Utf8>)>>(
        _zcashFfiMnemonicFromEntropy,
      ).cast(),
  'zcash_ffi_mnemonic_to_seed': () =>
      Native.addressOf<
            NativeFunction<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>
          >(_zcashFfiMnemonicToSeed)
          .cast(),
  'zcash_ffi_scan_compact_blocks': () =>
      Native.addressOf<
            NativeFunction<
              Pointer<Utf8> Function(
                Pointer<Utf8>,
                Pointer<Utf8>,
                Pointer<Utf8>,
              )
            >
          >(_zcashFfiScanCompactBlocks)
          .cast(),
  'zcash_ffi_seed_to_account_metadata': () =>
      Native.addressOf<
            NativeFunction<
              Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint32)
            >
          >(_zcashFfiSeedToAccountMetadata)
          .cast(),
  'zcash_ffi_seed_to_account_ufvk': () =>
      Native.addressOf<
            NativeFunction<
              Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint32)
            >
          >(_zcashFfiSeedToAccountUfvk)
          .cast(),
  'zcash_ffi_seed_to_sapling_spending_key': () =>
      Native.addressOf<
            NativeFunction<
              Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint32)
            >
          >(_zcashFfiSeedToSaplingSpendingKey)
          .cast(),
  'zcash_ffi_seed_to_transparent_xpub': () =>
      Native.addressOf<
            NativeFunction<
              Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint32)
            >
          >(_zcashFfiSeedToTransparentXpub)
          .cast(),
  'zcash_ffi_seed_to_viewing_keys': () =>
      Native.addressOf<
            NativeFunction<
              Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint32)
            >
          >(_zcashFfiSeedToViewingKeys)
          .cast(),
  'zcash_ffi_solve_equihash': () =>
      Native.addressOf<
            NativeFunction<Pointer<Utf8> Function(Pointer<Uint8>, IntPtr)>
          >(_zcashFfiSolveEquihash)
          .cast(),
  'zcash_ffi_transaction_txid': () =>
      Native.addressOf<NativeFunction<Pointer<Utf8> Function(Pointer<Utf8>)>>(
        _zcashFfiTransactionTxid,
      ).cast(),
  'zcash_ffi_transparent_address': () =>
      Native.addressOf<
            NativeFunction<
              Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint32)
            >
          >(_zcashFfiTransparentAddress)
          .cast(),
  'zcash_ffi_ufvk_to_address': () =>
      Native.addressOf<
            NativeFunction<
              Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint32)
            >
          >(_zcashFfiUfvkToAddress)
          .cast(),
  'zcash_ffi_unified_address_receivers': () =>
      Native.addressOf<
            NativeFunction<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>
          >(_zcashFfiUnifiedAddressReceivers)
          .cast(),
  'zcash_ffi_validate_key': () =>
      Native.addressOf<
            NativeFunction<
              Pointer<Utf8> Function(
                Pointer<Utf8>,
                Pointer<Utf8>,
                Pointer<Utf8>,
              )
            >
          >(_zcashFfiValidateKey)
          .cast(),
  'zcash_ffi_version': () =>
      Native.addressOf<NativeFunction<Pointer<Utf8> Function()>>(
        _zcashFfiVersion,
      ).cast(),
};

Iterable<String> get nativeAssetSymbolNames => _addresses.keys;

Pointer<T> nativeAssetSymbol<T extends NativeType>(String symbol) {
  final address = _addresses[symbol];
  if (address == null) {
    throw ArgumentError.value(
      symbol,
      'symbol',
      'not a zcash-ffi export the native-asset table declares',
    );
  }
  return address().cast<T>();
}
