import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

void main() {
  group('ZcashViewingKeys', () {
    test('parses transparent, sapling, and orchard viewing-key metadata', () {
      final keys = ZcashViewingKeys.fromJson({
        'network': 'mainnet',
        'account_index': 3,
        'transparent': {
          'available': true,
          'external_ivk': 'aa' * 65,
          'internal_ivk': 'bb' * 65,
          'default_external_address': 't1example',
          'default_external_index': 0,
        },
        'sapling': {
          'available': true,
          'default_address': 'zs1example',
          'default_diversifier_index': 5,
        },
        'orchard': {'available': true},
      });

      expect(keys.network, ZcashAddressNetwork.mainnet);
      expect(keys.accountIndex, 3);
      expect(keys.hasTransparent, isTrue);
      expect(keys.hasSapling, isTrue);
      expect(keys.hasOrchard, isTrue);
      expect(keys.transparent.externalIvk, 'aa' * 65);
      expect(keys.transparent.internalIvk, 'bb' * 65);
      expect(keys.transparent.defaultExternalAddress, 't1example');
      expect(keys.transparent.defaultExternalIndex, 0);
      expect(keys.sapling.defaultAddress, 'zs1example');
      expect(keys.sapling.defaultDiversifierIndex, 5);
      expect(keys.toJson()['account_index'], 3);
      expect(
        (keys.toJson()['transparent']! as Map)['external_ivk'],
        'aa' * 65,
      );
    });

    test('parses absent pools without viewing-key material', () {
      final keys = ZcashViewingKeys.fromJson({
        'network': 'testnet',
        'account_index': 0,
        'transparent': {'available': false},
        'sapling': {'available': false},
        'orchard': {'available': false},
      });

      expect(keys.network, ZcashAddressNetwork.testnet);
      expect(keys.hasTransparent, isFalse);
      expect(keys.transparent.externalIvk, isNull);
      expect(keys.transparent.defaultExternalAddress, isNull);
      expect(keys.sapling.defaultAddress, isNull);
      expect(keys.hasOrchard, isFalse);
    });

    test('rejects metadata without transparent object', () {
      expect(
        () => ZcashViewingKeys.fromJson({
          'network': 'mainnet',
          'account_index': 0,
          'sapling': {'available': false},
          'orchard': {'available': false},
        }),
        throwsFormatException,
      );
    });

    test('rejects metadata without sapling object', () {
      expect(
        () => ZcashViewingKeys.fromJson({
          'network': 'mainnet',
          'account_index': 0,
          'transparent': {'available': false},
          'orchard': {'available': false},
        }),
        throwsFormatException,
      );
    });

    test('rejects metadata without orchard object', () {
      expect(
        () => ZcashViewingKeys.fromJson({
          'network': 'mainnet',
          'account_index': 0,
          'transparent': {'available': false},
          'sapling': {'available': false},
        }),
        throwsFormatException,
      );
    });
  });
}
