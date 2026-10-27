import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

void main() {
  group('ZcashKeyValidation', () {
    test('parses a valid UFVK result with components', () {
      final result = ZcashKeyValidation.fromJson({
        'key_type': 'ufvk',
        'network': 'mainnet',
        'valid': true,
        'components': {'orchard': true, 'sapling': true, 'transparent': false},
      });

      expect(result.keyType, ZcashKeyType.ufvk);
      expect(result.network, ZcashAddressNetwork.mainnet);
      expect(result.valid, isTrue);
      expect(result.reason, isNull);
      expect(result.components!.orchard, isTrue);
      expect(result.components!.transparent, isFalse);
      expect(result.toJson()['valid'], true);
      expect((result.toJson()['components']! as Map)['orchard'], true);
      expect(result.expiryHeight, isNull);
    });

    test('parses P2SH components and Revision 2 expiry', () {
      final result = ZcashKeyValidation.fromJson({
        'key_type': 'ufvk',
        'network': 'mainnet',
        'valid': true,
        'components': {
          'orchard': true,
          'sapling': false,
          'transparent': true,
          'p2pkh': false,
          'p2sh': true,
        },
        'expiry_height': 3600000,
        'expiry_time': 1900000000,
      });

      expect(result.components!.transparent, isTrue);
      expect(result.components!.p2pkh, isFalse);
      expect(result.components!.p2sh, isTrue);
      expect(result.expiryHeight, 3600000);
      expect(result.expiryTime, 1900000000);
    });

    test('parses a wrong-network failure without components', () {
      final result = ZcashKeyValidation.fromJson({
        'key_type': 'sapling_extended_spending_key',
        'network': 'testnet',
        'valid': false,
        'reason': 'wrong_network',
      });

      expect(result.keyType, ZcashKeyType.saplingExtendedSpendingKey);
      expect(result.valid, isFalse);
      expect(result.reason, ZcashKeyValidationReason.wrongNetwork);
      expect(result.components, isNull);
      expect(result.toJson()['reason'], 'wrong_network');
    });

    test('parses an invalid failure', () {
      final result = ZcashKeyValidation.fromJson({
        'key_type': 'transparent_xpub',
        'network': 'regtest',
        'valid': false,
        'reason': 'invalid',
      });

      expect(result.keyType, ZcashKeyType.transparentXpub);
      expect(result.network, ZcashAddressNetwork.regtest);
      expect(result.reason, ZcashKeyValidationReason.invalid);
      expect(result.toJson()['reason'], 'invalid');
    });

    test('key type labels round-trip', () {
      for (final type in ZcashKeyType.values) {
        expect(ZcashKeyType.fromJson(type.label), type);
      }
    });

    test('rejects unknown key type', () {
      expect(() => ZcashKeyType.fromJson('not-a-key'), throwsFormatException);
    });

    test('rejects unknown reason', () {
      expect(
        () => ZcashKeyValidationReason.fromJson('mystery'),
        throwsFormatException,
      );
    });
  });
}
