@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';
import 'package:zcash_ffi/zcash_ffi.dart';

import 'harness.dart';
import 'lightwalletd_harness.dart';

// Needs an Ironwood-aware ZEBRA_BIN, a digest-pinned NU6.3-aware
// LIGHTWALLETD_DOCKER_IMAGE or LIGHTWALLETD_BIN, and a ZCASH_FFI_LIB with
// ironwood-tx-build and ironwood-note-discovery.
void main() {
  // The height-1 coinbase matures at 101; NU6.3 is staged at 130.
  const nu63Activation = 130;
  const maturityHeight = 101;

  final ffiLib = Platform.environment['ZCASH_FFI_LIB'] ?? '';
  final enabled =
      Platform.environment.containsKey('ZEBRA_INTEGRATION') &&
      Platform.environment.containsKey('LIGHTWALLETD_INTEGRATION') &&
      ffiLib.isNotEmpty;

  ZebraHarness? harness;
  LightwalletdHarness? lightwalletd;
  ZcashFfiBindings? ffi;
  int? shieldHeight;
  int? shieldedZatoshis;
  int? secondShieldHeight;
  int? secondShieldedZatoshis;
  ZcashScanResult? unrootedScan;
  ZcashScanResult? syncedScan;
  String? syncEndTreeHex;
  ZcashLightwalletdSyncCursor? syncCursor;
  IronwoodNoteStore? store;
  int? spendHeight;
  String? spentNullifier;
  int? thirdShieldHeight;
  String? thirdShieldTxid;
  int? forkHeight;
  int? forkedSweepHeight;
  int? forkedSweepZatoshis;
  int? abandonedTipHeight;
  String? abandonedTipHash;
  int? preReorgBalance;
  ZcashScannedNote? abandonedNote;
  int? fourthShieldHeight;
  int? fourthShieldedZatoshis;
  int? secondForkSweepZatoshis;
  int? preRestartBalance;
  int? preRestartHeight;
  int? preRestartTrailLow;
  String? cursorDocument;
  String? storeDocument;
  ZcashChainSync? restoredSync;

  ZcashChainSync chainSync({
    required ZcashLightwalletdSyncCursor cursor,
    required IronwoodNoteStore store,
  }) => ZcashChainSync(
    cursor: cursor,
    accountFingerprint: _accountFingerprint,
    ironwoodStore: store,
    network: 'regtest',
    includeOrchardWitnesses: true,
    chainTip: harness!.client.getBlockCount,
    fetchRange: (start, end) =>
        _fetchRange(lightwalletd!, start: start, end: end),
    fetchTreeState: (height) => harness!.client.getTreeState('$height'),
    scan: (envelope) async => _scan(ffi!, envelope),
    servedBlockHashAt: (height) => _servedBlockHashOnce(lightwalletd!, height),
  );

  setUpAll(() async {
    if (!enabled) return;
    ffi = ZcashFfiBindings.open(ffiLib);
    harness = await ZebraHarness.start(
      nu63ActivationHeight: nu63Activation,
      minerAddress: kIronwoodProofMinerAddress,
    );
    await harness!.mineBlocks(maturityHeight);
    await _mineTo(harness!, nu63Activation + 2);
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
    'Live Ironwood discovery through lightwalletd',
    () {
      test('lightwalletd follows an NU6.3 chain', () async {
        if (harness == null) return;

        final tip = await harness!.client.getBlockCount();
        expect(
          tip,
          greaterThan(nu63Activation),
          reason: 'the chain must be past NU6.3 for Ironwood to exist at all',
        );

        final synced = await lightwalletd!.waitForSyncHeight(
          tip,
          readBackendHeight: harness!.client.getBlockCount,
        );
        expect(synced.lightwalletdHeight, greaterThanOrEqualTo(tip));
      });

      test('a transparent sweep into Ironwood is mined', () async {
        if (harness == null) return;

        final tip = await harness!.client.getBlockCount();
        final coins = await _oneMatureCoin(harness!, tip);
        expect(coins.spendableZatoshis, greaterThan(0));

        final treeState = await harness!.client.getTreeState('$tip');
        final prepared = prepareNativeShieldingSend(
          network: ZcashNetwork.regtest,
          destination: ShieldingDestination.ironwood,
          coins: coins,
          toAddress: kIronwoodProofUnifiedAddress,
          targetHeight: tip + 1,
          signingKeyForCoin: (coin) => kIronwoodProofMinerSecretKeyHex,
          ironwoodAnchor: IronwoodAnchorSource.tree(
            treeState.ironwood?.finalState ?? '',
          ),
          regtestNu63ActivationHeight: nu63Activation,
          allowExperimentalBuild: true,
          bindings: ffi,
        );

        final txid = await harness!.client.sendRawTransaction(
          prepared.transactionHex,
        );
        expect(txid, prepared.txid);

        final hash = (await harness!.mineBlocks(1)).single;
        expect(
          (await harness!.client.getBlock(hash)).transactions,
          contains(txid),
        );

        shieldHeight = await harness!.client.getBlockCount();
        shieldedZatoshis = prepared.shieldedZatoshis;
        expect(shieldedZatoshis, greaterThan(0));
      });

      test('the server carries the Ironwood field the node does', () async {
        if (harness == null || shieldHeight == null) return;
        final height = shieldHeight!;

        await lightwalletd!.waitForSyncHeight(
          height,
          readBackendHeight: harness!.client.getBlockCount,
        );

        final range = BlockRange()
          ..start = (BlockID()..height = Int64(height))
          ..end = (BlockID()..height = Int64(height));
        final served = ZcashLightwalletdScanSource(
          await lightwalletd!.fetchCompactBlockRange(range).toList(),
        );

        final rawBlock = await harness!.client.getRawBlock('$height');
        final converted = ZcashCompactBlockConversion.fromJson(
          _nativeOk(
            ffi!.compactBlocksFromRawBlocks(
              encodeCompactBlockRequest(
                network: 'regtest',
                rawBlockHex: [rawBlock],
                regtestNu63ActivationHeight: nu63Activation,
              ),
            ),
          ),
        );

        expect(
          converted.blocks.single.ironwoodActions,
          greaterThan(0),
          reason: 'the block the node mined does contain an Ironwood action',
        );
        expect(
          served.ironwoodActions,
          converted.blocks.single.ironwoodActions,
          reason:
              'v0.4.19 would report 0 here and no error, because the field it '
              'would be decoding does not exist in its protobuf',
        );
        expect(served.ironwoodCommitmentTreeSize, isNotNull);
        expect(
          served.ironwoodCommitmentTreeSize,
          converted.ironwoodCommitmentTreeSize,
          reason: 'the server and the chain must agree on the tree size',
        );

        expect(
          () => served.requireIronwoodParity(
            nodeIronwoodCommitmentTreeSize:
                converted.ironwoodCommitmentTreeSize,
          ),
          returnsNormally,
        );
      });

      test('the note is found by scanning what lightwalletd served', () async {
        if (harness == null || shieldHeight == null) return;
        final height = shieldHeight!;

        final range = BlockRange()
          ..start = (BlockID()..height = Int64(height))
          ..end = (BlockID()..height = Int64(height));
        final served = ZcashLightwalletdScanSource(
          await lightwalletd!.fetchCompactBlockRange(range).toList(),
        );

        final ufvk = _regtestScanUfvk();
        final scanned = ZcashScanResult.fromJson(
          _nativeOk(
            ffi!.scanCompactBlocksRaw(
              ufvk,
              'regtest',
              jsonEncode({
                'include_orchard_witnesses': true,
                'blocks': served.toScanEntries(),
              }),
            ),
          ),
          allowExperimentalOrchardNotes: true,
        );

        final note = scanned.notes.firstWhere(
          (n) => n.pool == 'ironwood',
          orElse: () => throw StateError(
            'no Ironwood note in a lightwalletd scan: $scanned',
          ),
        );
        expect(
          note.value,
          shieldedZatoshis,
          reason:
              'the wallet recovered its own shielded value from blocks a real '
              'lightwalletd served, which is the sync path a wallet actually '
              'uses',
        );
        expect(scanned.ironwoodAnchor, isNotNull);
      });

      test('the two sources agree note for note', () async {
        if (harness == null || shieldHeight == null) return;
        final height = shieldHeight!;

        final range = BlockRange()
          ..start = (BlockID()..height = Int64(height))
          ..end = (BlockID()..height = Int64(height));
        final served = ZcashLightwalletdScanSource(
          await lightwalletd!.fetchCompactBlockRange(range).toList(),
        );

        final rawBlock = await harness!.client.getRawBlock('$height');
        final converted = ZcashCompactBlockConversion.fromJson(
          _nativeOk(
            ffi!.compactBlocksFromRawBlocks(
              encodeCompactBlockRequest(
                network: 'regtest',
                rawBlockHex: [rawBlock],
                regtestNu63ActivationHeight: nu63Activation,
              ),
            ),
          ),
        );

        final ufvk = _regtestScanUfvk();
        ZcashScanResult scan(List<Map<String, Object?>> entries) =>
            ZcashScanResult.fromJson(
              _nativeOk(
                ffi!.scanCompactBlocksRaw(
                  ufvk,
                  'regtest',
                  jsonEncode({
                    'include_orchard_witnesses': true,
                    'blocks': entries,
                  }),
                ),
              ),
              allowExperimentalOrchardNotes: true,
            );

        final fromServer = scan(served.toScanEntries());
        final fromNode = scan(converted.toScanEntries());

        List<String> fingerprint(ZcashScanResult r) => [
          for (final n in r.notes) '${n.pool}:${n.value}:${n.nullifier ?? ''}',
        ]..sort();

        expect(fingerprint(fromServer), fingerprint(fromNode));
        expect(fromServer.ironwoodAnchor, fromNode.ironwoodAnchor);
      });

      test(
        'a second sweep into Ironwood lands further along the chain',
        () async {
          if (harness == null || shieldHeight == null) return;

          await harness!.mineBlocks(2);
          final tip = await harness!.client.getBlockCount();
          final coins = await _oneMatureCoin(harness!, tip);
          final treeState = await harness!.client.getTreeState('$tip');
          final prepared = prepareNativeShieldingSend(
            network: ZcashNetwork.regtest,
            destination: ShieldingDestination.ironwood,
            coins: coins,
            toAddress: kIronwoodProofUnifiedAddress,
            targetHeight: tip + 1,
            signingKeyForCoin: (coin) => kIronwoodProofMinerSecretKeyHex,
            ironwoodAnchor: IronwoodAnchorSource.tree(
              treeState.ironwood?.finalState ?? '',
            ),
            regtestNu63ActivationHeight: nu63Activation,
            allowExperimentalBuild: true,
            bindings: ffi,
          );

          final txid = await harness!.client.sendRawTransaction(
            prepared.transactionHex,
          );
          final hash = (await harness!.mineBlocks(1)).single;
          expect(
            (await harness!.client.getBlock(hash)).transactions,
            contains(txid),
          );

          secondShieldHeight = await harness!.client.getBlockCount();
          secondShieldedZatoshis = prepared.shieldedZatoshis;
          expect(
            secondShieldHeight,
            greaterThan(shieldHeight! + 1),
            reason:
                'the two notes must sit in different ranges of one sync, which '
                'is the case the block-at-a-time proof above never reaches',
          );

          await lightwalletd!.waitForSyncHeight(
            secondShieldHeight!,
            readBackendHeight: harness!.client.getBlockCount,
          );
        },
      );

      test('a mid-chain range scanned from zero roots at an anchor no chain '
          'has had', () async {
        if (harness == null || secondShieldHeight == null) return;

        final served = await _fetchRange(
          lightwalletd!,
          start: shieldHeight! + 2,
          end: secondShieldHeight!,
        );
        final scanned = ZcashScanResult.fromJson(
          _nativeOk(
            ffi!.scanCompactBlocksRaw(
              _regtestScanUfvk(),
              'regtest',
              jsonEncode({
                'include_orchard_witnesses': true,
                'blocks': served.toScanEntries(),
              }),
            ),
          ),
          allowExperimentalOrchardNotes: true,
        );

        final note = scanned.notes.singleWhere((n) => n.pool == 'ironwood');
        expect(note.value, secondShieldedZatoshis);
        expect(note.witness, isNotNull);
        expect(scanned.ironwoodAnchor, isNotNull);
        unrootedScan = scanned;
      });

      test('the cursor carries the tree from one range into the next', () async {
        if (harness == null || secondShieldHeight == null) return;

        final start = shieldHeight!;
        final split = shieldHeight! + 1;
        final end = secondShieldHeight!;

        var cursor = ZcashLightwalletdSyncCursor.fromTreeState(
          await harness!.client.getTreeState('${start - 1}'),
        );

        final rangeA = await _fetchRange(
          lightwalletd!,
          start: start,
          end: split,
        );
        final scanA = _scan(
          ffi!,
          cursor.scanInputFor(
            rangeA,
            network: 'regtest',
            includeOrchardWitnesses: true,
          ),
        );
        expect(
          scanA.notes.where((n) => n.pool == 'ironwood').single.value,
          shieldedZatoshis,
        );

        cursor = cursor.advance(
          scanned: rangeA,
          treeState: await harness!.client.getTreeState('$split'),
        );
        expect(cursor.nextHeight, split + 1);
        expect(
          cursor.priorIronwoodSize,
          greaterThan(0),
          reason:
              'the first sweep put leaves in the Ironwood tree, and the next '
              'range must be told how many',
        );

        final rangeB = await _fetchRange(
          lightwalletd!,
          start: split + 1,
          end: end,
        );
        final scanB = _scan(
          ffi!,
          cursor.scanInputFor(
            rangeB,
            network: 'regtest',
            includeOrchardWitnesses: true,
          ),
        );

        final note = scanB.notes.singleWhere((n) => n.pool == 'ironwood');
        expect(note.value, secondShieldedZatoshis);
        expect(
          scanB.ironwoodAnchor,
          isNot(unrootedScan!.ironwoodAnchor),
          reason:
              'the same blocks, the same note, and a different anchor — the '
              'only difference is whether the sync carried the tree it began on',
        );

        syncedScan = scanB;
        syncEndTreeHex = (await harness!.client.getTreeState(
          '$end',
        )).ironwood?.finalState;
        expect(syncEndTreeHex, isNotNull);

        syncCursor = cursor.advance(
          scanned: rangeB,
          treeState: await harness!.client.getTreeState('$end'),
        );
        store = IronwoodNoteStore()
          ..apply(scanA, accountFingerprint: _accountFingerprint)
          ..apply(scanB, accountFingerprint: _accountFingerprint);
        expect(store!.nullifiersToWatch, hasLength(2));
      });

      test('a range that does not continue the sync is refused', () async {
        if (harness == null || secondShieldHeight == null) return;

        final cursor = ZcashLightwalletdSyncCursor.fromTreeState(
          await harness!.client.getTreeState('${shieldHeight! - 1}'),
        );
        final gapped = await _fetchRange(
          lightwalletd!,
          start: shieldHeight! + 1,
          end: secondShieldHeight!,
        );

        expect(
          () => cursor.scanInputFor(gapped, network: 'regtest'),
          throwsA(
            isA<ZcashModelException>().having(
              (e) => e.toString(),
              'message',
              contains('Re-fetch from ${shieldHeight!}'),
            ),
          ),
        );
      });

      test(
        'the node mines a spend of a note discovered across the sync',
        () async {
          if (harness == null || syncedScan == null || unrootedScan == null) {
            return;
          }

          final unrooted = unrootedScan!.notes.singleWhere(
            (n) => n.pool == 'ironwood',
          );
          final tip = await harness!.client.getBlockCount();
          final rejected = buildNativeIronwoodTransaction(
            network: ZcashNetwork.regtest,
            targetHeight: tip + 1,
            regtestNu63ActivationHeight: nu63Activation,
            anchor: IronwoodAnchorSource.anchor(unrootedScan!.ironwoodAnchor!),
            inputs: const [],
            ironwoodSpends: [
              IronwoodBuildIronwoodSpendNote.fromScannedNote(
                unrooted,
                anchorHex: unrootedScan!.ironwoodAnchor!,
              ),
            ],
            seedHex: _testSeedHex,
            ironwoodOutput: const IronwoodBuildOutput(
              address: kIronwoodProofUnifiedAddress,
            ),
            ironwoodChangeZatoshis: unrooted.value ~/ 2,
            allowExperimentalIronwoodBuild: true,
            bindings: ffi,
          );
          expect(rejected.transactionHex, isNotEmpty);
          await expectLater(
            harness!.client.sendRawTransaction(rejected.transactionHex),
            throwsA(isA<ZebraRpcException>()),
            reason:
                'a well-formed, correctly proved transaction whose anchor is a '
                'root of a tree that has never existed — which is what a range '
                'scanned from zero produces, silently',
          );

          final note = syncedScan!.notes.singleWhere(
            (n) => n.pool == 'ironwood',
          );
          final built = buildNativeIronwoodTransaction(
            network: ZcashNetwork.regtest,
            targetHeight: tip + 1,
            regtestNu63ActivationHeight: nu63Activation,
            anchor: IronwoodAnchorSource.tree(syncEndTreeHex!),
            inputs: const [],
            ironwoodSpends: [
              IronwoodBuildIronwoodSpendNote.fromScannedNote(
                note,
                anchorHex: syncedScan!.ironwoodAnchor!,
              ),
            ],
            seedHex: _testSeedHex,
            ironwoodOutput: const IronwoodBuildOutput(
              address: kIronwoodProofUnifiedAddress,
            ),
            ironwoodChangeZatoshis: note.value ~/ 2,
            allowExperimentalIronwoodBuild: true,
            bindings: ffi,
          );

          expect(
            built.ironwoodAnchor,
            syncedScan!.ironwoodAnchor,
            reason:
                'the witnesses the sync produced root at the anchor the node '
                'reports for that height, which is the whole claim of this '
                'milestone',
          );

          final txid = await harness!.client.sendRawTransaction(
            built.transactionHex,
          );
          final hash = (await harness!.mineBlocks(1)).single;
          expect(
            (await harness!.client.getBlock(hash)).transactions,
            contains(txid),
            reason:
                'a witness is only proven by a transaction the network accepts',
          );

          spendHeight = await harness!.client.getBlockCount();
          spentNullifier = note.nullifier;
          expect(spentNullifier, isNotNull);
        },
      );

      test(
        'a spend is observed by scanning what lightwalletd served',
        () async {
          if (harness == null || spendHeight == null) return;

          await harness!.mineBlocks(1);
          final end = await harness!.client.getBlockCount();
          await lightwalletd!.waitForSyncHeight(
            end,
            readBackendHeight: harness!.client.getBlockCount,
          );

          final served = await _fetchRange(
            lightwalletd!,
            start: syncCursor!.nextHeight,
            end: end,
          );
          final scanned = _scan(
            ffi!,
            syncCursor!.scanInputFor(
              served,
              network: 'regtest',
              includeOrchardWitnesses: true,
              watchedNullifiers: store!.watchSet,
            ),
          );

          final spend = scanned.spends.singleWhere(
            (s) => s.nullifier == spentNullifier,
            orElse: () => throw StateError(
              'the spend this repo broadcast is not in a scan of the blocks '
              'lightwalletd served: $scanned',
            ),
          );
          expect(spend.pool, 'ironwood');
          expect(spend.height, spendHeight);

          store!.apply(scanned, accountFingerprint: _accountFingerprint);
          final resolved = store!.noteSet;
          expect(
            resolved.spent.map((n) => n.note.nullifier),
            contains(spentNullifier),
            reason:
                'the note was discovered in one range and observed spent in '
                'another, which is what a store exists for',
          );
          expect(
            resolved.unspentZatoshis,
            lessThan(shieldedZatoshis! + secondShieldedZatoshis!),
            reason: 'a wallet that missed the spend would still be counting it',
          );
        },
      );

      test('a watch set filed under another pool sees nothing', () async {
        if (harness == null || spendHeight == null) return;

        final end = await harness!.client.getBlockCount();
        final served = await _fetchRange(
          lightwalletd!,
          start: syncCursor!.nextHeight,
          end: end,
        );
        for (final pool in ['orchard', 'sapling']) {
          final scanned = _scan(
            ffi!,
            syncCursor!.scanInputFor(
              served,
              network: 'regtest',
              includeOrchardWitnesses: true,
              watchedNullifiers: ZcashWatchedNullifiers.forPool(pool, [
                spentNullifier!,
              ]),
            ),
          );
          expect(
            scanned.spends,
            isEmpty,
            reason:
                'the same 32 bytes, watched in the $pool pool, name no note the '
                '$pool pool has ever had',
          );
        }
      });

      test(
        'the sync reaches the tip, with a third note in the store',
        () async {
          if (harness == null || syncCursor == null) return;

          final tip = await harness!.client.getBlockCount();
          final prepared = await _sweepIntoIronwood(
            harness!,
            ffi!,
            nu63Activation,
          );
          await harness!.client.sendRawTransaction(prepared.transactionHex);
          await harness!.mineBlocks(1);
          thirdShieldHeight = await harness!.client.getBlockCount();
          thirdShieldTxid = prepared.txid;
          expect(thirdShieldHeight, greaterThan(tip));

          await harness!.mineBlocks(2);
          final end = await harness!.client.getBlockCount();
          await lightwalletd!.waitForSyncHeight(
            end,
            readBackendHeight: harness!.client.getBlockCount,
          );

          final served = await _fetchRange(
            lightwalletd!,
            start: syncCursor!.nextHeight,
            end: end,
          );
          final scanned = _scan(
            ffi!,
            syncCursor!.scanInputFor(
              served,
              network: 'regtest',
              includeOrchardWitnesses: true,
              watchedNullifiers: store!.watchSet,
            ),
          );
          store!.apply(scanned, accountFingerprint: _accountFingerprint);
          syncCursor = syncCursor!.advance(
            scanned: served,
            treeState: await harness!.client.getTreeState('$end'),
          );

          expect(syncCursor!.trail.highestHeight, end);
          expect(syncCursor!.trail.hashAt(end), isNotNull);
          expect(
            syncCursor!.trail.lowestHeight,
            lessThan(thirdShieldHeight!),
            reason:
                'the fork point below has to be inside what the wallet kept',
          );

          abandonedNote = store!.notes.singleWhere(
            (n) => n.height == thirdShieldHeight,
            orElse: () => throw StateError(
              'the third sweep is not in the store: ${store!.notes}',
            ),
          );
          preReorgBalance = store!.noteSet.unspentZatoshis;
          expect(preReorgBalance, greaterThan(0));
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );

      test('the node reorgs onto a chain that paid a different sweep', () async {
        if (harness == null || thirdShieldHeight == null) return;

        abandonedTipHeight = await harness!.client.getBlockCount();
        abandonedTipHash = syncCursor!.trail.hashAt(abandonedTipHeight!);
        expect(abandonedTipHash, isNotNull);

        await harness!.client.invalidateBlock(
          await harness!.client.getBlockHash(thirdShieldHeight!),
        );
        expect(
          await harness!.client.getBlockCount(),
          lessThan(thirdShieldHeight!),
          reason: 'the block that paid the third sweep is off the chain',
        );
        expect(
          await harness!.client.getRawMempool(),
          isNot(contains(thirdShieldTxid)),
          reason:
              'the node does not put an abandoned block\'s transactions back, '
              'which is what lets the replacement block differ from it',
        );

        final replacement = await _sweepIntoIronwood(
          harness!,
          ffi!,
          nu63Activation,
        );
        await harness!.client.sendRawTransaction(replacement.transactionHex);
        await harness!.mineBlocks(1);
        forkedSweepHeight = await harness!.client.getBlockCount();
        forkedSweepZatoshis = replacement.shieldedZatoshis;
        expect(
          forkedSweepHeight,
          thirdShieldHeight,
          reason: 'the replacement sits at the height it replaced',
        );
        expect(
          await harness!.client.getBlockHash(thirdShieldHeight!),
          isNot(reverseTxidByteOrder(abandonedNote!.tx)),
          reason: 'and it is a different block',
        );

        while (await harness!.client.getBlockCount() <=
            syncCursor!.nextHeight + 1) {
          await harness!.mineBlocks(2);
        }
        final newTip = await harness!.client.getBlockCount();
        expect(newTip, greaterThan(abandonedTipHeight!));

        forkHeight = await _forkHeightAgainstNode(harness!, syncCursor!.trail);
        expect(forkHeight, isNotNull);
        expect(
          forkHeight,
          thirdShieldHeight! - 1,
          reason: 'the last block both chains still hold',
        );

        await lightwalletd!.waitForSyncHeight(
          newTip,
          readBackendHeight: harness!.client.getBlockCount,
        );
        final servedTipHash = await _awaitServedBlockHash(
          lightwalletd!,
          abandonedTipHeight!,
          settled: (hash) => hash != null && hash != abandonedTipHash,
        );
        expect(
          servedTipHash,
          isNot(abandonedTipHash),
          reason:
              'the server is now answering for height ${abandonedTipHeight!} with '
              'a different block, which is the whole event a wallet has to notice',
        );
      }, timeout: const Timeout(Duration(minutes: 5)));

      test(
        'a sync carrying no hash re-anchors onto the fork with no error',
        () async {
          if (harness == null || forkHeight == null) return;

          final blind = ZcashLightwalletdSyncCursor(
            nextHeight: syncCursor!.nextHeight,
            priorSaplingFrontier: syncCursor!.priorSaplingFrontier,
            priorOrchardFrontier: syncCursor!.priorOrchardFrontier,
            priorIronwoodFrontier: syncCursor!.priorIronwoodFrontier,
            priorSaplingSize: syncCursor!.priorSaplingSize,
            priorOrchardSize: syncCursor!.priorOrchardSize,
            priorIronwoodSize: syncCursor!.priorIronwoodSize,
          );
          final newTip = await harness!.client.getBlockCount();
          final forked = await _fetchRange(
            lightwalletd!,
            start: blind.nextHeight,
            end: newTip,
          );

          expect(
            forked.ironwoodCommitmentTreeSize,
            syncCursor!.priorIronwoodSize,
            reason: 'the two chains are the same length and the same size',
          );

          final scanned = _scan(
            ffi!,
            blind.scanInputFor(
              forked,
              network: 'regtest',
              includeOrchardWitnesses: true,
            ),
          );
          expect(
            scanned.scannedBlocks,
            greaterThan(0),
            reason:
                'no exception, no diagnostic, and the wallet is now positioned on a '
                'chain it never verified',
          );
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );

      test('the sync that kept a hash refuses the same blocks', () async {
        if (harness == null || forkHeight == null) return;

        final newTip = await harness!.client.getBlockCount();
        final forked = await _fetchRange(
          lightwalletd!,
          start: syncCursor!.nextHeight,
          end: newTip,
        );

        expect(
          () => syncCursor!.scanInputFor(forked, network: 'regtest'),
          throwsA(
            isA<ZcashChainReorgException>()
                .having((e) => e.height, 'height', syncCursor!.nextHeight)
                .having((e) => e.expectedPrevHash, 'expected', abandonedTipHash)
                .having(
                  (e) => e.servedPrevHash,
                  'served',
                  isNot(abandonedTipHash),
                ),
          ),
          reason:
              'the same range the blind cursor accepted, refused by type, with '
              'the two chains named',
        );
      }, timeout: const Timeout(Duration(minutes: 3)));

      test(
        'the wallet finds the fork point, and the money follows the chain',
        () async {
          if (harness == null || forkHeight == null) return;

          final recovery = await ZcashReorgRecovery.find(
            trail: syncCursor!.trail,
            servedBlockHashAt: (height) =>
                _servedBlockHashOnce(lightwalletd!, height),
          );

          expect(
            recovery.forkHeight,
            forkHeight,
            reason:
                'the last height both chains still have, not the first they do not '
                '— and the same height the node itself parts at',
          );
          expect(recovery.resumeHeight, forkHeight! + 1);
          expect(recovery.depth, abandonedTipHeight! - forkHeight!);

          final balanceBefore = store!.noteSet.unspentZatoshis;
          store!.rollbackTo(recovery.forkHeight);
          expect(
            store!.notes.where((n) => n.tx == abandonedNote!.tx),
            isEmpty,
            reason: 'the block that paid it is not on any chain now',
          );
          expect(
            store!.noteSet.unspentZatoshis,
            balanceBefore - abandonedNote!.value,
          );
          expect(store!.coveredThrough, recovery.forkHeight);

          var resumed = ZcashLightwalletdSyncCursor.fromTreeState(
            await harness!.client.getTreeState('${recovery.forkHeight}'),
          );
          expect(resumed.nextHeight, recovery.resumeHeight);

          final newTip = await harness!.client.getBlockCount();
          final served = await _fetchRange(
            lightwalletd!,
            start: resumed.nextHeight,
            end: newTip,
          );
          final scanned = _scan(
            ffi!,
            resumed.scanInputFor(
              served,
              network: 'regtest',
              includeOrchardWitnesses: true,
              watchedNullifiers: store!.watchSet,
            ),
          );
          store!.apply(scanned, accountFingerprint: _accountFingerprint);
          resumed = resumed.advance(
            scanned: served,
            treeState: await harness!.client.getTreeState('$newTip'),
          );
          syncCursor = resumed;

          expect(
            store!.notes.where((n) => n.tx == abandonedNote!.tx),
            isEmpty,
            reason:
                'the abandoned payment is not on the chain the wallet resynced',
          );
          expect(
            store!.notes.where((n) => n.height == thirdShieldHeight),
            hasLength(1),
          );
          expect(
            store!.noteSet.unspentZatoshis,
            balanceBefore - abandonedNote!.value + forkedSweepZatoshis!,
            reason:
                'the balance is the winning chain\'s, not the abandoned one\'s',
          );

          expect(resumed.trail.hashAt(newTip), isNotNull);
          final overlapping = await _fetchRange(
            lightwalletd!,
            start: resumed.nextHeight - 1,
            end: newTip,
          );
          expect(
            () => resumed.scanInputFor(overlapping, network: 'regtest'),
            throwsA(isA<ZcashModelException>()),
            reason: 're-serving a height it already accepted is still a gap',
          );
        },
        timeout: const Timeout(Duration(minutes: 5)),
      );

      test('the loop syncs a range, and the wallet is written down', () async {
        if (harness == null || syncCursor == null) return;

        final prepared = await _sweepIntoIronwood(
          harness!,
          ffi!,
          nu63Activation,
        );
        await harness!.client.sendRawTransaction(prepared.transactionHex);
        await harness!.mineBlocks(1);
        fourthShieldHeight = await harness!.client.getBlockCount();
        fourthShieldedZatoshis = prepared.shieldedZatoshis;
        await harness!.mineBlocks(2);
        final tip = await harness!.client.getBlockCount();
        await lightwalletd!.waitForSyncHeight(
          tip,
          readBackendHeight: harness!.client.getBlockCount,
        );

        final sync = chainSync(cursor: syncCursor!, store: store!);
        final ranges = <String>[];
        final outcome = await sync.syncToTip(
          onAdvanced: (advanced) =>
              ranges.add('${advanced.range.start}-${advanced.range.end}'),
        );

        expect(outcome, isA<ZcashSyncCaughtUp>());
        expect((outcome as ZcashSyncCaughtUp).chainHeight, tip);
        expect(ranges, isNotEmpty);
        expect(sync.cursor.nextHeight, tip + 1);
        expect(
          store!.notes.where((n) => n.height == fourthShieldHeight),
          hasLength(1),
          reason: 'the loop applied what it scanned',
        );

        preRestartBalance = store!.noteSet.unspentZatoshis;
        preRestartHeight = sync.cursor.nextHeight;
        preRestartTrailLow = sync.trail.lowestHeight;
        cursorDocument = jsonEncode(sync.cursor.toJson());
        storeDocument = jsonEncode(store!.toJson());
        syncCursor = null;
        store = null;
      }, timeout: const Timeout(Duration(minutes: 5)));

      test('reopening from the documents is not a rescan', () async {
        if (harness == null || cursorDocument == null) return;

        final restoredCursor = ZcashLightwalletdSyncCursor.fromJson(
          (jsonDecode(cursorDocument!) as Map).cast<String, Object?>(),
        );
        final restoredStore = IronwoodNoteStore.fromJson(
          (jsonDecode(storeDocument!) as Map).cast<String, Object?>(),
        );

        expect(restoredCursor.nextHeight, preRestartHeight);
        expect(restoredStore.noteSet.unspentZatoshis, preRestartBalance);
        expect(
          restoredCursor.trail.lowestHeight,
          preRestartTrailLow,
          reason:
              'the trail is the half a re-bootstrap from a getTreeState cannot '
              'reproduce, and it is the half a reorg is recovered with',
        );

        await harness!.mineBlocks(2);
        final tip = await harness!.client.getBlockCount();
        await lightwalletd!.waitForSyncHeight(
          tip,
          readBackendHeight: harness!.client.getBlockCount,
        );

        final sync = chainSync(cursor: restoredCursor, store: restoredStore);
        final ranges = <CompactBlockScanRange>[];
        final outcome = await sync.syncToTip(
          onAdvanced: (advanced) => ranges.add(advanced.range),
        );

        expect(outcome, isA<ZcashSyncCaughtUp>());
        expect(
          ranges.first.start,
          preRestartHeight,
          reason:
              'the reopened wallet asked for the block after the one it had, not '
              'for its birthday: a restart is not a rescan',
        );
        expect(ranges.last.end, tip);
        expect(sync.cursor.nextHeight, tip + 1);
        expect(
          restoredStore.noteSet.unspentZatoshis,
          preRestartBalance,
          reason: 'and it did not rediscover what it already held as new money',
        );

        syncCursor = sync.cursor;
        store = restoredStore;
        restoredSync = sync;
      }, timeout: const Timeout(Duration(minutes: 5)));

      test(
        'the reopened wallet recovers from a reorg its trail remembers',
        () async {
          if (harness == null || restoredSync == null) return;

          final sync = restoredSync!;

          final preReorgTip = await harness!.client.getBlockCount();
          final rebootstrapped = ZcashLightwalletdSyncCursor.fromTreeState(
            await harness!.client.getTreeState('$preReorgTip'),
          );
          expect(rebootstrapped.trail.checkpoints, hasLength(1));

          await harness!.client.invalidateBlock(
            await harness!.client.getBlockHash(fourthShieldHeight!),
          );
          final replacement = await _sweepIntoIronwood(
            harness!,
            ffi!,
            nu63Activation,
          );
          await harness!.client.sendRawTransaction(replacement.transactionHex);
          await harness!.mineBlocks(1);
          secondForkSweepZatoshis = replacement.shieldedZatoshis;
          while (await harness!.client.getBlockCount() <= preReorgTip + 1) {
            await harness!.mineBlocks(2);
          }
          final newTip = await harness!.client.getBlockCount();
          final nodeForkHeight = await _forkHeightAgainstNode(
            harness!,
            sync.trail,
          );
          expect(nodeForkHeight, fourthShieldHeight! - 1);

          await lightwalletd!.waitForSyncHeight(
            newTip,
            readBackendHeight: harness!.client.getBlockCount,
          );
          await _awaitServedBlockHash(
            lightwalletd!,
            fourthShieldHeight!,
            settled: (hash) =>
                hash != null && hash != sync.trail.hashAt(fourthShieldHeight!),
          );

          final outcome = await sync.step();
          expect(outcome, isA<ZcashSyncReorged>());
          final reorged = outcome as ZcashSyncReorged;
          expect(reorged.recovery.forkHeight, nodeForkHeight);
          expect(reorged.recovery.resumeHeight, nodeForkHeight! + 1);

          await expectLater(
            ZcashReorgRecovery.find(
              trail: rebootstrapped.trail,
              servedBlockHashAt: (height) =>
                  _servedBlockHashOnce(lightwalletd!, height),
            ),
            throwsA(isA<ZcashReorgTooDeepException>()),
            reason:
                'the re-bootstrap path knows one block, and the reorg took it: '
                'that wallet rescans from its birthday for a three-block fork',
          );

          final forkTreeState = await harness!.client.getTreeState(
            '${reorged.recovery.forkHeight}',
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
          );

          final balanceBefore = store!.noteSet.unspentZatoshis;
          store!.rollbackTo(reorged.recovery.forkHeight);
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
          expect(
            store!.notes.where((n) => n.height == fourthShieldHeight),
            hasLength(1),
            reason: 'the winning chain paid a sweep at that height too',
          );
          expect(
            store!.noteSet.unspentZatoshis,
            balanceBefore - fourthShieldedZatoshis! + secondForkSweepZatoshis!,
            reason:
                'the balance is the winning chain\'s — never both payments, which '
                'would be counting money twice, and never only the abandoned one',
          );
          syncCursor = sync.cursor;
        },
        timeout: const Timeout(Duration(minutes: 5)),
      );

      test(
        'a restored position whose frontiers are for another height',
        () async {
          if (harness == null ||
              syncCursor == null ||
              fourthShieldHeight == null) {
            return;
          }

          await harness!.mineBlocks(2);
          final end = await harness!.client.getBlockCount();
          await lightwalletd!.waitForSyncHeight(
            end,
            readBackendHeight: harness!.client.getBlockCount,
          );

          final served = await _fetchRange(
            lightwalletd!,
            start: syncCursor!.nextHeight,
            end: end,
          );
          final honest = _scan(
            ffi!,
            syncCursor!.scanInputFor(
              served,
              network: 'regtest',
              includeOrchardWitnesses: true,
            ),
          );

          final staleTreeState = await harness!.client.getTreeState(
            '${fourthShieldHeight! - 1}',
          );
          final mispaired = ZcashLightwalletdSyncCursor(
            nextHeight: syncCursor!.nextHeight,
            priorSaplingFrontier: staleTreeState.sapling?.finalState,
            priorOrchardFrontier: staleTreeState.orchard?.finalState,
            priorIronwoodFrontier: staleTreeState.ironwood?.finalState,
            priorBlockHash: syncCursor!.priorBlockHash,
          );
          final wrong = _scan(
            ffi!,
            mispaired.scanInputFor(
              served,
              network: 'regtest',
              includeOrchardWitnesses: true,
            ),
          );

          expect(
            wrong.scannedBlocks,
            greaterThan(0),
            reason: 'no exception and no diagnostic, exactly as 21a described',
          );
          expect(
            wrong.ironwoodAnchor,
            isNot(honest.ironwoodAnchor),
            reason:
                'the same blocks and a different anchor — and the node accepts '
                'only one of them, which 21a proved by having one rejected',
          );

          final document = (jsonDecode(jsonEncode(syncCursor!.toJson())) as Map)
              .cast<String, Object?>();
          expect(
            () => ZcashLightwalletdSyncCursor.fromJson({
              ...document,
              'frontier_height': staleTreeState.height,
            }),
            throwsA(
              isA<ZcashModelException>().having(
                (e) => e.toString(),
                'message',
                contains('blocks from where they are about to be used'),
              ),
            ),
          );
          expect(
            () => ZcashLightwalletdSyncCursor.fromJson({
              ...document,
              'trail': ZcashChainTrail.empty().toJson(),
            }),
            throwsA(isA<ZcashModelException>()),
            reason:
                'and a position restored with no trail is not a position that can '
                'recover from the next reorg',
          );
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );
    },
    skip: enabled
        ? false
        : 'needs ZEBRA_INTEGRATION, LIGHTWALLETD_INTEGRATION and ZCASH_FFI_LIB',
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

Future<String?> _servedBlockHashOnce(
  LightwalletdHarness lightwalletd,
  int height,
) async {
  try {
    final served = await _fetchRange(lightwalletd, start: height, end: height);
    return served.lastBlockHash;
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

Future<ShieldingPreparedSend> _sweepIntoIronwood(
  ZebraHarness harness,
  ZcashFfiBindings ffi,
  int nu63Activation,
) async {
  final tip = await harness.client.getBlockCount();
  final coins = await _oneMatureCoin(harness, tip);
  final treeState = await harness.client.getTreeState('$tip');
  return prepareNativeShieldingSend(
    network: ZcashNetwork.regtest,
    destination: ShieldingDestination.ironwood,
    coins: coins,
    toAddress: kIronwoodProofUnifiedAddress,
    targetHeight: tip + 1,
    signingKeyForCoin: (coin) => kIronwoodProofMinerSecretKeyHex,
    ironwoodAnchor: IronwoodAnchorSource.tree(
      treeState.ironwood?.finalState ?? '',
    ),
    regtestNu63ActivationHeight: nu63Activation,
    allowExperimentalBuild: true,
    bindings: ffi,
  );
}

Future<int?> _forkHeightAgainstNode(
  ZebraHarness harness,
  ZcashChainTrail trail,
) async {
  for (final checkpoint in trail.checkpoints.reversed) {
    String? nodeHash;
    try {
      // Trail hashes are in compact-block order; RPC shows displayed order.
      nodeHash = blockHashFromDisplayedHash(
        await harness.client.getBlockHash(checkpoint.height),
      );
    } on Object {
      nodeHash = null;
    }
    if (nodeHash != null && nodeHash == checkpoint.blockHash) {
      return checkpoint.height;
    }
  }
  return null;
}

ZcashScanResult _scan(ZcashFfiBindings ffi, ScanInputEnvelope envelope) =>
    ZcashScanResult.fromJson(
      _nativeOk(
        ffi.scanCompactBlocksRaw(
          _regtestScanUfvk(),
          'regtest',
          envelope.encode(),
        ),
      ),
      allowExperimentalOrchardNotes: true,
    );

Future<TransparentCoinSet> _oneMatureCoin(
  ZebraHarness harness,
  int chainHeight,
) async {
  final utxos = await harness.client.getAddressUtxos([
    kIronwoodProofMinerAddress,
  ]);
  final all = TransparentCoinSet.fromUtxos(
    utxos: utxos,
    chainHeight: chainHeight,
    coinbaseOutpoints: {
      for (final utxo in utxos) '${utxo.txid}:${utxo.outputIndex}',
    },
  );
  final spendable = all.spendable;
  if (spendable.isEmpty) {
    throw StateError('no mature coinbase output at height $chainHeight');
  }
  final chosen = spendable.first.utxo;
  return TransparentCoinSet.fromUtxos(
    utxos: [chosen],
    chainHeight: chainHeight,
    coinbaseOutpoints: {'${chosen.txid}:${chosen.outputIndex}'},
  );
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

const _accountFingerprint = 'lightwalletd-sync-proof';

const _testSeedHex =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'
    '202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f';

String _regtestScanUfvk() {
  final metadata = deriveNativeAccountMetadata(
    seedHex: _testSeedHex,
    network: ZcashNetwork.regtest,
    bindings: ZcashFfiBindings.open(Platform.environment['ZCASH_FFI_LIB']!),
  );
  return metadata.ufvk;
}

Future<void> _mineTo(ZebraHarness harness, int height) async {
  final current = await harness.client.getBlockCount();
  if (current >= height) return;
  await harness.mineBlocks(height - current);
}
