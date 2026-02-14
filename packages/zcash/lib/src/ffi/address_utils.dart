import 'dart:async';
import 'dart:convert';

import 'zcash_ffi_bindings.dart';

enum ZcashNetwork {
  mainnet,
  testnet;

  String get _ffiParam => this == ZcashNetwork.mainnet ? 'main' : 'test';
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

  const UnifiedAddressSet({
    required this.ua,
    this.saplingAddress,
    this.orchardAddress,
    this.transparentAddress,
  });

  @override
  String toString() =>
      'UnifiedAddressSet(ua: $ua, sapling: $saplingAddress, '
      'orchard: $orchardAddress, transparent: $transparentAddress)';
}

/// [seedHex] is the 64-byte BIP 39 seed in hex, not the mnemonic.
Future<UnifiedAddressSet> deriveAddress({
  required String seedHex,
  required ZcashNetwork network,
  int accountIndex = 0,
  int diversifierIndex = 0,
}) async {
  final ffi = ZcashFfiBindings.instance;

  final ufvkJson = ffi.seedToAccountUfvk(
    seedHex,
    network._ffiParam,
    accountIndex,
  );
  final ufvkMap = jsonDecode(ufvkJson) as Map<String, dynamic>;
  if (ufvkMap.containsKey('error')) {
    throw ArgumentError('UFVK derivation failed: ${ufvkMap['error']}');
  }
  final ufvk = ufvkMap['ufvk'] as String;

  final addrJson =
      ffi.ufvkToAddress(ufvk, network._ffiParam, diversifierIndex);
  final addrMap = jsonDecode(addrJson) as Map<String, dynamic>;
  if (addrMap.containsKey('error')) {
    throw ArgumentError('Address derivation failed: ${addrMap['error']}');
  }

  return UnifiedAddressSet(
    ua: addrMap['ua'] as String,
    saplingAddress: addrMap['sapling'] as String?,
    orchardAddress: addrMap['orchard'] as String?,
    transparentAddress: addrMap['transparent'] as String?,
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
  final xpubMap = jsonDecode(xpubJson) as Map<String, dynamic>;
  if (xpubMap.containsKey('error')) {
    throw ArgumentError('xpub derivation failed: ${xpubMap['error']}');
  }
  final xpub = xpubMap['xpub'] as String;

  final addrJson =
      ffi.transparentAddress(xpub, network._ffiParam, childIndex);
  final addrMap = jsonDecode(addrJson) as Map<String, dynamic>;
  if (addrMap.containsKey('error')) {
    throw ArgumentError('Address derivation failed: ${addrMap['error']}');
  }

  return addrMap['address'] as String;
}

bool isValidAddress(String addr, ZcashNetwork network) {
  // The native check accepts either network, so the prefix decides.
  final type = ZcashFfiBindings.instance.addressType(addr);
  if (type == 0) return false;

  switch (network) {
    case ZcashNetwork.mainnet:
      return addr.startsWith('t1') ||
          addr.startsWith('t3') ||
          addr.startsWith('zs1') ||
          addr.startsWith('u1');
    case ZcashNetwork.testnet:
      return addr.startsWith('tm') ||
          addr.startsWith('tn') ||
          addr.startsWith('ztestsapling') ||
          addr.startsWith('utest');
  }
}

AddressType classifyAddress(String addr) {
  return AddressType.fromInt(ZcashFfiBindings.instance.addressType(addr));
}
