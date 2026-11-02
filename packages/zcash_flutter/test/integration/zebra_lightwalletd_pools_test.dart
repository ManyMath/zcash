@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';
import 'package:zcash_ffi/zcash_ffi.dart';

import 'harness.dart';
import 'lightwalletd_harness.dart';

// Needs an Ironwood-aware ZEBRA_BIN, a digest-pinned LIGHTWALLETD_DOCKER_IMAGE
// or LIGHTWALLETD_BIN, the Sapling MPC parameters, and a ZCASH_FFI_LIB with
// orchard-tx-build, sapling-spend-build, orchard-note-discovery and
// ironwood-note-discovery.
// ZIP 258 closes Orchard at NU6.3, so the Orchard note is made below it.
void main() {
  // The height-1 coinbase matures at 101; NU6.3 is staged at 130.
  const nu63Activation = 130;
  const maturityHeight = 101;

  final ffiLib = Platform.environment['ZCASH_FFI_LIB'] ?? '';
  final spendParams = Platform.environment['ZCASH_SAPLING_SPEND_PARAMS'] ?? '';
  final outputParams =
      Platform.environment['ZCASH_SAPLING_OUTPUT_PARAMS'] ?? '';
  final enabled =
      Platform.environment.containsKey('ZEBRA_INTEGRATION') &&
      Platform.environment.containsKey('LIGHTWALLETD_INTEGRATION') &&
      ffiLib.isNotEmpty &&
      spendParams.isNotEmpty &&
      outputParams.isNotEmpty;

  ZebraHarness? harness;
  LightwalletdHarness? lightwalletd;
  ZcashFfiBindings? ffi;
  int? orchardHeight;
  int? orchardValue;
  int? saplingHeight;
  int? saplingValue;
  String? walletDocument;
  int? preRestartHeight;
  int? preRestartTrailLow;
  ZcashWalletSyncState? reopened;
  ZcashChainSync? reopenedSync;
  String? abandonedSaplingTxid;
  AddressUtxo? saplingCoin;
  String? replacementSaplingTxid;
  int? replacementSaplingValue;

  ZcashChainSync syncFor(ZcashWalletSyncState wallet) =>
      openNativeLightwalletdSync(
        client: lightwalletd!.client,
        wallet: wallet,
        ufvk: _regtestScanUfvk(ffiLib),
        network: ZcashNetwork.regtest,
        allowExperimentalOrchardNotes: true,
        rangeSize: 10,
        bindings: ffi,
        nodeCommitmentTreeSizes: (height) async {
          final converted = await _convert(
            harness!,
            ffi!,
            nu63Activation,
            start: height,
            end: height,
          );
          return ZcashCommitmentTreeSizes(
            sapling: converted.saplingCommitmentTreeSize,
            orchard: converted.orchardCommitmentTreeSize,
            ironwood: converted.ironwoodCommitmentTreeSize,
          );
        },
      );

  setUpAll(() async {
    if (!enabled) return;
    ffi = ZcashFfiBindings.open(ffiLib);
    harness = await ZebraHarness.start(
      nu63ActivationHeight: nu63Activation,
      minerAddress: kIronwoodProofMinerAddress,
    );
    await harness!.mineBlocks(maturityHeight);
    lightwalletd = await LightwalletdHarness.start(
      backend: LightwalletdBackend.zebra(rpcPort: harness!.rpcPort),
    );
  });

  tearDownAll(() async {
    final lwd = lightwalletd;
    lightwalletd = null;
    if (lwd != null) await lwd.shutdown();
    final z = harness;
    harness = null;
    if (z != null) await z.shutdown();
  });

  group(
    'Live Sapling and Orchard discovery through lightwalletd',
    () {
      test('an Orchard note is created below activation', () async {
        if (harness == null) return;

        final tip = await harness!.client.getBlockCount();
        expect(
          tip,
          lessThan(nu63Activation),
          reason:
              'ZIP 258 closes the Orchard pool at NU6.3, so this is the only '
              'side of the chain where an Orchard note can be made at all',
        );

        final coin = await _matureCoinbase(harness!, tip);
        final treeState = await harness!.client.getTreeState('$tip');
        final built = buildNativeOrchardTransaction(
          network: ZcashNetwork.regtest,
          targetHeight: tip + 1,
          regtestNu63ActivationHeight: nu63Activation,
          anchor: OrchardAnchorSource.tree(treeState.orchard?.finalState ?? ''),
          inputs: [
            TransparentBuildInput(
              txid: coin.txid,
              vout: coin.outputIndex,
              valueZatoshis: coin.satoshis,
              secretKeyHex: kIronwoodProofMinerSecretKeyHex,
            ),
          ],
          orchardOutput: const OrchardBuildOutput(
            address: kIronwoodProofUnifiedAddress,
          ),
          allowExperimentalOrchardBuild: true,
          bindings: ffi,
        );
        expect(built.consensusBranchId, 'nu6.2');

        final txid = await harness!.client.sendRawTransaction(
          built.transactionHex,
        );
        final hash = (await harness!.mineBlocks(1)).single;
        expect(
          (await harness!.client.getBlock(hash)).transactions,
          contains(txid),
        );

        orchardHeight = await harness!.client.getBlockCount();
        orchardValue = built.orchardOutputZatoshis;
        expect(orchardValue, greaterThan(0));
      });

      test('a Sapling note is created above activation', () async {
        if (harness == null || orchardHeight == null) return;

        await _mineTo(harness!, nu63Activation + 2);
        final tip = await harness!.client.getBlockCount();
        final coin = await _matureCoinbase(harness!, tip);
        saplingCoin = coin;
        final built = buildNativeSaplingTransaction(
          network: ZcashNetwork.regtest,
          targetHeight: tip + 1,
          regtestNu63ActivationHeight: nu63Activation,
          seedHex: _testSeedHex,
          inputs: [
            TransparentBuildInput(
              txid: coin.txid,
              vout: coin.outputIndex,
              valueZatoshis: coin.satoshis,
              secretKeyHex: kIronwoodProofMinerSecretKeyHex,
            ),
          ],
          outputs: [SaplingBuildOutput(address: _saplingAddress(ffiLib))],
          spendParamsPath: spendParams,
          outputParamsPath: outputParams,
          allowExperimentalSaplingBuild: true,
          bindings: ffi,
        );
        expect(built.consensusBranchId, 'nu6.3');
        expect(
          built.hasRealProofs,
          isTrue,
          reason:
              'the mock prover\'s all-zero proofs are rejected by a node, '
              'and there would then be no Sapling note to discover',
        );

        final txid = await harness!.client.sendRawTransaction(
          built.transactionHex,
        );
        final hash = (await harness!.mineBlocks(1)).single;
        expect(
          (await harness!.client.getBlock(hash)).transactions,
          contains(txid),
        );

        saplingHeight = await harness!.client.getBlockCount();
        saplingValue = built.totalOutputZatoshis;
        expect(saplingValue, greaterThan(0));

        await lightwalletd!.waitForSyncHeight(
          saplingHeight!,
          readBackendHeight: harness!.client.getBlockCount,
        );
      });

      test('the server carries the Orchard fields the node does', () async {
        if (harness == null || saplingHeight == null) return;

        final served = await _fetchRange(
          lightwalletd!,
          start: orchardHeight!,
          end: orchardHeight!,
        );
        final converted = await _convert(
          harness!,
          ffi!,
          nu63Activation,
          start: orchardHeight!,
          end: orchardHeight!,
        );

        expect(converted.blocks.single.orchardActions, greaterThan(0));
        expect(served.orchardActions, converted.blocks.single.orchardActions);
        expect(
          served.orchardCommitmentTreeSize,
          converted.orchardCommitmentTreeSize,
        );
        expect(
          () => served.requireOrchardParity(
            nodeOrchardCommitmentTreeSize: converted.orchardCommitmentTreeSize,
          ),
          returnsNormally,
        );

        expect(served.ironwoodActions, 0);
      });

      test('the server carries the Sapling fields the node does', () async {
        if (harness == null || saplingHeight == null) return;

        final served = await _fetchRange(
          lightwalletd!,
          start: saplingHeight!,
          end: saplingHeight!,
        );
        final converted = await _convert(
          harness!,
          ffi!,
          nu63Activation,
          start: saplingHeight!,
          end: saplingHeight!,
        );

        expect(converted.blocks.single.saplingOutputs, greaterThan(0));
        expect(served.saplingOutputs, converted.blocks.single.saplingOutputs);
        expect(
          served.saplingCommitmentTreeSize,
          converted.saplingCommitmentTreeSize,
        );
        expect(
          () => served.requireSaplingParity(
            nodeSaplingCommitmentTreeSize: converted.saplingCommitmentTreeSize,
          ),
          returnsNormally,
        );
      });

      test(
        'both notes are found by syncing the range that holds them',
        () async {
          if (harness == null || saplingHeight == null) return;

          final cursor = ZcashLightwalletdSyncCursor.fromTreeState(
            await harness!.client.getTreeState('${orchardHeight! - 1}'),
          );
          final served = await _fetchRange(
            lightwalletd!,
            start: orchardHeight!,
            end: saplingHeight!,
          );
          final scanned = _scan(
            ffi!,
            ffiLib,
            cursor.scanInputFor(
              served,
              network: 'regtest',
              includeSaplingWitnesses: true,
              includeOrchardWitnesses: true,
            ),
          );

          final orchard = scanned.notes.singleWhere((n) => n.pool == 'orchard');
          expect(orchard.value, orchardValue);
          expect(orchard.height, orchardHeight);
          expect(orchard.witness, isNotNull);

          final sapling = scanned.notes.singleWhere((n) => n.pool == 'sapling');
          expect(sapling.value, saplingValue);
          expect(sapling.height, saplingHeight);
          expect(sapling.witness, isNotNull);

          expect(
            scanned.notes.where((n) => n.pool == 'ironwood'),
            isEmpty,
            reason:
                'nothing on this chain made an Ironwood note, and a scan that '
                'reported one would be reading the Orchard field twice',
          );
          expect(
            scanned.saplingAnchor,
            isNot(scanned.orchardAnchor),
            reason: 'two pools, two trees, two roots',
          );
        },
      );

      test('the two sources agree note for note, in both pools', () async {
        if (harness == null || saplingHeight == null) return;

        final cursor = ZcashLightwalletdSyncCursor.fromTreeState(
          await harness!.client.getTreeState('${orchardHeight! - 1}'),
        );
        final served = await _fetchRange(
          lightwalletd!,
          start: orchardHeight!,
          end: saplingHeight!,
        );
        final fromServer = _scan(
          ffi!,
          ffiLib,
          cursor.scanInputFor(
            served,
            network: 'regtest',
            includeSaplingWitnesses: true,
            includeOrchardWitnesses: true,
          ),
        );

        final converted = await _convert(
          harness!,
          ffi!,
          nu63Activation,
          start: orchardHeight!,
          end: saplingHeight!,
        );
        final fromNode = ZcashScanResult.fromJson(
          _nativeOk(
            ffi!.scanCompactBlocksRaw(
              _regtestScanUfvk(ffiLib),
              'regtest',
              jsonEncode({
                'include_sapling_witnesses': true,
                'include_orchard_witnesses': true,
                'blocks': converted.toScanEntries(),
              }),
            ),
          ),
          allowExperimentalOrchardNotes: true,
        );

        List<String> fingerprint(ZcashScanResult r) =>
            [for (final n in r.notes) '${n.pool}:${n.height}:${n.value}']
              ..sort();

        expect(fingerprint(fromServer), fingerprint(fromNode));
        expect(fromServer.saplingAnchor, fromNode.saplingAnchor);
        expect(fromServer.orchardAnchor, fromNode.orchardAnchor);
      });

      test('one call syncs both pools into one wallet', () async {
        if (harness == null || saplingHeight == null) return;

        await harness!.mineBlocks(2);
        final tip = await harness!.client.getBlockCount();
        await lightwalletd!.waitForSyncHeight(
          tip,
          readBackendHeight: harness!.client.getBlockCount,
        );

        final wallet = ZcashWalletSyncState.atBirthday(
          cursor: ZcashLightwalletdSyncCursor.fromTreeState(
            treeStateFromLightwalletd(
              await lightwalletd!.client.getTreeStateAtHeight(
                orchardHeight! - 1,
              ),
            ),
          ),
          accountFingerprint: _accountFingerprint,
        );

        final ranges = <CompactBlockScanRange>[];
        final outcome = await syncFor(
          wallet,
        ).syncToTip(onAdvanced: (advanced) => ranges.add(advanced.range));

        expect(outcome, isA<ZcashSyncCaughtUp>());
        expect(ranges.first.start, orchardHeight);
        expect(ranges.last.end, tip);
        expect(wallet.cursor.nextHeight, tip + 1);

        expect(wallet.sapling.coveredThrough, tip);
        expect(wallet.orchard.coveredThrough, tip);
        expect(wallet.ironwood.coveredThrough, tip);

        final sapling = wallet.sapling.notes.single;
        expect(sapling.height, saplingHeight);
        expect(sapling.value, saplingValue);
        final orchard = wallet.orchard.notes.single;
        expect(orchard.height, orchardHeight);
        expect(orchard.value, orchardValue);
        expect(
          wallet.ironwood.notes,
          isEmpty,
          reason:
              'nothing on this chain made an Ironwood note, and a store that '
              'held one would be reading the Orchard field twice',
        );

        final balance = wallet.balance();
        expect(balance.totalZatoshis, saplingValue! + orchardValue!);
        expect(
          balance.spendableZatoshis,
          0,
          reason:
              'a store hands back no witness, so what it answers is what the '
              'wallet has and never what it can spend right now',
        );

        walletDocument = jsonEncode(wallet.toJson());
        preRestartHeight = wallet.cursor.nextHeight;
        preRestartTrailLow = wallet.cursor.trail.lowestHeight;
      }, timeout: const Timeout(Duration(minutes: 5)));

      test('reopening the document is not a rescan, in either pool', () async {
        if (harness == null || walletDocument == null) return;

        final restored = ZcashWalletSyncState.fromJson(
          (jsonDecode(walletDocument!) as Map).cast<String, Object?>(),
        );
        expect(restored.cursor.nextHeight, preRestartHeight);
        expect(restored.sapling.notes.single.value, saplingValue);
        expect(restored.orchard.notes.single.value, orchardValue);
        expect(
          restored.cursor.trail.lowestHeight,
          preRestartTrailLow,
          reason:
              'the trail is the half a getTreeState re-bootstrap cannot '
              'reproduce, and it is the half a reorg is recovered with',
        );

        await harness!.mineBlocks(3);
        final tip = await harness!.client.getBlockCount();
        await lightwalletd!.waitForSyncHeight(
          tip,
          readBackendHeight: harness!.client.getBlockCount,
        );

        final sync = syncFor(restored);
        final ranges = <CompactBlockScanRange>[];
        final outcome = await sync.syncToTip(
          onAdvanced: (advanced) => ranges.add(advanced.range),
        );

        expect(outcome, isA<ZcashSyncCaughtUp>());
        expect(
          ranges.first.start,
          preRestartHeight,
          reason:
              'the reopened wallet asked for the block after the one it had, '
              'not for its birthday',
        );
        expect(restored.cursor.nextHeight, tip + 1);
        expect(
          restored.balance().totalZatoshis,
          saplingValue! + orchardValue!,
          reason: 'and it did not rediscover what it held as new money',
        );

        reopened = restored;
        reopenedSync = sync;
      }, timeout: const Timeout(Duration(minutes: 5)));

      test(
        'a reorg below the restart, in the pool that made the note',
        () async {
          if (harness == null || reopenedSync == null) return;
          final wallet = reopened!;
          final sync = reopenedSync!;

          final preReorgTip = await harness!.client.getBlockCount();
          final abandonedHash = wallet.cursor.trail.hashAt(saplingHeight!);
          expect(abandonedHash, isNotNull);
          final abandonedTxids = (await harness!.client.getBlock(
            await harness!.client.getBlockHash(saplingHeight!),
          )).transactions;
          expect(abandonedTxids, hasLength(2));
          abandonedSaplingTxid = abandonedTxids.last;

          // Same coin, built before invalidating: zebrad re-admits the
          // abandoned tx, so the replacement must double-spend it at once.
          final replacement = _buildSaplingShield(
            ffi!,
            ffiLib,
            nu63Activation,
            coin: saplingCoin!,
            targetHeight: saplingHeight!,
            spendParams: spendParams,
            outputParams: outputParams,
          );
          expect(
            replacement.txid,
            isNot(abandonedSaplingTxid),
            reason: 'a fork has to be given different content, not re-mined',
          );
          await harness!.client.invalidateBlock(
            await harness!.client.getBlockHash(saplingHeight!),
          );
          await harness!.client.sendRawTransaction(replacement.transactionHex);
          expect(
            await harness!.client.getRawMempool(),
            isNot(contains(abandonedSaplingTxid)),
            reason:
                'the replacement spends the abandoned transaction\'s coin, so '
                'the node cannot hold both',
          );
          await harness!.mineBlocks(1);
          expect(await harness!.client.getBlockCount(), saplingHeight);
          replacementSaplingTxid = replacement.txid;
          replacementSaplingValue = replacement.totalOutputZatoshis;

          while (await harness!.client.getBlockCount() <= preReorgTip) {
            await harness!.mineBlocks(2);
          }
          final newTip = await harness!.client.getBlockCount();
          await lightwalletd!.waitForSyncHeight(
            newTip,
            readBackendHeight: harness!.client.getBlockCount,
          );
          await _awaitServedBlockHash(
            lightwalletd!,
            saplingHeight!,
            settled: (hash) => hash != null && hash != abandonedHash,
          );

          final outcome = await sync.step();
          expect(outcome, isA<ZcashSyncReorged>());
          final reorged = outcome as ZcashSyncReorged;
          expect(
            reorged.recovery.forkHeight,
            saplingHeight! - 1,
            reason: 'the last block both chains still hold',
          );
          expect(
            reorged.recovery.forkHeight,
            lessThan(preRestartHeight!),
            reason:
                'below the height the wallet reopened at, so only a persisted '
                'trail reaches it',
          );

          final forkTreeState = treeStateFromLightwalletd(
            await lightwalletd!.client.getTreeStateAtHeight(
              reorged.recovery.forkHeight,
            ),
          );
          expect(
            () => sync.resumeFrom(
              recovery: reorged.recovery,
              treeState: forkTreeState,
            ),
            throwsA(
              isA<ZcashModelException>().having(
                (e) => e.toString(),
                'message',
                contains('rollbackTo(${reorged.recovery.forkHeight})'),
              ),
            ),
            reason: 'rolling a store back is instructed, in every pool',
          );

          wallet.sapling.rollbackTo(reorged.recovery.forkHeight);
          wallet.orchard.rollbackTo(reorged.recovery.forkHeight);
          wallet.ironwood.rollbackTo(reorged.recovery.forkHeight);
          expect(
            wallet.sapling.notes,
            isEmpty,
            reason: 'the block that paid the Sapling note is on no chain now',
          );
          expect(
            wallet.orchard.notes.single.height,
            orchardHeight,
            reason:
                'the Orchard note is thirty blocks below the fork, so the pool '
                'that had nothing to do with the reorg keeps what it held',
          );

          sync.resumeFrom(recovery: reorged.recovery, treeState: forkTreeState);
          expect(sync.cursor.nextHeight, reorged.recovery.resumeHeight);
          expect(
            sync.trail.lowestHeight,
            preRestartTrailLow,
            reason:
                'the trail below a fork point is on both chains, so a recovery '
                'does not leave the wallet one checkpoint deep',
          );

          expect(await sync.syncToTip(), isA<ZcashSyncCaughtUp>());

          final recovered = wallet.sapling.notes.single;
          expect(recovered.height, saplingHeight);
          expect(
            recovered.tx,
            // Scans use protocol byte order; RPC txids are reversed.
            reverseTxidByteOrder(replacementSaplingTxid!),
            reason:
                'the note the wallet holds is the one the winning chain paid — '
                'never both, which would count money twice, and never the '
                'abandoned one',
          );
          expect(
            wallet.balance().totalZatoshis,
            replacementSaplingValue! + orchardValue!,
          );
          expect(
            () => ZcashWalletSyncState.fromJson(
              (jsonDecode(jsonEncode(wallet.toJson())) as Map)
                  .cast<String, Object?>(),
            ),
            returnsNormally,
          );
        },
        timeout: const Timeout(Duration(minutes: 8)),
      );

      test('a wallet restored half-rolled-back is refused', () async {
        if (harness == null || reopened == null) return;

        final document = (jsonDecode(jsonEncode(reopened!.toJson())) as Map)
            .cast<String, Object?>();
        final sapling = (document['sapling']! as Map).cast<String, Object?>();
        final stale = {
          ...document,
          'sapling': {
            ...sapling,
            'covered_through': (sapling['covered_through']! as int) - 3,
          },
        };

        expect(
          () => ZcashWalletSyncState.fromJson(stale),
          throwsA(
            isA<ZcashModelException>().having(
              (e) => e.toString(),
              'message',
              contains('different heights'),
            ),
          ),
        );
      });
    },
    skip: enabled
        ? false
        : 'needs ZEBRA_INTEGRATION, LIGHTWALLETD_INTEGRATION, ZCASH_FFI_LIB and '
              'the Sapling MPC parameters',
  );
}

