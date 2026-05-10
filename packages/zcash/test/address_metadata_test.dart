import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

void main() {
  group('ZcashAddressMetadata', () {
    test('parses structured unified receiver metadata', () {
      final metadata = ZcashAddressMetadata.fromJson({
        'network': 'mainnet',
        'receiver_type': 'unified',
        'pool': 'mixed',
        'receivers': {
          'sprout': false,
          'orchard': true,
          'sapling': true,
          'transparent': true,
          'transparent_kind': 'p2pkh',
          'unknown': 0,
          'total': 3,
        },
      });

      expect(metadata.network, ZcashAddressNetwork.mainnet);
      expect(metadata.receiverType, ZcashAddressReceiverType.unified);
      expect(metadata.pool, ZcashAddressPool.mixed);
      expect(metadata.receivers.orchard, isTrue);
      expect(metadata.receivers.sapling, isTrue);
      expect(metadata.receivers.transparent, isTrue);
      expect(metadata.receivers.transparentKind, 'p2pkh');
      expect(metadata.receivers.total, 3);
    });

    test('rejects metadata without receiver object', () {
      expect(
        () => ZcashAddressMetadata.fromJson({
          'network': 'mainnet',
          'receiver_type': 'p2pkh',
          'pool': 'transparent',
        }),
        throwsFormatException,
      );
    });
  });

  group('ZcashUnifiedAddressReceiverInventory', () {
    test('parses receiver inventory counts and kinds', () {
      final inventory = ZcashUnifiedAddressReceiverInventory.fromJson({
        'network': 'mainnet',
        'address_type': 'unified',
        'receiver_count': 3,
        'receivers': [
          {'index': 0, 'kind': 'orchard', 'pool': 'orchard'},
          {'index': 1, 'kind': 'sapling', 'pool': 'sapling'},
          {'index': 2, 'kind': 'p2pkh', 'pool': 'transparent'},
        ],
        'counts': {
          'orchard': 1,
          'sapling': 1,
          'transparent': 1,
          'p2pkh': 1,
          'p2sh': 0,
          'unknown': 0,
          'total': 3,
        },
      });

      expect(inventory.network, ZcashAddressNetwork.mainnet);
      expect(inventory.receiverCount, 3);
      expect(inventory.hasOrchard, isTrue);
      expect(inventory.hasSapling, isTrue);
      expect(inventory.hasTransparent, isTrue);
      expect(inventory.receivers[0].kind, ZcashAddressReceiverType.orchard);
      expect(inventory.receivers[2].pool, ZcashAddressPool.transparent);
      expect(inventory.counts.p2pkh, 1);
      expect(inventory.toJson()['address_type'], 'unified');
    });

    test('rejects inventory without receiver array', () {
      expect(
        () => ZcashUnifiedAddressReceiverInventory.fromJson({
          'network': 'mainnet',
          'counts': {'total': 0},
        }),
        throwsFormatException,
      );
    });

    test('supports unknown receiver placeholders', () {
      final inventory = ZcashUnifiedAddressReceiverInventory.fromJson({
        'network': 'testnet',
        'receivers': [
          {'index': 0, 'kind': 'unknown', 'pool': 'unknown'},
        ],
        'counts': {'unknown': 1, 'total': 1},
      });

      expect(inventory.network, ZcashAddressNetwork.testnet);
      expect(inventory.receivers.single.kind, ZcashAddressReceiverType.unknown);
      expect(inventory.receivers.single.pool, ZcashAddressPool.unknown);
      expect(inventory.counts.unknown, 1);
    });
  });

  group('ZcashTransparentClassification', () {
    test('parses transparent address classification', () {
      final classification = ZcashTransparentClassification.fromJson({
        'network': 'mainnet',
        'input_type': 'address',
        'kind': 'p2pkh',
        'pool': 'transparent',
        'standard': true,
        'transparent': true,
        'script_size': 25,
      });

      expect(classification.network, ZcashAddressNetwork.mainnet);
      expect(
        classification.inputType,
        ZcashTransparentClassificationInput.address,
      );
      expect(classification.kind, ZcashTransparentClassificationKind.p2pkh);
      expect(classification.pool, ZcashAddressPool.transparent);
      expect(classification.standard, isTrue);
      expect(classification.transparent, isTrue);
      expect(classification.scriptSize, 25);
      expect(classification.toJson()['kind'], 'p2pkh');
    });

    test('parses non-standard script classification without network', () {
      final classification = ZcashTransparentClassification.fromJson({
        'input_type': 'script',
        'kind': 'non_standard',
        'pool': 'unknown',
        'standard': false,
        'transparent': false,
        'script_size': 1,
      });

      expect(classification.network, isNull);
      expect(
        classification.inputType,
        ZcashTransparentClassificationInput.script,
      );
      expect(
        classification.kind,
        ZcashTransparentClassificationKind.nonStandard,
      );
      expect(classification.pool, ZcashAddressPool.unknown);
      expect(classification.standard, isFalse);
      expect(classification.transparent, isFalse);
      expect(classification.toJson()['kind'], 'non_standard');
    });
  });

  group('ZcashDiversifierSearchResult', () {
    test('parses structured diversifier search metadata', () {
      final result = ZcashDiversifierSearchResult.fromJson({
        'requested_index': 4,
        'next_valid_index': 6,
        'skipped_count': 2,
        'receiver_presence': {
          'orchard': true,
          'sapling': true,
          'transparent': true,
          'transparent_kind': 'p2pkh',
          'total': 3,
        },
        'addresses': {
          'ua': 'u1example',
          'sapling': 'zs1example',
          'orchard': 'u1orchardexample',
          'transparent': 't1example',
        },
      });

      expect(result.requestedIndex, 4);
      expect(result.nextValidIndex, 6);
      expect(result.skippedCount, 2);
      expect(result.receiverPresence.orchard, isTrue);
      expect(result.receiverPresence.transparentKind, 'p2pkh');
      expect(result.addresses.ua, 'u1example');
      expect(result.addresses.saplingAddress, 'zs1example');
      expect(result.addresses.transparentAddress, 't1example');
      expect(result.toJson()['next_valid_index'], 6);
      expect(
        result.addressEncoding,
        isNull,
        reason: 'a native library predating the field reports no encoding',
      );
    });

    test('carries the encoding the addresses were derived under', () {
      final result = ZcashDiversifierSearchResult.fromJson({
        'requested_index': 0,
        'next_valid_index': 0,
        'skipped_count': 0,
        'address_encoding': 'regtest',
        'receiver_presence': {
          'orchard': true,
          'sapling': true,
          'transparent': true,
          'transparent_kind': 'p2pkh',
          'total': 3,
        },
        'addresses': {
          'ua': 'uregtest1example',
          'sapling': 'zregtestsapling1example',
          'orchard': 'uregtest1orchardexample',
          'transparent': 'tmexample',
        },
      });

      expect(result.addressEncoding, 'regtest');
      expect(result.toJson()['address_encoding'], 'regtest');
    });

    test('rejects result without receiver presence object', () {
      expect(
        () => ZcashDiversifierSearchResult.fromJson({
          'requested_index': 0,
          'next_valid_index': 0,
          'addresses': {'ua': 'u1example'},
        }),
        throwsFormatException,
      );
    });

    test('rejects result without addresses object', () {
      expect(
        () => ZcashDiversifierSearchResult.fromJson({
          'requested_index': 0,
          'next_valid_index': 0,
          'receiver_presence': {'total': 0},
        }),
        throwsFormatException,
      );
    });
  });
}
