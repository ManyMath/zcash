@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zcash_ffi/zcash_ffi.dart';

// Skipped unless ZCASH_FFI_LIB points at a built libzcash_ffi.

// Bytes 0x00..0x3f, as in the Rust tests.
const _seed =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'
    '202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f';

const _expectedMainnetTAddr = 't1c8oqrzA1kYPdgVhfDNUZn3buAbk6rXxiX';
const _expectedMainnetSapling =
    'zs1zt3mq96vp65l8ch54r78nc50ml68qsyg3pkteq8pn8sfgzakhgw4vqn6px5w08hrf2uzuam5kmj';
const _expectedMainnetUa =
    'u1tcw2tuatlzdc4ncep4nef7v9h5q87jx7t4fzyj7sw5g6775u3fwkucjafgsl2dg6h3hfjtml85ggqakl5mf2c746ygk7qnp8kyhentqkcnpqwarfcceczd0drzuvtxaeak9kadkwp6sn5xpj40cwmpjcu8aqy6v8rueum0h9mvefhhfytvrq2dcwxsx4cdk7uzv99yhspftg72ut509';

bool get _libAvailable =>
    (Platform.environment['ZCASH_FFI_LIB'] ?? '').isNotEmpty;

void main() {
  group('FFI address utilities', skip: _libAvailable ? false : 'ZCASH_FFI_LIB not set', () {
    test('deriveAddress returns correct mainnet UA', () async {
      final set = await deriveAddress(
        seedHex: _seed,
        network: ZcashNetwork.mainnet,
      );
      expect(set.ua, equals(_expectedMainnetUa));
      expect(set.saplingAddress, equals(_expectedMainnetSapling));
      expect(set.transparentAddress, equals(_expectedMainnetTAddr));
    });

    test('deriveTransparentAddress child 0 matches expected', () async {
      final addr = await deriveTransparentAddress(
        seedHex: _seed,
        network: ZcashNetwork.mainnet,
      );
      expect(addr, equals(_expectedMainnetTAddr));
    });

    test('deriveTransparentAddress child 1 and 2 differ', () async {
      final a0 = await deriveTransparentAddress(
        seedHex: _seed,
        network: ZcashNetwork.mainnet,
        childIndex: 0,
      );
      final a1 = await deriveTransparentAddress(
        seedHex: _seed,
        network: ZcashNetwork.mainnet,
        childIndex: 1,
      );
      final a2 = await deriveTransparentAddress(
        seedHex: _seed,
        network: ZcashNetwork.mainnet,
        childIndex: 2,
      );
      expect(a0, isNot(equals(a1)));
      expect(a1, isNot(equals(a2)));
    });

    test('classifyAddress transparent', () {
      expect(
        classifyAddress(_expectedMainnetTAddr),
        AddressType.transparent,
      );
    });

    test('classifyAddress sapling', () {
      expect(
        classifyAddress(_expectedMainnetSapling),
        AddressType.sapling,
      );
    });

    test('classifyAddress unified', () {
      expect(classifyAddress(_expectedMainnetUa), AddressType.unified);
    });

    test('classifyAddress unknown for garbage', () {
      expect(classifyAddress('notanaddress'), AddressType.unknown);
    });

    test('isValidAddress mainnet transparent', () {
      expect(
        isValidAddress(_expectedMainnetTAddr, ZcashNetwork.mainnet),
        isTrue,
      );
    });

    test('isValidAddress testnet transparent', () async {
      final addr = await deriveTransparentAddress(
        seedHex: _seed,
        network: ZcashNetwork.testnet,
      );
      expect(isValidAddress(addr, ZcashNetwork.testnet), isTrue);
      expect(isValidAddress(addr, ZcashNetwork.mainnet), isFalse);
    });

    test('different account indices produce different UFVKs', () async {
      final set0 = await deriveAddress(
        seedHex: _seed,
        network: ZcashNetwork.mainnet,
        accountIndex: 0,
      );
      final set1 = await deriveAddress(
        seedHex: _seed,
        network: ZcashNetwork.mainnet,
        accountIndex: 1,
      );
      expect(set0.ua, isNot(equals(set1.ua)));
    });

    test('different diversifier indices produce different UAs', () async {
      final set0 = await deriveAddress(
        seedHex: _seed,
        network: ZcashNetwork.mainnet,
        diversifierIndex: 0,
      );
      final set1 = await deriveAddress(
        seedHex: _seed,
        network: ZcashNetwork.mainnet,
        diversifierIndex: 1,
      );
      expect(set0.ua, isNot(equals(set1.ua)));
    });
  });

  group('FFI bindings version', skip: _libAvailable ? false : 'ZCASH_FFI_LIB not set', () {
    test('version is semver', () {
      final v = ZcashFfiBindings.instance.version();
      expect(v, matches(RegExp(r'^\d+\.\d+\.\d+')));
    });
  });

  group('FFI Equihash solver', skip: _libAvailable ? false : 'ZCASH_FFI_LIB not set', () {
    test('solveEquihash returns 32-byte nonce and 1344-byte solution', () {
      final header = Uint8List.fromList(List<int>.generate(108, (i) => i));
      final result = solveEquihash(header);
      expect(result.nonce, hasLength(32));
      expect(result.solution, hasLength(1344));
    });
  });
}