Future<ZcashLightwalletdScanSource> _fetchRange(
  LightwalletdHarness lightwalletd, {
  required int start,
  required int end,
}) async {
  final range = BlockRange()
    ..start = (BlockID()..height = Int64(start))
    ..end = (BlockID()..height = Int64(end));
  return ZcashLightwalletdScanSource(
    await lightwalletd.fetchCompactBlockRange(range).toList(),
  );
}

Future<ZcashCompactBlockConversion> _convert(
  ZebraHarness harness,
  ZcashFfiBindings ffi,
  int nu63Activation, {
  required int start,
  required int end,
}) async {
  final raw = <String>[];
  for (var height = start; height <= end; height++) {
    raw.add(await harness.client.getRawBlock('$height'));
  }
  return ZcashCompactBlockConversion.fromJson(
    _nativeOk(
      ffi.compactBlocksFromRawBlocks(
        encodeCompactBlockRequest(
          network: 'regtest',
          rawBlockHex: raw,
          regtestNu63ActivationHeight: nu63Activation,
        ),
      ),
    ),
  );
}

ZcashScanResult _scan(
  ZcashFfiBindings ffi,
  String ffiLib,
  ScanInputEnvelope envelope,
) => ZcashScanResult.fromJson(
  _nativeOk(
    ffi.scanCompactBlocksRaw(
      _regtestScanUfvk(ffiLib),
      'regtest',
      envelope.encode(),
    ),
  ),
  allowExperimentalOrchardNotes: true,
);

