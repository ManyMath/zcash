@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:zcash_ffi/zcash_ffi.dart'
    show
        CapabilityStatus,
        CompactBlockScanInput,
        NativeCapability,
        NativeCapabilitySnapshot,
        ZcashAddressNetwork,
        ZcashAddressPool,
        ZcashAddressReceiverType,
        ZcashKeyType,
        ZcashKeyValidationReason;
import 'package:zcash_ffi/src/ffi/zcash_native_assets.dart';

const _seed =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'
    '202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f';

void main() {
  group('native-assets FFI wrapper', () {

    test('version is semver through native assets', () {
      expect(zcashNativeVersion(), matches(RegExp(r'^\d+\.\d+\.\d+')));
    });

    test('native capabilities match the documented package matrix', () {
      final capabilities = zcashNativeCapabilities();

      expect(
        capabilities.statuses,
        NativeCapabilitySnapshot.documented.statuses,
      );
      expect(
        capabilities.statusFor(NativeCapability.saplingScan),
        CapabilityStatus.supported,
      );
      expect(
        capabilities.statusFor(NativeCapability.orchardNoteDiscovery),
        CapabilityStatus.unsupported,
      );
    });

    test('derives deterministic regtest UFVK and address components', () {
      final ufvk = zcashNativeSeedToAccountUfvk(
        seedHex: _seed,
        network: 'regtest',
      );
      final accountMetadata = zcashNativeSeedToAccountMetadata(
        seedHex: _seed,
        network: 'regtest',
      );
      expect(accountMetadata.network, ZcashAddressNetwork.regtest);
      expect(accountMetadata.accountIndex, 0);
      expect(accountMetadata.ufvk, equals(ufvk));
      expect(accountMetadata.transparentAccountXpub, startsWith('tpub'));
      expect(accountMetadata.hasOrchard, isTrue);
      expect(accountMetadata.hasSapling, isTrue);
      expect(accountMetadata.hasTransparent, isTrue);

      final viewingKeys = zcashNativeSeedToViewingKeys(
        seedHex: _seed,
        network: 'regtest',
      );
      expect(viewingKeys.network, ZcashAddressNetwork.regtest);
      expect(viewingKeys.accountIndex, 0);
      expect(viewingKeys.transparent.externalIvk, hasLength(130));
      expect(viewingKeys.transparent.internalIvk, hasLength(130));
      expect(viewingKeys.transparent.defaultExternalAddress, startsWith('tm'));
      _expectOptionalPrefix(
        viewingKeys.sapling.defaultAddress,
        'zregtestsapling',
      );
      expect(viewingKeys.hasOrchard, isTrue);
      expect(viewingKeys.toJson().toString(), isNot(contains(_seed)));

      final repeated = zcashNativeSeedToAccountUfvk(
        seedHex: _seed,
        network: 'test',
      );
      expect(ufvk, equals(repeated));
      expect(ufvk, startsWith('uviewtest'));

      final address = zcashNativeUfvkToAddress(ufvk: ufvk, network: 'regtest');
      final diversifierSearch = zcashNativeUfvkToDiversifierSearch(
        ufvk: ufvk,
        network: 'regtest',
        diversifierIndex: 1,
      );
      final repeatedAddress = zcashNativeUfvkToAddress(
        ufvk: ufvk,
        network: 'test',
      );
      expect(diversifierSearch.requestedIndex, 1);
      expect(diversifierSearch.nextValidIndex, greaterThanOrEqualTo(1));
      expect(diversifierSearch.receiverPresence.sapling, isTrue);
      expect(diversifierSearch.addresses.ua, startsWith('uregtest'));
      expect(diversifierSearch.addressEncoding, 'regtest');
      expect(address.addressEncoding, 'regtest');
      expect(repeatedAddress.addressEncoding, 'testnet');
      expect(address.ua, isNot(equals(repeatedAddress.ua)));
      expect(address.ua, startsWith('uregtest'));
      expect(repeatedAddress.ua, startsWith('utest'));
      _expectOptionalPrefix(address.sapling, 'zregtestsapling');
      _expectOptionalPrefix(repeatedAddress.sapling, 'ztestsapling');
      _expectOptionalPrefix(address.orchard, 'uregtest');
      _expectOptionalPrefix(address.transparent, 'tm');
      expect(address.transparent, equals(repeatedAddress.transparent));
      expect(
        [
          address.sapling,
          address.orchard,
          address.transparent,
        ].whereType<String>(),
        isNotEmpty,
      );

      final xpub = zcashNativeSeedToTransparentXpub(
        seedHex: _seed,
        network: 'regtest',
      );
      final transparentAddress = zcashNativeTransparentAddress(
        xpub: xpub,
        network: 'regtest',
      );
      expect(xpub, startsWith('tpub'));
      expect(transparentAddress, startsWith('tm'));
      final transparentMetadata = zcashNativeDecodeAddress(
        address: transparentAddress,
        network: 'regtest',
      );
      expect(transparentMetadata.network, ZcashAddressNetwork.regtest);
      expect(transparentMetadata.receiverType, ZcashAddressReceiverType.p2pkh);
      expect(transparentMetadata.pool, ZcashAddressPool.transparent);
      expect(transparentMetadata.receivers.transparent, isTrue);

      final saplingSpendingKey = zcashNativeSeedToSaplingSpendingKey(
        seedHex: _seed,
        network: 'regtest',
      );
      final testnetSaplingSpendingKey = zcashNativeSeedToSaplingSpendingKey(
        seedHex: _seed,
        network: 'test',
      );
      expect(saplingSpendingKey, startsWith('secret-extended-key-regtest'));
      expect(testnetSaplingSpendingKey, startsWith('secret-extended-key-test'));
      expect(saplingSpendingKey, isNot(equals(testnetSaplingSpendingKey)));
      expect(saplingSpendingKey, isNot(contains(_seed)));

      final ufvkValidation = zcashNativeValidateKey(
        key: ufvk,
        network: 'regtest',
        keyType: ZcashKeyType.ufvk,
      );
      expect(ufvkValidation.valid, isTrue);
      expect(ufvkValidation.network, ZcashAddressNetwork.regtest);
      expect(ufvkValidation.components!.sapling, isTrue);

      final regtestSkValidation = zcashNativeValidateKey(
        key: saplingSpendingKey,
        network: 'regtest',
        keyType: ZcashKeyType.saplingExtendedSpendingKey,
      );
      expect(regtestSkValidation.valid, isTrue);
      expect(regtestSkValidation.toJson().toString(), isNot(contains(_seed)));

      final wrongNetworkSk = zcashNativeValidateKey(
        key: saplingSpendingKey,
        network: 'test',
        keyType: ZcashKeyType.saplingExtendedSpendingKey,
      );
      expect(wrongNetworkSk.valid, isFalse);
      expect(wrongNetworkSk.reason, ZcashKeyValidationReason.wrongNetwork);

      final xpubValidation = zcashNativeValidateKey(
        key: xpub,
        network: 'regtest',
        keyType: ZcashKeyType.transparentXpub,
      );
      expect(xpubValidation.valid, isTrue);
    });

    test('scanner returns zero-note summary through native assets', () {
      final ufvk = zcashNativeSeedToAccountUfvk(
        seedHex: _seed,
        network: 'regtest',
      );

      final result = zcashNativeScanCompactBlocks(
        ufvk: ufvk,
        network: 'regtest',
        blocks: const [],
      );

      expect(result.scannedBlocks, 0);
      expect(result.discoveredNotes, 0);
      expect(result.notes, isEmpty);
    });

    test('scanner converts native-assets errors consistently', () {
      const secretUfvk = 'uviewtest-secret-that-must-not-leak';
      expect(
        () => zcashNativeScanCompactBlocks(
          ufvk: secretUfvk,
          network: 'not-a-network',
          blocks: const <CompactBlockScanInput>[],
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('unsupported_network'), isNot(contains(secretUfvk))),
          ),
        ),
      );
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

void _expectOptionalPrefix(String? value, String prefix) {
  if (value == null) {
    return;
  }
  expect(value, startsWith(prefix));
}
