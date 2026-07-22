@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zcash_ffi/zcash_ffi.dart';

const _expectedMainnetTAddr = 't1c8oqrzA1kYPdgVhfDNUZn3buAbk6rXxiX';
const _expectedMainnetSapling =
    'zs1zt3mq96vp65l8ch54r78nc50ml68qsyg3pkteq8pn8sfgzakhgw4vqn6px5w08hrf2uzuam5kmj';
const _expectedMainnetUa =
    'u1tcw2tuatlzdc4ncep4nef7v9h5q87jx7t4fzyj7sw5g6775u3fwkucjafgsl2dg6h3hfjtml85ggqakl5mf2c746ygk7qnp8kyhentqkcnpqwarfcceczd0drzuvtxaeak9kadkwp6sn5xpj40cwmpjcu8aqy6v8rueum0h9mvefhhfytvrq2dcwxsx4cdk7uzv99yhspftg72ut509';
const _p2pkhScriptHex = '76a914040404040404040404040404040404040404040488ac';
const _p2shScriptHex = 'a914070707070707070707070707070707070707070787';

bool get _libAvailable =>
    (Platform.environment['ZCASH_FFI_LIB'] ?? '').isNotEmpty;

void main() {
  group(
    'FFI address utilities',
    skip: _libAvailable ? false : 'ZCASH_FFI_LIB not set',
    () {

      test('classifyAddress transparent', () {
        expect(classifyAddress(_expectedMainnetTAddr), AddressType.transparent);
      });

      test('classifyAddress sapling', () {
        expect(classifyAddress(_expectedMainnetSapling), AddressType.sapling);
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

      test('decodeNativeAddress returns structured transparent metadata', () {
        final metadata = decodeNativeAddress(
          address: _expectedMainnetTAddr,
          network: ZcashNetwork.mainnet,
        );

        expect(metadata.network, ZcashAddressNetwork.mainnet);
        expect(metadata.receiverType, ZcashAddressReceiverType.p2pkh);
        expect(metadata.pool, ZcashAddressPool.transparent);
        expect(metadata.receivers.transparent, isTrue);
        expect(metadata.receivers.transparentKind, 'p2pkh');
        expect(metadata.receivers.total, 1);
      });

      test('decodeNativeAddress returns structured unified metadata', () {
        final metadata = decodeNativeAddress(
          address: _expectedMainnetUa,
          network: ZcashNetwork.mainnet,
        );

        expect(metadata.network, ZcashAddressNetwork.mainnet);
        expect(metadata.receiverType, ZcashAddressReceiverType.unified);
        expect(metadata.pool, ZcashAddressPool.mixed);
        expect(metadata.receivers.orchard, isTrue);
        expect(metadata.receivers.sapling, isTrue);
        expect(metadata.receivers.transparent, isTrue);
        expect(metadata.receivers.total, 3);
      });

      test('inventoryUnifiedAddressReceivers returns receiver kinds', () {
        final inventory = inventoryUnifiedAddressReceivers(
          address: _expectedMainnetUa,
          network: ZcashNetwork.mainnet,
        );

        expect(inventory.network, ZcashAddressNetwork.mainnet);
        expect(inventory.receiverCount, 3);
        expect(inventory.counts.orchard, 1);
        expect(inventory.counts.sapling, 1);
        expect(inventory.counts.transparent, 1);
        expect(inventory.counts.p2pkh, 1);
        expect(inventory.counts.unknown, 0);
        expect(
          inventory.receivers.map((receiver) => receiver.kind),
          containsAll([
            ZcashAddressReceiverType.orchard,
            ZcashAddressReceiverType.sapling,
            ZcashAddressReceiverType.p2pkh,
          ]),
        );
      });

      test('classifyNativeTransparentAddress returns p2pkh metadata', () {
        final classification = classifyNativeTransparentAddress(
          address: _expectedMainnetTAddr,
          network: ZcashNetwork.mainnet,
        );

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
      });

      test(
        'classifyNativeTransparentScript returns p2pkh and p2sh metadata',
        () {
          final p2pkh = classifyNativeTransparentScript(
            scriptHex: _p2pkhScriptHex,
          );
          expect(p2pkh.network, isNull);
          expect(p2pkh.inputType, ZcashTransparentClassificationInput.script);
          expect(p2pkh.kind, ZcashTransparentClassificationKind.p2pkh);
          expect(p2pkh.pool, ZcashAddressPool.transparent);
          expect(p2pkh.standard, isTrue);
          expect(p2pkh.scriptSize, 25);

          final p2sh = classifyNativeTransparentScript(
            scriptHex: _p2shScriptHex,
          );
          expect(p2sh.kind, ZcashTransparentClassificationKind.p2sh);
          expect(p2sh.scriptSize, 23);
        },
      );

      test('classifyNativeTransparentScript reports non-standard scripts', () {
        final classification = classifyNativeTransparentScript(scriptHex: '6a');

        expect(
          classification.kind,
          ZcashTransparentClassificationKind.nonStandard,
        );
        expect(classification.pool, ZcashAddressPool.unknown);
        expect(classification.standard, isFalse);
        expect(classification.transparent, isFalse);
        expect(classification.scriptSize, 1);
      });

      test(
        'inventoryUnifiedAddressReceivers rejects non-UA without address echo',
        () {
          expect(
            () => inventoryUnifiedAddressReceivers(
              address: _expectedMainnetSapling,
              network: ZcashNetwork.mainnet,
            ),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'message',
                allOf(
                  contains('not_unified_address'),
                  isNot(contains(_expectedMainnetSapling)),
                ),
              ),
            ),
          );
        },
      );

      test(
        'classifyNativeTransparentAddress rejects wrong network without echo',
        () {
          expect(
            () => classifyNativeTransparentAddress(
              address: _expectedMainnetTAddr,
              network: ZcashNetwork.testnet,
            ),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'message',
                allOf(
                  contains('wrong_network'),
                  isNot(contains(_expectedMainnetTAddr)),
                ),
              ),
            ),
          );
        },
      );

      test(
        'classifyNativeTransparentScript rejects malformed hex without echo',
        () {
          const scriptHex = 'not-hex-user-input';

          expect(
            () => classifyNativeTransparentScript(scriptHex: scriptHex),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'message',
                allOf(contains('invalid_hex'), isNot(contains(scriptHex))),
              ),
            ),
          );
        },
      );

      test('nativeNetworkConstants returns mainnet consensus constants', () {
        final constants = nativeNetworkConstants(network: 'main');

        expect(constants.network, ZcashConsensusNetwork.mainnet);
        expect(constants.coinType, 133);
        expect(constants.zatoshisPerZec, 100000000);
        expect(constants.maxMoneyZatoshis, 2100000000000000);
        expect(constants.coinbaseMaturityBlocks, 100);
        expect(constants.addressPrefixes.saplingPaymentAddressHrp, 'zs');
        expect(constants.addressPrefixes.unifiedAddressHrp, 'u');
        expect(constants.addressPrefixes.transparentPubkeyAddressB58Prefix, [
          0x1c,
          0xb8,
        ]);
        expect(constants.activationByName('Sapling')?.activationHeight, 419200);
        expect(constants.activationByName('Sapling')?.branchId, '76b809bb');
      });

      test(
        'nativeNetworkConstants exposes regtest constants without schedule',
        () {
          final constants = nativeNetworkConstants(network: 'regtest');

          expect(constants.network, ZcashConsensusNetwork.regtest);
          expect(constants.coinType, 1);
          expect(
            constants.addressPrefixes.saplingPaymentAddressHrp,
            'zregtestsapling',
          );
          expect(constants.addressPrefixes.unifiedAddressHrp, 'uregtest');
          expect(constants.activationHeights, isEmpty);
        },
      );

      test(
        'nativeNetworkConstants rejects unsupported network without echo',
        () {
          const network = 'devnet-with-user-input';

          expect(
            () => nativeNetworkConstants(network: network),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'message',
                allOf(
                  contains('unsupported_network'),
                  isNot(contains(network)),
                ),
              ),
            ),
          );
        },
      );

      test(
        'decodeNativeAddress rejects wrong network without address echo',
        () {
          expect(
            () => decodeNativeAddress(
              address: _expectedMainnetTAddr,
              network: ZcashNetwork.testnet,
            ),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'message',
                allOf(
                  contains('wrong_network'),
                  isNot(contains(_expectedMainnetTAddr)),
                ),
              ),
            ),
          );
        },
      );

      test('seedToSaplingSpendingKey returns sanitized JSON errors', () {
        final raw = ZcashFfiBindings.instance.seedToSaplingSpendingKey(
          '000102',
          'test',
          0,
        );
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        expect(decoded['error'], contains('seed must be at least 32 bytes'));
        expect(raw, isNot(contains('000102')));
      });

      test('seedToAccountMetadata returns sanitized JSON errors', () {
        final raw = ZcashFfiBindings.instance.seedToAccountMetadata(
          '000102',
          'test',
          0,
        );
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        expect(decoded['category'], 'invalid_seed');
        expect(decoded['error'], contains('seed must be at least 32 bytes'));
        expect(raw, isNot(contains('000102')));
      });
    },
  );

  group(
    'FFI bindings version',
    skip: _libAvailable ? false : 'ZCASH_FFI_LIB not set',
    () {
      test('version is semver', () {
        final v = ZcashFfiBindings.instance.version();
        expect(v, matches(RegExp(r'^\d+\.\d+\.\d+')));
      });
    },
  );

  group(
    'FFI Equihash solver',
    skip: _libAvailable ? false : 'ZCASH_FFI_LIB not set',
    () {
      test('solveEquihash returns 32-byte nonce and 1344-byte solution', () {
        final header = Uint8List.fromList(List<int>.generate(108, (i) => i));
        final result = solveEquihash(header);
        expect(result.nonce, hasLength(32));
        expect(result.solution, hasLength(1344));
      });
    },
  );

  group(
    'FFI transaction decode',
    skip: _libAvailable ? false : 'ZCASH_FFI_LIB not set',
    () {
      test('decodeNativeTransaction summarizes a v5 transparent tx', () {
        final summary = decodeNativeTransaction(
          txHex: _v5TransparentTxHex,
          network: ZcashNetwork.testnet,
        );
        expect(summary.network, ZcashAddressNetwork.testnet);
        expect(summary.version, ZcashTransactionVersion.v5);
        expect(summary.txid, equals(_v5TransparentTxid));
        expect(summary.consensusBranchId, equals('nu5'));
        expect(summary.consensusBranchIdHex, equals('c2d6d0b4'));
        expect(summary.transparent.present, isTrue);
        expect(summary.transparent.vin, 1);
        expect(summary.transparent.vout, 2);
        expect(summary.sapling.present, isFalse);
        expect(summary.orchard.present, isFalse);
        expect(summary.sprout.present, isFalse);
      });

      test('decodeNativeTransaction reports null branch for a v4 tx', () {
        final summary = decodeNativeTransaction(
          txHex: _v4EmptyTxHex,
          network: ZcashNetwork.mainnet,
        );
        expect(summary.version, ZcashTransactionVersion.v4);
        expect(summary.txid, equals(_v4EmptyTxid));
        expect(summary.consensusBranchId, isNull);
        expect(summary.consensusBranchIdHex, isNull);
      });

      test('decodeNativeTransaction rejects malformed hex without echo', () {
        const bad = 'nothexzz';
        expect(
          () => decodeNativeTransaction(
            txHex: bad,
            network: ZcashNetwork.mainnet,
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              allOf(contains('invalid_hex'), isNot(contains(bad))),
            ),
          ),
        );
      });

      test('decodeNativeTransaction rejects garbage bytes without echo', () {
        const garbage = 'deadbeef';
        expect(
          () => decodeNativeTransaction(
            txHex: garbage,
            network: ZcashNetwork.mainnet,
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              allOf(contains('invalid_transaction'), isNot(contains(garbage))),
            ),
          ),
        );
      });

      test('zcashNativeDecodeTransaction accepts regtest network', () {
        final summary = zcashNativeDecodeTransaction(
          txHex: _v5TransparentTxHex,
          network: 'regtest',
        );
        expect(summary.network, ZcashAddressNetwork.regtest);
        expect(summary.version, ZcashTransactionVersion.v5);
        expect(summary.transparent.vout, 2);
      });

      test('transactionTxid returns txid and v5 auth digest', () {
        final id = transactionTxid(txHex: _v5TransparentTxHex);
        expect(id.txid, equals(_v5TransparentTxid));
        expect(id.authDigest, equals(_v5TransparentAuthDigest));
      });

      test('transactionTxid reports null auth digest for a v4 tx', () {
        final id = transactionTxid(txHex: _v4EmptyTxHex);
        expect(id.txid, equals(_v4EmptyTxid));
        expect(id.authDigest, isNull);
      });

      test('zcashNativeTransactionTxid matches the DynamicLibrary path', () {
        final id = zcashNativeTransactionTxid(txHex: _v5TransparentTxHex);
        expect(id.txid, equals(_v5TransparentTxid));
        expect(id.authDigest, equals(_v5TransparentAuthDigest));
      });

      test('transactionTxid rejects malformed hex without echo', () {
        const bad = 'nothexzz';
        expect(
          () => transactionTxid(txHex: bad),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              allOf(contains('invalid_hex'), isNot(contains(bad))),
            ),
          ),
        );
      });
    },
  );

  group(
    'FFI transparent transaction build (experimental gate)',
    skip: _libAvailable ? false : 'ZCASH_FFI_LIB not set',
    () {
      const secretKey =
          '1111111111111111111111111111111111111111111111111111111111111111';
      final inputs = [
        TransparentBuildInput(
          txid: '22' * 32,
          vout: 0,
          valueZatoshis: 100000,
          secretKeyHex: secretKey,
        ),
      ];
      const outputs = [
        TransparentBuildOutput(
          address: 'tmEgiuT9b9XHFTGqMHQ7gK6yY6JhsKqYZ9q',
          valueZatoshis: 90000,
        ),
      ];

      test('throws without explicit experimental opt-in', () {
        expect(
          () => buildNativeTransparentTransaction(
            network: ZcashNetwork.testnet,
            targetHeight: 10,
            feeZatoshis: 10000,
            inputs: inputs,
            outputs: outputs,
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('experimental'),
            ),
          ),
        );
      });

      test(
        'default build reports feature disabled without echoing the key',
        () {
          expect(
            () => buildNativeTransparentTransaction(
              network: ZcashNetwork.testnet,
              targetHeight: 10,
              feeZatoshis: 10000,
              inputs: inputs,
              outputs: outputs,
              allowExperimentalTransparentBuild: true,
            ),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'message',
                allOf(
                  contains('experimental_feature_disabled'),
                  isNot(contains(secretKey)),
                ),
              ),
            ),
          );
        },
      );
    },
  );

  group('ZcashNetwork', () {
    test('maps each network to the label the native exports take', () {
      expect(ZcashNetwork.mainnet.ffiLabel, 'main');
      expect(ZcashNetwork.testnet.ffiLabel, 'test');
      expect(ZcashNetwork.regtest.ffiLabel, 'regtest');
      expect(
        ZcashNetwork.values.map((n) => n.ffiLabel).toSet(),
        hasLength(ZcashNetwork.values.length),
        reason: 'no two networks may share a label',
      );
    });
  });
}

// From the crate's Rust decode tests: a v5 with one transparent input and two
// outputs, and an empty v4. Txids are in display order.
const _v5TransparentTxHex =
    '050000800a27a726b4d0d6c20000000000000000010000000000000000000000000000'
    '0000000000000000000000000000000000000000000000ffffffff02e803000000000000'
    '00e80300000000000000000000';
const _v5TransparentTxid =
    'ce9b14d1d12ada71c58f9b17eab6935b30d6e039f73f01e72a0e5a39aae8af6d';
const _v5TransparentAuthDigest =
    '8d713d7b61f8362a98041252eb3d254394d67f5601f05591d3d8b09581e15ba5';
const _v4EmptyTxHex =
    '0400008085202f89000000000000000000000000000000000000000000';
const _v4EmptyTxid =
    'e22daacccd32e2335184e5604d86742609cf4ee106884a0603dbedf736ddd782';