SaplingBuildResult _buildSaplingShield(
  ZcashFfiBindings ffi,
  String ffiLib,
  int nu63Activation, {
  required AddressUtxo coin,
  required int targetHeight,
  required String spendParams,
  required String outputParams,
}) {
  final built = buildNativeSaplingTransaction(
    network: ZcashNetwork.regtest,
    targetHeight: targetHeight,
    regtestNu63ActivationHeight: nu63Activation,
    seedHex: _testSeedHex,
    inputs: [
      TransparentBuildInput(
        txid: coin.txid,
        vout: coin.outputIndex,
        valueZatoshis: coin.satoshis,
        secretKeyHex: kIronwoodProofMinerSecretKeyHex,
      ),
    ],
    outputs: [SaplingBuildOutput(address: _saplingAddress(ffiLib))],
    spendParamsPath: spendParams,
    outputParamsPath: outputParams,
    allowExperimentalSaplingBuild: true,
    bindings: ffi,
  );
  if (!built.hasRealProofs) {
    throw StateError(
      'the mock prover\'s all-zero proofs are rejected by a node, and there '
      'would then be no replacement block',
    );
  }
  return built;
}

Future<String?> _servedBlockHashOnce(
  LightwalletdHarness lightwalletd,
  int height,
) async {
  try {
    return (await _fetchRange(
      lightwalletd,
      start: height,
      end: height,
    )).lastBlockHash;
  } on Object {
    return null;
  }
}

