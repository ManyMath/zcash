@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zcash_ffi/src/ffi/native_asset_symbols.dart';
import 'package:zcash_ffi/zcash_ffi.dart';

void main() {
  group('the native-asset table', () {
    test('declares every symbol the bindings look up', () {
      final source = File(
        'lib/src/ffi/zcash_ffi_bindings.dart',
      ).readAsStringSync();
      final lookedUp = {
        for (final m in RegExp(r"'(zcash_ffi_[a-z0-9_]+)'").allMatches(source))
          m.group(1)!,
      };

      expect(lookedUp, isNotEmpty);
      expect(
        lookedUp.difference(nativeAssetSymbolNames.toSet()),
        isEmpty,
        reason:
            'a symbol the bindings look up and the table does not declare '
            'works under ZCASH_FFI_LIB and throws for every consumer without it',
      );
    });

    test('resolves every symbol it declares in the hook-built library', () {
      for (final name in nativeAssetSymbolNames) {
        expect(nativeAssetSymbol<Void>(name), isNot(nullptr), reason: name);
      }
    });

    test('refuses a symbol it does not declare, as a DynamicLibrary does', () {
      expect(
        () => nativeAssetSymbol<Void>('zcash_ffi_not_an_export'),
        throwsArgumentError,
      );
    });
  });

  group('ZcashFfiBindings.resolve', () {
    test('with nothing set, reaches the code asset and the wallet API', () {
      final bindings = ZcashFfiBindings.resolve(const {});

      expect(bindings.version(), zcashNativeVersion());
      final metadata = deriveNativeAccountMetadata(
        seedHex: '00' * 32,
        network: ZcashNetwork.mainnet,
        bindings: bindings,
      );
      expect(metadata.ufvk, startsWith('uview1'));
    });

    test('prefers ZCASH_FFI_LIB over the code asset', () {
      expect(
        () => ZcashFfiBindings.resolve(const {
          'ZCASH_FFI_LIB': '/nonexistent/libzcash_ffi',
        }),
        throwsArgumentError,
      );
    });
  });
}
