import 'dart:convert';
import 'dart:io';

import 'package:zcash_flutter/src/ffi/zcash_native_assets.dart';

const _seedHex =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'
    '202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f';
const _malformedUfvk = 'not-a-real-uviewtest-wallet-input';

void main(List<String> args) {
  final mode = args.isEmpty ? 'matrix' : args.first;
  try {
    switch (mode) {
      case 'matrix':
        _printMatrix();
      case 'errors':
        _printErrors();
      default:
        stderr.writeln('unknown mode: $mode');
        exitCode = 64;
    }
  } catch (error, stackTrace) {
    stderr.writeln('unified_address_probe failed: $error');
    stderr.writeln(stackTrace);
    exitCode = 1;
  }
}

void _printMatrix() {
  stdout.writeln(
    jsonEncode({
      'regtest': _deriveNetwork('regtest'),
      'test': _deriveNetwork('test'),
    }),
  );
}

Map<String, Object?> _deriveNetwork(String network) {
  final ufvk = zcashNativeSeedToAccountUfvk(
    seedHex: _seedHex,
    network: network,
  );
  final repeatedUfvk = zcashNativeSeedToAccountUfvk(
    seedHex: _seedHex,
    network: network,
  );
  final address = zcashNativeUfvkToAddress(ufvk: ufvk, network: network);
  final repeatedAddress = zcashNativeUfvkToAddress(
    ufvk: ufvk,
    network: network,
  );
  return {
    'ufvkMatches': ufvk == repeatedUfvk,
    'ufvkPrefix': ufvk.substring(0, 9),
    'ua': address.ua,
    'sapling': address.sapling,
    'orchard': address.orchard,
    'transparent': address.transparent,
    'addressEncoding': address.addressEncoding,
    'repeated': _addressJson(repeatedAddress),
  };
}

Map<String, Object?> _addressJson(ZcashNativeAddressSet address) => {
  'ua': address.ua,
  'sapling': address.sapling,
  'orchard': address.orchard,
  'transparent': address.transparent,
  'addressEncoding': address.addressEncoding,
};

void _printErrors() {
  final malformedUfvkError = _captureStateError(
    () => zcashNativeUfvkToAddress(ufvk: _malformedUfvk, network: 'test'),
  );
  final ufvk = zcashNativeSeedToAccountUfvk(seedHex: _seedHex, network: 'test');
  final unsupportedNetworkError = _captureStateError(
    () => zcashNativeUfvkToAddress(ufvk: ufvk, network: 'not-a-network'),
  );
  stdout.writeln(
    jsonEncode({
      'malformedUfvkError': malformedUfvkError,
      'unsupportedNetworkError': unsupportedNetworkError,
      'containsSeed':
          malformedUfvkError.contains(_seedHex) ||
          unsupportedNetworkError.contains(_seedHex),
      'containsMalformedUfvk':
          malformedUfvkError.contains(_malformedUfvk) ||
          unsupportedNetworkError.contains(_malformedUfvk),
      'containsDerivedUfvk':
          malformedUfvkError.contains(ufvk) ||
          unsupportedNetworkError.contains(ufvk),
    }),
  );
}

String _captureStateError(void Function() action) {
  try {
    action();
  } on StateError catch (error) {
    return error.message;
  }
  throw StateError('expected native-assets call to fail');
}