Future<String?> _awaitServedBlockHash(
  LightwalletdHarness lightwalletd,
  int height, {
  required bool Function(String?) settled,
  Duration timeout = const Duration(seconds: 60),
}) async {
  final deadline = DateTime.now().add(timeout);
  String? last;
  while (DateTime.now().isBefore(deadline)) {
    last = await _servedBlockHashOnce(lightwalletd, height);
    if (settled(last)) return last;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  return last;
}

const _accountFingerprint = 'lightwalletd-pools-proof';

Future<AddressUtxo> _matureCoinbase(ZebraHarness harness, int tip) async {
  final utxos = await harness.client.getAddressUtxos([
    kIronwoodProofMinerAddress,
  ]);
  final matured = utxos.where((u) => u.height <= tip - 100).toList();
  if (matured.isEmpty) {
    throw StateError('no matured coinbase at height $tip');
  }
  return matured.first;
}

Map<String, Object?> _nativeOk(String raw) {
  final json = (jsonDecode(raw) as Map).cast<String, Object?>();
  if (json['status'] != 'ok') {
    throw StateError(
      'native call failed [${json['category']}]: ${json['error']}',
    );
  }
  return json;
}

const _testSeedHex =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'
    '202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f';

String _regtestScanUfvk(String ffiLib) => deriveNativeAccountMetadata(
  seedHex: _testSeedHex,
  network: ZcashNetwork.regtest,
  bindings: ZcashFfiBindings.open(ffiLib),
).ufvk;

String _saplingAddress(String ffiLib) {
  final decoded = _nativeOk(
    ZcashFfiBindings.open(
      ffiLib,
    ).ufvkToAddress(_regtestScanUfvk(ffiLib), 'regtest', 0),
  );
  final receivers = (decoded['addresses'] as Map).cast<String, Object?>();
  final address = receivers['sapling'] as String?;
  if (address == null || !address.startsWith('zregtestsapling')) {
    throw StateError('no regtest Sapling receiver in the account UA: $decoded');
  }
  return address;
}

Future<void> _mineTo(ZebraHarness harness, int height) async {
  final current = await harness.client.getBlockCount();
  if (current >= height) return;
  await harness.mineBlocks(height - current);
}
