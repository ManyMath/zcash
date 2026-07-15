@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:zcash_ffi/src/ffi/zcash_native_assets.dart';

const _seed =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'
    '202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f';

void main() {
  group('native-assets FFI wrapper', () {

    test('version is semver through native assets', () {
      expect(zcashNativeVersion(), matches(RegExp(r'^\d+\.\d+\.\d+')));
    });

    test('throws explicit Dart errors for malformed seed and network', () {
      expect(
        () => zcashNativeSeedToAccountUfvk(
          seedHex: 'not-hex',
          network: 'regtest',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('seed is not valid hex'),
          ),
        ),
      );
      expect(
        () => zcashNativeSeedToAccountUfvk(
          seedHex: _seed,
          network: 'not-a-network',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains("network must be 'main', 'test', or 'regtest'"),
          ),
        ),
      );
    });

    test('throws explicit Dart errors for Sapling key invalid inputs', () {
      expect(
        () => zcashNativeSeedToSaplingSpendingKey(
          seedHex: '000102',
          network: 'regtest',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('seed_to_sapling_spending_key failed'),
              contains('seed must be at least 32 bytes'),
              isNot(contains('000102')),
            ),
          ),
        ),
      );
      expect(
        () => zcashNativeSeedToSaplingSpendingKey(
          seedHex: _seed,
          network: 'not-a-network',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains("network must be 'main', 'test', or 'regtest'"),
          ),
        ),
      );
    });
  });
}
