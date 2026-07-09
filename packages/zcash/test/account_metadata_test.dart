import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

void main() {
  group('ZcashAccountMetadata', () {
    test('parses account receiver metadata', () {
      final metadata = ZcashAccountMetadata.fromJson({
        'network': 'regtest',
        'account_index': 7,
        'ufvk': 'uviewtest1example',
        'transparent_account_xpub': 'tpubexample',
        'receivers': {
          'orchard': true,
          'sapling': true,
          'transparent': true,
          'p2pkh': true,
          'p2sh': false,
          'unknown': 0,
          'total': 3,
        },
        'receiver_kinds': [
          {'kind': 'orchard', 'pool': 'orchard'},
          {'kind': 'sapling', 'pool': 'sapling'},
          {'kind': 'p2pkh', 'pool': 'transparent'},
        ],
      });

      expect(metadata.network, ZcashAddressNetwork.regtest);
      expect(metadata.accountIndex, 7);
      expect(metadata.ufvk, 'uviewtest1example');
      expect(metadata.transparentAccountXpub, 'tpubexample');
      expect(metadata.hasOrchard, isTrue);
      expect(metadata.hasSapling, isTrue);
      expect(metadata.hasTransparent, isTrue);
      expect(metadata.receivers.total, 3);
      expect(metadata.receiverKinds[0].kind, ZcashAddressReceiverType.orchard);
      expect(metadata.receiverKinds[2].pool, ZcashAddressPool.transparent);
      expect(metadata.toJson()['account_index'], 7);
    });

    test('rejects metadata without receivers object', () {
      expect(
        () => ZcashAccountMetadata.fromJson({
          'network': 'mainnet',
          'account_index': 0,
          'ufvk': 'uview1example',
          'receiver_kinds': <Object?>[],
        }),
        throwsFormatException,
      );
    });

    test('rejects metadata without receiver kinds list', () {
      expect(
        () => ZcashAccountMetadata.fromJson({
          'network': 'mainnet',
          'account_index': 0,
          'ufvk': 'uview1example',
          'receivers': {'total': 0},
        }),
        throwsFormatException,
      );
    });
  });
}
