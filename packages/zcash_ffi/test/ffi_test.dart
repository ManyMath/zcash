@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zcash_ffi/zcash_ffi.dart';

const _seed =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'
    '202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f';

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
      test('deriveAddress returns correct mainnet UA', () async {
        final set = await deriveAddress(
          seedHex: _seed,
          network: ZcashNetwork.mainnet,
        );
        expect(set.ua, equals(_expectedMainnetUa));
        expect(set.saplingAddress, equals(_expectedMainnetSapling));
        expect(set.transparentAddress, equals(_expectedMainnetTAddr));
      });

      test(
        'deriveNativeViewingKeys returns read-only viewing-key metadata',
        () {
          final keys = deriveNativeViewingKeys(
            seedHex: _seed,
            network: ZcashNetwork.mainnet,
          );

          expect(keys.network, ZcashAddressNetwork.mainnet);
          expect(keys.accountIndex, 0);
          expect(keys.hasTransparent, isTrue);
          expect(keys.hasSapling, isTrue);
          expect(keys.hasOrchard, isTrue);
          expect(keys.transparent.externalIvk, hasLength(130));
          expect(keys.transparent.internalIvk, hasLength(130));
          expect(
            keys.transparent.externalIvk,
            isNot(equals(keys.transparent.internalIvk)),
          );
          expect(keys.transparent.defaultExternalAddress, startsWith('t1'));
          expect(keys.transparent.defaultExternalIndex, 0);
          expect(keys.sapling.defaultAddress, startsWith('zs1'));
          expect(keys.toJson().toString(), isNot(contains(_seed)));
          expect(keys.toJson().toString(), isNot(contains('secret-')));
        },
      );

      test('deriveNativeViewingKeys account indices differ', () {
        final account0 = deriveNativeViewingKeys(
          seedHex: _seed,
          network: ZcashNetwork.mainnet,
        );
        final account1 = deriveNativeViewingKeys(
          seedHex: _seed,
          network: ZcashNetwork.mainnet,
          accountIndex: 1,
        );
        expect(
          account0.transparent.externalIvk,
          isNot(equals(account1.transparent.externalIvk)),
        );
        expect(
          account0.sapling.defaultAddress,
          isNot(equals(account1.sapling.defaultAddress)),
        );
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

      test(
        'deriveSaplingSpendingKey returns deterministic zcashd import key',
        () async {
          final key = await deriveSaplingSpendingKey(
            seedHex: _seed,
            network: ZcashNetwork.testnet,
          );
          final repeated = await deriveSaplingSpendingKey(
            seedHex: _seed,
            network: ZcashNetwork.testnet,
          );
          expect(key, equals(repeated));
          expect(key, startsWith('secret-extended-key-test'));
          expect(key, isNot(contains(_seed)));
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

  group(
    'FFI sapling transaction build (experimental gate)',
    skip: _libAvailable ? false : 'ZCASH_FFI_LIB not set',
    () {
      const seedHex =
          '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'
          '202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f';
      const spendNotes = [SaplingBuildSpendNote(valueZatoshis: 100000)];
      const outputs = [
        SaplingBuildOutput(
          address: 'tmEgiuT9b9XHFTGqMHQ7gK6yY6JhsKqYZ9q',
          valueZatoshis: 90000,
        ),
      ];

      test('throws without explicit experimental opt-in', () {
        expect(
          () => buildNativeSaplingTransaction(
            network: ZcashNetwork.testnet,
            targetHeight: 10,
            feeZatoshis: 10000,
            seedHex: seedHex,
            spendNotes: spendNotes,
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
        'default build reports feature disabled without echoing the seed',
        () {
          expect(
            () => buildNativeSaplingTransaction(
              network: ZcashNetwork.testnet,
              targetHeight: 10,
              feeZatoshis: 10000,
              seedHex: seedHex,
              spendNotes: spendNotes,
              outputs: outputs,
              allowExperimentalSaplingBuild: true,
            ),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'message',
                allOf(
                  contains('experimental_feature_disabled'),
                  isNot(contains(seedHex)),
                ),
              ),
            ),
          );
        },
      );
    },
  );

  group('Sapling build request shape (no FFI)', () {
    final rseedHex = '2a' * 32;
    final anchorHex = '11' * 32;

    test('synthesized spend note encodes only value', () {
      const note = SaplingBuildSpendNote(valueZatoshis: 100000);
      expect(note.isRealNote, isFalse);
      expect(note.toRequestJson(), {'value_zatoshis': 100000});
    });

    test('real spend note encodes recipient/rseed/witness/anchor', () {
      final note = SaplingBuildSpendNote(
        valueZatoshis: 100000,
        recipientAddress: 'zregtestsapling1abc',
        rseedHex: rseedHex,
        witnessHex: 'deadbeef',
        anchorHex: anchorHex,
      );
      expect(note.isRealNote, isTrue);
      expect(note.toRequestJson(), {
        'value_zatoshis': 100000,
        'recipient': 'zregtestsapling1abc',
        'rseed': rseedHex,
        'witness': 'deadbeef',
        'anchor': anchorHex,
      });
    });

    test('partial real spend note is rejected (together-or-neither)', () {
      const note = SaplingBuildSpendNote(
        valueZatoshis: 100000,
        recipientAddress: 'zregtestsapling1abc',
      );
      expect(note.isRealNote, isTrue);
      expect(note.toRequestJson, throwsArgumentError);
    });

    test(
      'a memo rides on the output it is addressed to, and only that one',
      () {
        final json =
            jsonDecode(
                  encodeSaplingBuildRequest(
                    network: 'regtest',
                    targetHeight: 10,
                    seedHex: _seed,
                    spendNotes: const [
                      SaplingBuildSpendNote(valueZatoshis: 100000),
                    ],
                    outputs: const [
                      SaplingBuildOutput(
                        address: 'zregtestsapling1recipient',
                        valueZatoshis: 50000,
                        memoHex: 'deadbeef',
                      ),
                      SaplingBuildOutput(
                        address: 'zregtestsapling1mine',
                        valueZatoshis: 40000,
                      ),
                    ],
                  ),
                )
                as Map<String, Object?>;

        expect(json['outputs'], [
          {
            'address': 'zregtestsapling1recipient',
            'value_zatoshis': 50000,
            'memo': 'deadbeef',
          },
          {'address': 'zregtestsapling1mine', 'value_zatoshis': 40000},
        ]);
      },
    );

    test('encodeSaplingBuildRequest carries real-note fields verbatim', () {
      final json =
          jsonDecode(
                encodeSaplingBuildRequest(
                  network: 'regtest',
                  targetHeight: 10,
                  feeZatoshis: 10000,
                  seedHex: _seed,
                  spendNotes: [
                    SaplingBuildSpendNote(
                      valueZatoshis: 100000,
                      recipientAddress: 'zregtestsapling1abc',
                      rseedHex: rseedHex,
                      witnessHex: 'deadbeef',
                      anchorHex: anchorHex,
                    ),
                  ],
                  outputs: const [
                    SaplingBuildOutput(
                      address: 'zregtestsapling1abc',
                      valueZatoshis: 90000,
                    ),
                  ],
                ),
              )
              as Map<String, Object?>;
      expect(json['sapling_build_version'], saplingBuildRequestVersion);
      final spendNotes = json['spend_notes'] as List<Object?>;
      final note = spendNotes.single as Map<String, Object?>;
      expect(note['recipient'], 'zregtestsapling1abc');
      expect(note['rseed'], rseedHex);
      expect(note['witness'], 'deadbeef');
      expect(note['anchor'], anchorHex);
    });

    test('omits the staged activation height unless it is stated', () {
      final json =
          jsonDecode(
                encodeSaplingBuildRequest(
                  network: 'regtest',
                  targetHeight: 10,
                  feeZatoshis: 10000,
                  seedHex: _seed,
                  spendNotes: const [
                    SaplingBuildSpendNote(valueZatoshis: 100000),
                  ],
                  outputs: const [
                    SaplingBuildOutput(
                      address: 'zregtestsapling1abc',
                      valueZatoshis: 90000,
                    ),
                  ],
                ),
              )
              as Map<String, Object?>;
      expect(json.containsKey('regtest_nu63_activation_height'), isFalse);
    });

    test('a shielding request carries inputs and no spend notes', () {
      final json =
          jsonDecode(
                encodeSaplingBuildRequest(
                  network: 'regtest',
                  targetHeight: 140,
                  feeZatoshis: 15000,
                  seedHex: _seed,
                  inputs: const [
                    TransparentBuildInput(
                      txid: '33',
                      vout: 0,
                      valueZatoshis: 100000,
                      secretKeyHex: '11',
                    ),
                  ],
                  outputs: const [
                    SaplingBuildOutput(
                      address: 'zregtestsapling1abc',
                      valueZatoshis: 85000,
                    ),
                  ],
                ),
              )
              as Map<String, Object?>;
      expect(json['spend_notes'], isEmpty);
      final inputs = json['inputs'] as List<Object?>;
      final input = inputs.single as Map<String, Object?>;
      expect(input['txid'], '33');
      expect(input['vout'], 0);
      expect(input['value_zatoshis'], 100000);
      expect(input['secret_key'], '11');
    });

    test('a quote request omits the fee and asks for the remainder', () {
      final json =
          jsonDecode(
                encodeSaplingBuildRequest(
                  network: 'regtest',
                  targetHeight: 140,
                  quoteOnly: true,
                  seedHex: _seed,
                  inputs: const [
                    TransparentBuildInput(
                      txid: '33',
                      vout: 0,
                      valueZatoshis: 100000,
                      secretKeyHex: '11',
                    ),
                  ],
                  outputs: const [
                    SaplingBuildOutput(address: 'zregtestsapling1abc'),
                  ],
                ),
              )
              as Map<String, Object?>;
      expect(json['quote_only'], isTrue);
      expect(json.containsKey('fee_zatoshis'), isFalse);
      final outputs = json['outputs'] as List<Object?>;
      final output = outputs.single as Map<String, Object?>;
      expect(output['address'], 'zregtestsapling1abc');
      expect(
        output.containsKey('value_zatoshis'),
        isFalse,
        reason: 'an absent value is what asks for the remainder',
      );
    });

    test('a build request still states its fee when the caller states one', () {
      final json =
          jsonDecode(
                encodeSaplingBuildRequest(
                  network: 'regtest',
                  targetHeight: 140,
                  feeZatoshis: 20000,
                  seedHex: _seed,
                  spendNotes: const [
                    SaplingBuildSpendNote(valueZatoshis: 100000),
                  ],
                  outputs: const [
                    SaplingBuildOutput(
                      address: 'zregtestsapling1abc',
                      valueZatoshis: 80000,
                    ),
                  ],
                ),
              )
              as Map<String, Object?>;
      expect(json['fee_zatoshis'], 20000);
      expect(json.containsKey('quote_only'), isFalse);
    });

    test('quoting refuses without the experimental opt-in', () {
      expect(
        () => quoteNativeSaplingFee(
          network: ZcashNetwork.regtest,
          targetHeight: 140,
          seedHex: _seed,
          inputs: [
            TransparentBuildInput(
              txid: '33',
              vout: 0,
              valueZatoshis: 100000,
              secretKeyHex: '11' * 32,
            ),
          ],
          outputs: const [SaplingBuildOutput(address: 'zregtestsapling1abc')],
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('allowExperimentalSaplingBuild'),
              contains('sapling-spend-build'),
              isNot(contains('11' * 32)),
            ),
          ),
        ),
      );
    });

    test('a scanned note becomes a spend input with three components', () {
      final note = ZcashScannedNote(
        height: 200,
        tx: 'aa' * 32,
        output: 0,
        value: 100000,
        pool: 'sapling',
        nullifier: 'ab' * 32,
        commitmentPosition: 0,
        isChange: false,
        recipient: 'zregtestsapling1example',
        rseed: '11' * 32,
        witness: '33' * 40,
      );
      final spend = SaplingBuildSpendNote.fromScannedNote(
        note,
        anchorHex: '44' * 32,
      ).toRequestJson();

      expect(spend['value_zatoshis'], 100000);
      expect(spend['recipient'], 'zregtestsapling1example');
      expect(spend['rseed'], '11' * 32);
      expect(spend['witness'], '33' * 40);
      expect(spend['anchor'], '44' * 32);
    });

    test('a note from another pool is not a Sapling spend input', () {
      final note = ZcashScannedNote(
        height: 200,
        tx: 'aa' * 32,
        output: 0,
        value: 100000,
        pool: 'ironwood',
        nullifier: 'ab' * 32,
        commitmentPosition: 0,
        isChange: false,
        recipient: 'uregtest1example',
        rseed: '11' * 32,
        rho: '22' * 32,
        noteVersion: 'v3',
        witness: '33' * 40,
      );
      expect(
        () => SaplingBuildSpendNote.fromScannedNote(note, anchorHex: '44' * 32),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a note with no witness cannot be spent yet', () {
      final note = ZcashScannedNote(
        height: 200,
        tx: 'aa' * 32,
        output: 0,
        value: 100000,
        pool: 'sapling',
        nullifier: 'ab' * 32,
        commitmentPosition: 0,
        isChange: false,
        recipient: 'zregtestsapling1example',
        rseed: '11' * 32,
      );
      expect(
        () => SaplingBuildSpendNote.fromScannedNote(note, anchorHex: '44' * 32),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message.toString(),
            'message',
            contains('includeSaplingWitnesses'),
          ),
        ),
      );
    });

    test('carries the staged activation height when it is stated', () {
      final json =
          jsonDecode(
                encodeSaplingBuildRequest(
                  network: 'regtest',
                  targetHeight: 140,
                  feeZatoshis: 10000,
                  seedHex: _seed,
                  spendNotes: const [
                    SaplingBuildSpendNote(valueZatoshis: 100000),
                  ],
                  outputs: const [
                    SaplingBuildOutput(
                      address: 'zregtestsapling1abc',
                      valueZatoshis: 90000,
                    ),
                  ],
                  regtestNu63ActivationHeight: 130,
                ),
              )
              as Map<String, Object?>;
      expect(json['regtest_nu63_activation_height'], 130);
    });
  });

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

  group(
    'regtest reaches the native layer',
    skip: _libAvailable ? false : 'ZCASH_FFI_LIB not set',
    () {
      test('derives regtest-encoded addresses distinct from testnet', () async {
        final regtest = await deriveAddress(
          seedHex: _seed,
          network: ZcashNetwork.regtest,
        );
        final testnet = await deriveAddress(
          seedHex: _seed,
          network: ZcashNetwork.testnet,
        );

        expect(regtest.addressEncoding, 'regtest');
        expect(testnet.addressEncoding, 'testnet');
        expect(regtest.ua, startsWith('uregtest'));
        expect(testnet.ua, startsWith('utest'));
        expect(regtest.saplingAddress, startsWith('zregtestsapling'));

        expect(regtest.ua, isNot(equals(testnet.ua)));
        expect(regtest.transparentAddress, equals(testnet.transparentAddress));
      });

      test(
        'a regtest UA decodes under regtest and not under testnet',
        () async {
          final regtest = await deriveAddress(
            seedHex: _seed,
            network: ZcashNetwork.regtest,
          );

          expect(
            decodeNativeAddress(
              address: regtest.ua,
              network: ZcashNetwork.regtest,
            ).network,
            ZcashAddressNetwork.regtest,
          );
          expect(isValidAddress(regtest.ua, ZcashNetwork.regtest), isTrue);
          expect(isValidAddress(regtest.ua, ZcashNetwork.testnet), isFalse);
        },
      );
    },
  );
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
