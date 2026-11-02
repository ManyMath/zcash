@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zcash_flutter/zcash_flutter.dart';
import 'harness.dart';

// Needs an Ironwood-aware ZEBRA_BIN and a ZCASH_FFI_LIB with orchard-tx-build
// and ironwood-tx-build.
void main() {
  // The height-1 coinbase matures at 101; NU6.3 is staged at 130.
  const nu63Activation = 130;
  const maturityHeight = 101;

  final ffiLib = Platform.environment['ZCASH_FFI_LIB'] ?? '';
  final enabled =
      Platform.environment.containsKey('ZEBRA_INTEGRATION') &&
      ffiLib.isNotEmpty;

  ZebraHarness? harness;
  ZcashFfiBindings? ffi;
  AddressUtxo? coinbase;
  String? preActivationTxHex;
  String? preActivationTxid;
  int? shieldBlockHeight;
  int? migrationBlockHeight;
  int? migratedDenomination;
  int? retainedOrchardChange;
  ZcashScannedNote? migratedIronwoodNote;
  String? migratedIronwoodAnchor;
  int? ironwoodSpendBlockHeight;
  String? ironwoodSpendTxid;
  int? paymentBlockHeight;

  setUpAll(() async {
    if (!enabled) return;
    ffi = ZcashFfiBindings.open(ffiLib);
    harness = await ZebraHarness.start(
      nu63ActivationHeight: nu63Activation,
      minerAddress: kIronwoodProofMinerAddress,
    );
    await harness!.mineBlocks(maturityHeight);
  });

  tearDownAll(() async {
    if (harness == null) return;
    await harness!.shutdown();
    harness = null;
  });

  group('Live NU6.3 staged-chain builds', () {
    test('a matured coinbase is spendable by the suite key', () async {
      if (harness == null) return;
      final utxos = await harness!.client.getAddressUtxos([
        kIronwoodProofMinerAddress,
      ]);
      final matured = utxos.where((u) => u.height <= 1).toList();
      expect(
        matured,
        isNotEmpty,
        reason:
            'the chain must pay coinbases to an address this suite holds the '
            'key for; without one there is no transparent value to shield',
      );
      coinbase = matured.first;
      expect(coinbase!.satoshis, greaterThan(20000));
    });

    test(
      'a v5 Orchard shielding transaction is accepted below NU6.3',
      () async {
        if (harness == null || coinbase == null) return;
        final tip = await harness!.client.getBlockCount();
        expect(
          tip,
          lessThan(nu63Activation),
          reason: 'this transaction can only exist on the pre-activation side',
        );

        final treeState = await harness!.client.getTreeState('$tip');
        final built = buildNativeOrchardTransaction(
          network: ZcashNetwork.regtest,
          targetHeight: tip + 1,
          regtestNu63ActivationHeight: nu63Activation,
          anchor: OrchardAnchorSource.tree(treeState.orchard?.finalState ?? ''),
          inputs: [
            TransparentBuildInput(
              txid: coinbase!.txid,
              vout: coinbase!.outputIndex,
              valueZatoshis: coinbase!.satoshis,
              secretKeyHex: kIronwoodProofMinerSecretKeyHex,
            ),
          ],
          orchardOutput: const OrchardBuildOutput(
            address: kIronwoodProofUnifiedAddress,
          ),
          allowExperimentalOrchardBuild: true,
          bindings: ffi,
        );

        expect(built.isConsensusValid, isTrue);
        expect(built.version, 'v5');
        expect(
          built.consensusBranchId,
          'nu6.2',
          reason: 'below activation the chain is on NU6.2, and so must this be',
        );
        expect(built.orchardActions, 2);
        expect(
          built.orchardOutputZatoshis,
          coinbase!.satoshis - built.feeZatoshis,
        );
        preActivationTxHex = built.transactionHex;
        preActivationTxid = built.txid;

        final txid = await harness!.client.sendRawTransaction(
          built.transactionHex,
        );
        expect(txid, built.txid);
        expect(await harness!.client.getRawMempool(), contains(built.txid));

        final hash = (await harness!.mineBlocks(1)).single;
        final block = await harness!.client.getBlock(hash);
        expect(
          block.transactions,
          contains(built.txid),
          reason: 'the transaction must be mined, not merely accepted',
        );
        shieldBlockHeight = await harness!.client.getBlockCount();
      },
    );

    test('the mined Orchard output is in the chain tree state', () async {
      if (harness == null || preActivationTxid == null) return;
      final tip = await harness!.client.getBlockCount();
      final treeState = await harness!.client.getTreeState('$tip');
      expect(
        treeState.orchard?.finalState,
        isNot(anyOf(isNull, isEmpty, '000000')),
        reason:
            'the Orchard commitment tree must have grown; an empty tree here '
            'would mean the transaction carried no Orchard output after all',
      );
    });

    test('the same transaction is rejected once NU6.3 activates', () async {
      if (harness == null || preActivationTxHex == null) return;
      await _mineTo(harness!, nu63Activation);
      final info = await harness!.client.getBlockchainInfo();
      expect(info.upgrades['37a5165b']!.status, 'active');

      await expectLater(
        harness!.client.sendRawTransaction(preActivationTxHex!),
        throwsA(isA<ZebraRpcException>()),
      );
    });

    test(
      'a v6 Ironwood shielding transaction is accepted above NU6.3',
      () async {
        if (harness == null) return;
        final tip = await harness!.client.getBlockCount();
        expect(tip, greaterThanOrEqualTo(nu63Activation));

        final utxos = await harness!.client.getAddressUtxos([
          kIronwoodProofMinerAddress,
        ]);
        final spendable = utxos
            .where((u) => u.height <= tip - 100 && u.txid != coinbase?.txid)
            .toList();
        expect(spendable, isNotEmpty, reason: 'need a second matured coinbase');

        final treeState = await harness!.client.getTreeState('$tip');
        final built = buildNativeIronwoodTransaction(
          network: ZcashNetwork.regtest,
          targetHeight: tip + 1,
          regtestNu63ActivationHeight: nu63Activation,
          anchor: IronwoodAnchorSource.tree(
            treeState.ironwood?.finalState ?? '',
          ),
          inputs: [
            TransparentBuildInput(
              txid: spendable.first.txid,
              vout: spendable.first.outputIndex,
              valueZatoshis: spendable.first.satoshis,
              secretKeyHex: kIronwoodProofMinerSecretKeyHex,
            ),
          ],
          ironwoodOutput: const IronwoodBuildOutput(
            address: kIronwoodProofUnifiedAddress,
          ),
          allowExperimentalIronwoodBuild: true,
          bindings: ffi,
        );

        expect(built.version, 'v6');
        expect(built.consensusBranchId, 'nu6.3');
        expect(built.ironwoodActions, 2);
        expect(built.isConsensusValid, isTrue);

        final txid = await harness!.client.sendRawTransaction(
          built.transactionHex,
        );
        expect(txid, built.txid);

        final hash = (await harness!.mineBlocks(1)).single;
        final block = await harness!.client.getBlock(hash);
        expect(
          block.transactions,
          contains(built.txid),
          reason:
              'a v6 transaction carrying an Ironwood bundle, mined by a real '
              'node: the first end of the Ironwood path this repo can prove '
              'without an offline stand-in',
        );
      },
    );

    test('a ZIP 318 canonical migration moves the note into Ironwood', () async {
      if (harness == null || shieldBlockHeight == null) return;

      final rawBlock = await harness!.client.getRawBlock('$shieldBlockHeight');
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
      expect(converted.blocks.single.orchardActions, 2);

      final ufvk = _regtestScanUfvk();
      final scanned = ZcashScanResult.fromJson(
        _nativeOk(
          ffi!.scanCompactBlocksRaw(
            ufvk,
            'regtest',
            jsonEncode({
              'include_orchard_witnesses': true,
              'blocks': converted.toScanEntries(),
            }),
          ),
        ),
        allowExperimentalOrchardNotes: true,
      );
      final note = scanned.notes.firstWhere(
        (n) => n.pool == 'orchard',
        orElse: () => throw StateError('no Orchard note found: $scanned'),
      );
      final orchardAnchor = scanned.orchardAnchor;
      expect(orchardAnchor, isNotNull);

      // ZIP 318's smallest denomination (0.01 ZEC); the rest stays as change.
      const denomination = 1000000;
      const canonicalFee = 15000;
      // ZIP 318 canonical expiry: last multiple of EXPIRY_MODULUS (34560) at
      // or below the broadcast height, plus two more.
      const canonicalExpiry = 2 * 34560;
      final change = note.value - denomination - canonicalFee;
      expect(change, greaterThan(0));

      final tip = await harness!.client.getBlockCount();
      expect(tip, greaterThanOrEqualTo(nu63Activation));
      final treeState = await harness!.client.getTreeState('$tip');

      final built = buildNativeIronwoodTransaction(
        network: ZcashNetwork.regtest,
        targetHeight: tip + 1,
        regtestNu63ActivationHeight: nu63Activation,
        expiryHeight: canonicalExpiry,
        anchor: IronwoodAnchorSource.tree(treeState.ironwood?.finalState ?? ''),
        inputs: const [],
        orchardSpends: [
          IronwoodBuildOrchardSpendNote.fromScannedNote(
            note,
            anchorHex: orchardAnchor!,
          ),
        ],
        orchardChangeZatoshis: change,
        seedHex: _testSeedHex,
        ironwoodOutput: const IronwoodBuildOutput(
          address: kIronwoodProofUnifiedAddress,
          valueZatoshis: denomination,
        ),
        allowExperimentalIronwoodBuild: true,
        bindings: ffi,
      );

      expect(built.zip318Canonical, isTrue);
      expect(built.spendsOrchard, isTrue);
      expect(built.version, 'v6');
      expect(built.consensusBranchId, 'nu6.3');
      expect(built.feeZatoshis, canonicalFee);
      expect(built.orchardActions, 2);
      expect(built.ironwoodActions, 1);
      expect(built.ironwoodOutputZatoshis, denomination);
      expect(built.expiryHeight, canonicalExpiry);

      final txid = await harness!.client.sendRawTransaction(
        built.transactionHex,
      );
      expect(txid, built.txid);

      final hash = (await harness!.mineBlocks(1)).single;
      final block = await harness!.client.getBlock(hash);
      expect(
        block.transactions,
        contains(built.txid),
        reason:
            'an Orchard note, created before activation, scanned without a '
            'lightwalletd, and migrated into Ironwood in the ZIP 318 canonical '
            'shape — accepted and mined by a real node',
      );
      migrationBlockHeight = await harness!.client.getBlockCount();
      migratedDenomination = denomination;
      retainedOrchardChange = change;
    });

    test('the migrated funds are visible in the Ironwood pool', () async {
      if (harness == null || migrationBlockHeight == null) return;

      final rawBlocks = <String>[
        for (var h = shieldBlockHeight!; h <= migrationBlockHeight!; h++)
          await harness!.client.getRawBlock('$h'),
      ];
      final converted = ZcashCompactBlockConversion.fromJson(
        _nativeOk(
          ffi!.compactBlocksFromRawBlocks(
            encodeCompactBlockRequest(
              network: 'regtest',
              rawBlockHex: rawBlocks,
              regtestNu63ActivationHeight: nu63Activation,
            ),
          ),
        ),
      );
      expect(converted.orchardCommitmentTreeSize, greaterThanOrEqualTo(4));
      expect(converted.ironwoodCommitmentTreeSize, greaterThanOrEqualTo(3));

      final scanned = ZcashScanResult.fromJson(
        _nativeOk(
          ffi!.scanCompactBlocksRaw(
            _regtestScanUfvk(),
            'regtest',
            jsonEncode({
              'include_orchard_witnesses': true,
              'blocks': converted.toScanEntries(),
            }),
          ),
        ),
        allowExperimentalOrchardNotes: true,
      );

      final ironwood = scanned.notes
          .where(
            (n) => n.pool == 'ironwood' && n.height == migrationBlockHeight,
          )
          .toList();
      expect(
        ironwood,
        hasLength(1),
        reason:
            'the migration created exactly one Ironwood note, and it must be '
            'discoverable by the same account key that received the Orchard '
            'one — ZIP 229 adds no Ironwood address, so no new key is involved',
      );
      expect(ironwood.single.value, migratedDenomination);
      expect(
        ironwood.single.noteVersion,
        'v3',
        reason:
            'an Ironwood note carries the ZIP 2005 V3 plaintext; a v2 here '
            'would mean it had been read out of the wrong pool',
      );

      final change = scanned.notes
          .where((n) => n.pool == 'orchard' && n.height == migrationBlockHeight)
          .toList();
      expect(change, hasLength(1));
      expect(change.single.value, retainedOrchardChange);
      expect(change.single.noteVersion, 'v2');

      expect(scanned.orchardAnchor, isNotNull);
      expect(scanned.ironwoodAnchor, isNotNull);
      expect(scanned.ironwoodAnchor, isNot(scanned.orchardAnchor));

      final treeState = await harness!.client.getTreeState(
        '$migrationBlockHeight',
      );
      expect(treeState.ironwood?.finalState, isNotNull);
      expect(
        ironwood.single.commitmentPosition,
        isNotNull,
        reason:
            'an Ironwood note is positioned in the Ironwood tree, which is '
            'not the Orchard one',
      );

      migratedIronwoodNote = ironwood.single;
      migratedIronwoodAnchor = scanned.ironwoodAnchor;
    });

    test('the migrated Ironwood note can be spent', () async {
      if (harness == null || migratedIronwoodNote == null) return;

      final note = migratedIronwoodNote!;
      const change = 400000;
      final tip = await harness!.client.getBlockCount();

      final quoted = quoteNativeIronwoodFee(
        network: ZcashNetwork.regtest,
        targetHeight: tip + 1,
        regtestNu63ActivationHeight: nu63Activation,
        anchor: IronwoodAnchorSource.anchor(migratedIronwoodAnchor!),
        inputs: const [],
        ironwoodSpends: [
          IronwoodBuildIronwoodSpendNote.fromScannedNote(
            note,
            anchorHex: migratedIronwoodAnchor!,
          ),
        ],
        seedHex: _testSeedHex,
        ironwoodOutput: const IronwoodBuildOutput(
          address: kIronwoodProofUnifiedAddress,
        ),
        ironwoodChangeZatoshis: change,
        allowExperimentalIronwoodBuild: true,
        bindings: ffi,
      );
      expect(quoted.consensusBranchId, 'nu6.3');
      expect(quoted.ironwoodSpends, 1);
      expect(quoted.totalInputZatoshis, note.value);
      expect(quoted.isFunded, isTrue);

      final built = buildNativeIronwoodTransaction(
        network: ZcashNetwork.regtest,
        targetHeight: tip + 1,
        regtestNu63ActivationHeight: nu63Activation,
        anchor: IronwoodAnchorSource.anchor(migratedIronwoodAnchor!),
        inputs: const [],
        ironwoodSpends: [
          IronwoodBuildIronwoodSpendNote.fromScannedNote(
            note,
            anchorHex: migratedIronwoodAnchor!,
          ),
        ],
        seedHex: _testSeedHex,
        ironwoodOutput: const IronwoodBuildOutput(
          address: kIronwoodProofUnifiedAddress,
        ),
        ironwoodChangeZatoshis: change,
        allowExperimentalIronwoodBuild: true,
        bindings: ffi,
      );

      expect(
        quoted.feeZatoshis,
        built.feeZatoshis,
        reason:
            'the quote must be the fee the build charges — this transaction is '
            'about to be accepted and mined at exactly this fee',
      );
      expect(
        quoted.maxIronwoodOutputZatoshis,
        built.ironwoodOutputZatoshis,
        reason:
            'the change was quoted as an output too, so the maximum payable is '
            'exactly what the build paid when it took the remainder',
      );

      expect(built.spendsIronwood, isTrue);
      expect(built.zip318Canonical, isFalse);
      expect(built.version, 'v6');
      expect(built.consensusBranchId, 'nu6.3');
      expect(built.ironwoodInputZatoshis, note.value);
      expect(built.ironwoodChangeZatoshis, change);
      expect(
        built.ironwoodOutputZatoshis,
        note.value - change - built.feeZatoshis,
      );
      expect(built.spendsOrchard, isFalse);
      expect(built.vin, 0);

      final txid = await harness!.client.sendRawTransaction(
        built.transactionHex,
      );
      expect(txid, built.txid);

      final hash = (await harness!.mineBlocks(1)).single;
      final block = await harness!.client.getBlock(hash);
      expect(
        block.transactions,
        contains(built.txid),
        reason:
            'an Ironwood note, created by this repo migrating out of Orchard, '
            'spent by this repo and mined by a real node — the pool is no '
            'longer write-only',
      );
      ironwoodSpendBlockHeight = await harness!.client.getBlockCount();
      ironwoodSpendTxid = built.txid;

      final again = buildNativeIronwoodTransaction(
        network: ZcashNetwork.regtest,
        targetHeight: tip + 2,
        regtestNu63ActivationHeight: nu63Activation,
        anchor: IronwoodAnchorSource.anchor(migratedIronwoodAnchor!),
        inputs: const [],
        ironwoodSpends: [
          IronwoodBuildIronwoodSpendNote.fromScannedNote(
            note,
            anchorHex: migratedIronwoodAnchor!,
          ),
        ],
        seedHex: _testSeedHex,
        ironwoodOutput: const IronwoodBuildOutput(
          address: kIronwoodProofUnifiedAddress,
        ),
        ironwoodChangeZatoshis: change,
        allowExperimentalIronwoodBuild: true,
        bindings: ffi,
      );
      await expectLater(
        harness!.client.sendRawTransaction(again.transactionHex),
        throwsA(isA<ZebraRpcException>()),
        reason:
            'the note is spent; only the network knows that, which is exactly '
            'what a wallet has to track',
      );
    });

    test('the spent Ironwood note is observed spent by a scan', () async {
      if (harness == null || ironwoodSpendBlockHeight == null) return;

      final note = migratedIronwoodNote!;
      final nullifier = note.nullifier;
      expect(
        nullifier,
        isNotNull,
        reason: 'the account key derives its own notes\' nullifiers',
      );

      final rawBlocks = <String>[
        for (var h = shieldBlockHeight!; h <= ironwoodSpendBlockHeight!; h++)
          await harness!.client.getRawBlock('$h'),
      ];
      final converted = ZcashCompactBlockConversion.fromJson(
        _nativeOk(
          ffi!.compactBlocksFromRawBlocks(
            encodeCompactBlockRequest(
              network: 'regtest',
              rawBlockHex: rawBlocks,
              regtestNu63ActivationHeight: nu63Activation,
            ),
          ),
        ),
      );

      final scanned = ZcashScanResult.fromJson(
        _nativeOk(
          ffi!.scanCompactBlocksRaw(
            _regtestScanUfvk(),
            'regtest',
            jsonEncode({'blocks': converted.toScanEntries()}),
          ),
        ),
        allowExperimentalOrchardNotes: true,
      );

      final spends = scanned.spends
          .where((s) => s.nullifier == nullifier)
          .toList();
      expect(
        spends,
        hasLength(1),
        reason:
            'the migrated Ironwood note was spent on this chain, and the '
            'nullifier the scanner exported for it is the one the spending '
            'transaction revealed',
      );
      expect(spends.single.pool, 'ironwood');
      expect(spends.single.height, ironwoodSpendBlockHeight);
      expect(spends.single.tx, _reverseTxidHex(ironwoodSpendTxid!));

      final spentNote = scanned.notes[spends.single.noteIndex!];
      expect(spentNote.pool, 'ironwood');
      expect(spentNote.value, note.value);
      expect(
        spentNote.nullifier,
        nullifier,
        reason: 'the spend must point at the note it spent',
      );
      expect(
        spends.single.tx,
        isNot(spentNote.tx),
        reason:
            'the note arrived in the migration and left in the spend; two '
            'transactions, and both are named the same way',
      );

      final tail = ZcashCompactBlockConversion.fromJson(
        _nativeOk(
          ffi!.compactBlocksFromRawBlocks(
            encodeCompactBlockRequest(
              network: 'regtest',
              rawBlockHex: [
                await harness!.client.getRawBlock('$ironwoodSpendBlockHeight'),
              ],
              regtestNu63ActivationHeight: nu63Activation,
            ),
          ),
        ),
      );
      final incremental = ZcashScanResult.fromJson(
        _nativeOk(
          ffi!.scanCompactBlocksRaw(
            _regtestScanUfvk(),
            'regtest',
            jsonEncode({
              'blocks': tail.toScanEntries(),
              'watched_nullifiers': ZcashWatchedNullifiers(
                ironwood: [nullifier!],
              ).toJson(),
            }),
          ),
        ),
        allowExperimentalOrchardNotes: true,
      );
      expect(incremental.spends, hasLength(1));
      expect(incremental.spends.single.nullifier, nullifier);
      expect(incremental.spends.single.noteIndex, isNull);

      // Spends match on (pool, nullifier), so Orchard finds nothing.
      final crossed = ZcashScanResult.fromJson(
        _nativeOk(
          ffi!.scanCompactBlocksRaw(
            _regtestScanUfvk(),
            'regtest',
            jsonEncode({
              'blocks': tail.toScanEntries(),
              'watched_nullifiers': ZcashWatchedNullifiers(
                orchard: [nullifier],
              ).toJson(),
            }),
          ),
        ),
        allowExperimentalOrchardNotes: true,
      );
      expect(crossed.spends, isEmpty);
    });

    test('the wallet\'s Ironwood balance reflects the spend', () async {
      if (harness == null || ironwoodSpendBlockHeight == null) return;

      final rawBlocks = <String>[
        for (var h = shieldBlockHeight!; h <= ironwoodSpendBlockHeight!; h++)
          await harness!.client.getRawBlock('$h'),
      ];
      final converted = ZcashCompactBlockConversion.fromJson(
        _nativeOk(
          ffi!.compactBlocksFromRawBlocks(
            encodeCompactBlockRequest(
              network: 'regtest',
              rawBlockHex: rawBlocks,
              regtestNu63ActivationHeight: nu63Activation,
            ),
          ),
        ),
      );
      final scanned = ZcashScanResult.fromJson(
        _nativeOk(
          ffi!.scanCompactBlocksRaw(
            _regtestScanUfvk(),
            'regtest',
            jsonEncode({
              'include_orchard_witnesses': true,
              'blocks': converted.toScanEntries(),
            }),
          ),
        ),
        allowExperimentalOrchardNotes: true,
      );

      final notes = IronwoodNoteSet.fromScan(
        notes: scanned.notes,
        spends: scanned.spends,
      );

      final migrated = notes.tracked
          .where((t) => t.note.nullifier == migratedIronwoodNote!.nullifier)
          .toList();
      expect(migrated, hasLength(1));
      expect(
        migrated.single.status,
        IronwoodNoteStatus.spent,
        reason:
            'this note was spent on this chain; a wallet still offering it '
            'would build a transaction the network rejects',
      );
      expect(migrated.single.spend!.height, ironwoodSpendBlockHeight);

      for (final note in notes.spendable) {
        expect(
          note.nullifier,
          isNot(migratedIronwoodNote!.nullifier),
          reason: 'the spent note must not appear in the spendable set',
        );
      }
      expect(
        notes.spendableZatoshis,
        lessThan(notes.spendableZatoshis + migratedIronwoodNote!.value),
      );
      expect(
        notes.spendable,
        isNotEmpty,
        reason:
            'the spend paid Ironwood back to this account, so there is still '
            'spendable value after it',
      );
      expect(notes.hasCompleteSpendComponents, isTrue);
      expect(
        notes.tracked.every((t) => t.note.pool == 'ironwood'),
        isTrue,
        reason: 'the Orchard change note from the migration is not this set\'s',
      );
    });

    test('a payment is selected, priced, built and mined', () async {
      if (harness == null || ironwoodSpendBlockHeight == null) return;

      final rawBlocks = <String>[
        for (var h = shieldBlockHeight!; h <= ironwoodSpendBlockHeight!; h++)
          await harness!.client.getRawBlock('$h'),
      ];
      final converted = ZcashCompactBlockConversion.fromJson(
        _nativeOk(
          ffi!.compactBlocksFromRawBlocks(
            encodeCompactBlockRequest(
              network: 'regtest',
              rawBlockHex: rawBlocks,
              regtestNu63ActivationHeight: nu63Activation,
            ),
          ),
        ),
      );
      final scanned = ZcashScanResult.fromJson(
        _nativeOk(
          ffi!.scanCompactBlocksRaw(
            _regtestScanUfvk(),
            'regtest',
            jsonEncode({
              'include_orchard_witnesses': true,
              'blocks': converted.toScanEntries(),
            }),
          ),
        ),
        allowExperimentalOrchardNotes: true,
      );
      final anchor = scanned.ironwoodAnchor!;
      final available = IronwoodNoteSet.fromScan(
        notes: scanned.notes,
        spends: scanned.spends,
      );
      final tip = await harness!.client.getBlockCount();

      final amount = available.spendableZatoshis ~/ 2;
      var quotes = 0;
      final selection = IronwoodInputSelection.select(
        notes: available,
        amountZatoshis: amount,
        feeForSpends: (spends) {
          quotes += 1;
          return quoteNativeIronwoodFee(
            network: ZcashNetwork.regtest,
            targetHeight: tip + 1,
            regtestNu63ActivationHeight: nu63Activation,
            anchor: IronwoodAnchorSource.anchor(anchor),
            inputs: const [],
            ironwoodSpends: [
              for (final note in spends)
                IronwoodBuildIronwoodSpendNote.fromScannedNote(
                  note,
                  anchorHex: anchor,
                ),
            ],
            seedHex: _testSeedHex,
            ironwoodOutput: const IronwoodBuildOutput(
              address: kIronwoodProofUnifiedAddress,
            ),
            allowExperimentalIronwoodBuild: true,
            bindings: ffi,
          ).feeZatoshis;
        },
      );

      expect(quotes, greaterThan(0), reason: 'the fee came from the builder');
      expect(selection.notes, isNotEmpty);
      expect(
        selection.inputZatoshis,
        selection.amountZatoshis +
            selection.feeZatoshis +
            selection.changeZatoshis,
        reason: 'the selection must balance or the build cannot',
      );

      final built = buildNativeIronwoodTransaction(
        network: ZcashNetwork.regtest,
        targetHeight: tip + 1,
        regtestNu63ActivationHeight: nu63Activation,
        anchor: IronwoodAnchorSource.anchor(anchor),
        inputs: const [],
        ironwoodSpends: [
          for (final note in selection.notes)
            IronwoodBuildIronwoodSpendNote.fromScannedNote(
              note,
              anchorHex: anchor,
            ),
        ],
        seedHex: _testSeedHex,
        ironwoodOutput: IronwoodBuildOutput(
          address: kIronwoodProofUnifiedAddress,
          valueZatoshis: selection.amountZatoshis,
        ),
        ironwoodChangeZatoshis: selection.changeZatoshis,
        allowExperimentalIronwoodBuild: true,
        bindings: ffi,
      );

      expect(
        built.feeZatoshis,
        selection.feeZatoshis,
        reason: 'the selection budgeted the fee the build charges',
      );
      expect(built.ironwoodOutputZatoshis, selection.amountZatoshis);
      expect(built.ironwoodChangeZatoshis, selection.changeZatoshis);
      expect(built.ironwoodInputZatoshis, selection.inputZatoshis);
      expect(built.consensusBranchId, 'nu6.3');

      final txid = await harness!.client.sendRawTransaction(
        built.transactionHex,
      );
      final hash = (await harness!.mineBlocks(1)).single;
      final block = await harness!.client.getBlock(hash);
      expect(
        block.transactions,
        contains(txid),
        reason:
            'inputs chosen from a scan, priced by the builder, spent and mined '
            'by a real node — the send path end to end, minus an API to call '
            'it and something to broadcast for the user',
      );
      paymentBlockHeight = await harness!.client.getBlockCount();
    });

    test('the send API pays out of a scan in one call', () async {
      if (harness == null || paymentBlockHeight == null) return;

      final rawBlocks = <String>[
        for (var h = shieldBlockHeight!; h <= paymentBlockHeight!; h++)
          await harness!.client.getRawBlock('$h'),
      ];
      final converted = ZcashCompactBlockConversion.fromJson(
        _nativeOk(
          ffi!.compactBlocksFromRawBlocks(
            encodeCompactBlockRequest(
              network: 'regtest',
              rawBlockHex: rawBlocks,
              regtestNu63ActivationHeight: nu63Activation,
            ),
          ),
        ),
      );
      final scanned = ZcashScanResult.fromJson(
        _nativeOk(
          ffi!.scanCompactBlocksRaw(
            _regtestScanUfvk(),
            'regtest',
            jsonEncode({
              'include_orchard_witnesses': true,
              'blocks': converted.toScanEntries(),
            }),
          ),
        ),
        allowExperimentalOrchardNotes: true,
      );

      final available = IronwoodNoteSet.fromScan(
        notes: scanned.notes,
        spends: scanned.spends,
      );
      expect(
        available.spendable.length,
        greaterThanOrEqualTo(2),
        reason:
            'the reservation below needs a second note to fall back to; every '
            'payment above paid this account, so the wallet holds several',
      );
      final smallest = available.spendable
          .map((note) => note.value)
          .reduce((a, b) => a < b ? a : b);
      final amount = smallest ~/ 4;
      final tip = await harness!.client.getBlockCount();

      final prepared = prepareNativeIronwoodSend(
        network: ZcashNetwork.regtest,
        scan: scanned,
        toAddress: kIronwoodProofUnifiedAddress,
        amountZatoshis: amount,
        targetHeight: tip + 1,
        seedHex: _testSeedHex,
        regtestNu63ActivationHeight: nu63Activation,
        allowExperimentalIronwoodBuild: true,
        bindings: ffi,
      );

      expect(prepared.plan.notes, isNotEmpty);
      expect(prepared.plan.anchorHex, scanned.ironwoodAnchor);
      expect(
        prepared.plan.anchorHex,
        isNot(scanned.orchardAnchor),
        reason:
            'both anchors are in this scan result and only one is a root '
            'of the tree these notes are in',
      );
      expect(prepared.transaction.consensusBranchId, 'nu6.3');
      expect(prepared.transaction.spendsIronwood, isTrue);
      expect(prepared.transaction.feeZatoshis, prepared.plan.feeZatoshis);
      expect(prepared.transaction.ironwoodOutputZatoshis, amount);

      final reserved = prepareNativeIronwoodSend(
        network: ZcashNetwork.regtest,
        scan: scanned,
        toAddress: kIronwoodProofUnifiedAddress,
        amountZatoshis: amount,
        targetHeight: tip + 1,
        seedHex: _testSeedHex,
        inFlight: [prepared.plan],
        regtestNu63ActivationHeight: nu63Activation,
        allowExperimentalIronwoodBuild: true,
        bindings: ffi,
      );
      final unreserved = prepareNativeIronwoodSend(
        network: ZcashNetwork.regtest,
        scan: scanned,
        toAddress: kIronwoodProofUnifiedAddress,
        amountZatoshis: amount,
        targetHeight: tip + 1,
        seedHex: _testSeedHex,
        regtestNu63ActivationHeight: nu63Activation,
        allowExperimentalIronwoodBuild: true,
        bindings: ffi,
      );

      expect(
        unreserved.plan.spentNullifiers,
        prepared.plan.spentNullifiers,
        reason:
            'selection is deterministic, so without the reservation the second '
            'payment consumes the notes the first one already committed',
      );
      expect(
        reserved.plan.spentNullifiers.intersection(
          prepared.plan.spentNullifiers,
        ),
        isEmpty,
      );

      final txid = await harness!.client.sendRawTransaction(
        prepared.transactionHex,
      );
      expect(txid, prepared.txid);
      final hash = (await harness!.mineBlocks(1)).single;
      final block = await harness!.client.getBlock(hash);
      expect(
        block.transactions,
        contains(txid),
        reason:
            'a payment a wallet could make with one call, mined by a real node',
      );

      await expectLater(
        harness!.client.sendRawTransaction(unreserved.transactionHex),
        throwsA(isA<ZebraRpcException>()),
        reason:
            'the notes are spent as of the block just mined, so this is the '
            'double spend a wallet that reuses a stale scan would broadcast',
      );
      final reservedTxid = await harness!.client.sendRawTransaction(
        reserved.transactionHex,
      );
      final reservedHash = (await harness!.mineBlocks(1)).single;
      expect(
        (await harness!.client.getBlock(reservedHash)).transactions,
        contains(reservedTxid),
        reason:
            'the reserved plan draws on notes the first payment left alone, so '
            'it is still valid against the same anchor and the same scan',
      );
    });

    test('a payment is broadcast and then recognised as confirmed', () async {
      if (harness == null || paymentBlockHeight == null) return;

      Future<ZcashScanResult> scanToTip({
        ZcashWatchedNullifiers? watched,
      }) async {
        final tip = await harness!.client.getBlockCount();
        final rawBlocks = <String>[
          for (var h = shieldBlockHeight!; h <= tip; h++)
            await harness!.client.getRawBlock('$h'),
        ];
        final converted = ZcashCompactBlockConversion.fromJson(
          _nativeOk(
            ffi!.compactBlocksFromRawBlocks(
              encodeCompactBlockRequest(
                network: 'regtest',
                rawBlockHex: rawBlocks,
                regtestNu63ActivationHeight: nu63Activation,
              ),
            ),
          ),
        );
        return ZcashScanResult.fromJson(
          _nativeOk(
            ffi!.scanCompactBlocksRaw(
              _regtestScanUfvk(),
              'regtest',
              jsonEncode({
                'include_orchard_witnesses': true,
                'blocks': converted.toScanEntries(),
                if (watched != null) 'watched_nullifiers': watched.toJson(),
              }),
            ),
          ),
          allowExperimentalOrchardNotes: true,
        );
      }

      final scanned = await scanToTip();
      final available = IronwoodNoteSet.fromScan(
        notes: scanned.notes,
        spends: scanned.spends,
      );
      final smallest = available.spendable
          .map((note) => note.value)
          .reduce((a, b) => a < b ? a : b);
      final tip = await harness!.client.getBlockCount();

      final send = prepareNativeIronwoodSend(
        network: ZcashNetwork.regtest,
        scan: scanned,
        toAddress: kIronwoodProofUnifiedAddress,
        amountZatoshis: smallest ~/ 4,
        targetHeight: tip + 1,
        seedHex: _testSeedHex,
        regtestNu63ActivationHeight: nu63Activation,
        allowExperimentalIronwoodBuild: true,
        bindings: ffi,
      );

      final receipt = await broadcastIronwoodSend(
        send: send,
        chainHeight: tip,
        submit: harness!.client.sendRawTransaction,
        isRejection: (error) => error is ZebraRpcException,
      );

      expect(receipt.txid, send.txid);
      expect(receipt.hasExpiredAt(tip), isFalse);
      expect(
        receipt.scanTxId,
        isNot(receipt.txid),
        reason: 'the two encodings of one hash are not the same string',
      );

      final hash = (await harness!.mineBlocks(1)).single;
      expect(
        (await harness!.client.getBlock(hash)).transactions,
        contains(receipt.txid),
        reason: 'the node speaks the displayed order this receipt carries',
      );

      final after = await scanToTip(
        watched: ZcashWatchedNullifiers(
          ironwood: receipt.committedNullifiers.toList(),
        ),
      );
      expect(
        receipt.isConfirmedBy(after),
        isTrue,
        reason:
            'a wallet that cannot recognise its own transaction after mining '
            'it never releases the notes it committed',
      );
      expect(receipt.confirmationIn(after)!.height, greaterThan(tip));

      final resolved = IronwoodNoteSet.fromScan(
        notes: after.notes,
        spends: after.spends,
      );
      for (final note in resolved.spendable) {
        expect(
          receipt.committedNullifiers.contains(note.nullifier),
          isFalse,
          reason: 'a note this payment spent must not be offered again',
        );
      }
    });

    test('a store resolves a note no single scan can', () async {
      if (harness == null || paymentBlockHeight == null) return;

      Future<ZcashScanResult> scanRange(
        int from,
        int to, {
        ZcashWatchedNullifiers? watched,
        bool witnesses = false,
      }) async {
        final rawBlocks = <String>[
          for (var h = from; h <= to; h++)
            await harness!.client.getRawBlock('$h'),
        ];
        final converted = ZcashCompactBlockConversion.fromJson(
          _nativeOk(
            ffi!.compactBlocksFromRawBlocks(
              encodeCompactBlockRequest(
                network: 'regtest',
                rawBlockHex: rawBlocks,
                regtestNu63ActivationHeight: nu63Activation,
              ),
            ),
          ),
        );
        return ZcashScanResult.fromJson(
          _nativeOk(
            ffi!.scanCompactBlocksRaw(
              _regtestScanUfvk(),
              'regtest',
              jsonEncode({
                if (witnesses) 'include_orchard_witnesses': true,
                'blocks': converted.toScanEntries(),
                if (watched != null) 'watched_nullifiers': watched.toJson(),
              }),
            ),
          ),
          allowExperimentalOrchardNotes: true,
        );
      }

      const fingerprint = 'ironwood-live-proof-account';
      final discoveryFrom = shieldBlockHeight!;
      final discoveryTo = await harness!.client.getBlockCount();

      final discovery = await scanRange(
        discoveryFrom,
        discoveryTo,
        witnesses: true,
      );
      final store = IronwoodNoteStore()
        ..apply(discovery, accountFingerprint: fingerprint);
      expect(store.coveredFrom, discoveryFrom);
      expect(store.coveredThrough, discoveryTo);

      final heldBefore = store.noteSet.unspentZatoshis;
      expect(heldBefore, greaterThan(0));
      expect(store.noteSet.spendableZatoshis, 0);

      final available = IronwoodNoteSet.fromScan(
        notes: discovery.notes,
        spends: discovery.spends,
      );
      final smallest = available.spendable
          .map((note) => note.value)
          .reduce((a, b) => a < b ? a : b);
      final send = prepareNativeIronwoodSend(
        network: ZcashNetwork.regtest,
        scan: discovery,
        toAddress: kIronwoodProofUnifiedAddress,
        amountZatoshis: smallest ~/ 4,
        targetHeight: discoveryTo + 1,
        seedHex: _testSeedHex,
        regtestNu63ActivationHeight: nu63Activation,
        allowExperimentalIronwoodBuild: true,
        bindings: ffi,
      );
      final receipt = await broadcastIronwoodSend(
        send: send,
        chainHeight: discoveryTo,
        submit: harness!.client.sendRawTransaction,
        isRejection: (error) => error is ZebraRpcException,
      );
      await harness!.mineBlocks(1);
      final spendHeight = await harness!.client.getBlockCount();
      expect(spendHeight, discoveryTo + 1);

      final committed = receipt.committedNullifiers.toSet();
      final committedValue = store.notes
          .where((note) => committed.contains(note.nullifier))
          .fold(0, (sum, note) => sum + note.value);
      expect(
        committedValue,
        greaterThan(0),
        reason: 'the notes this payment spent are notes the store already held',
      );

      final blind = await scanRange(discoveryTo + 1, spendHeight);
      expect(
        blind.spends,
        isEmpty,
        reason:
            'nothing in the later range identifies these nullifiers as this '
            'wallet\'s without a watch set',
      );
      expect(
        IronwoodNoteSet.fromScan(
          notes: blind.notes,
          spends: blind.spends,
        ).spent,
        isEmpty,
        reason:
            'the later range contains the spend and not the note it spent, so '
            'a note set built from it alone can resolve nothing',
      );

      final later = await scanRange(
        discoveryTo + 1,
        spendHeight,
        watched: store.watchSet,
      );
      expect(later.spends, isNotEmpty);
      expect(
        later.spends.map((spend) => spend.nullifier).toSet(),
        containsAll(committed),
      );
      expect(
        later.spends.every((spend) => spend.noteIndex == null),
        isTrue,
        reason: 'this scan never saw the notes, which is the ordinary case',
      );

      final restored = IronwoodNoteStore.fromJson(
        jsonDecode(jsonEncode(store.toJson())) as Map<String, Object?>,
      );
      store.apply(later, accountFingerprint: fingerprint);
      restored.apply(later, accountFingerprint: fingerprint);

      expect(
        store.noteSet.spent.map((entry) => entry.note.nullifier).toSet(),
        containsAll(committed),
        reason:
            'the note was discovered by one scan and spent during another, and '
            'the store is the only thing here that holds both',
      );
      final received = later.notes
          .where((note) => note.pool == 'ironwood')
          .fold(0, (sum, note) => sum + note.value);
      expect(
        store.noteSet.unspentZatoshis,
        heldBefore - committedValue + received,
      );
      expect(restored.noteSet.unspentZatoshis, store.noteSet.unspentZatoshis);
      expect(store.coveredFrom, discoveryFrom);
      expect(store.coveredThrough, spendHeight);
      expect(store.noteSet.spendableZatoshis, 0);
    });

    test('a memo is sent, mined, and read back off the chain', () async {
      if (harness == null || paymentBlockHeight == null) return;

      final memo = Uint8List.fromList(utf8.encode('paid, with thanks — 19c'));

      final tipBefore = await harness!.client.getBlockCount();
      final rawBlocks = <String>[
        for (var h = shieldBlockHeight!; h <= tipBefore; h++)
          await harness!.client.getRawBlock('$h'),
      ];
      final converted = ZcashCompactBlockConversion.fromJson(
        _nativeOk(
          ffi!.compactBlocksFromRawBlocks(
            encodeCompactBlockRequest(
              network: 'regtest',
              rawBlockHex: rawBlocks,
              regtestNu63ActivationHeight: nu63Activation,
            ),
          ),
        ),
      );
      final scan = ZcashScanResult.fromJson(
        _nativeOk(
          ffi!.scanCompactBlocksRaw(
            _regtestScanUfvk(),
            'regtest',
            jsonEncode({
              'include_orchard_witnesses': true,
              'blocks': converted.toScanEntries(),
            }),
          ),
        ),
        allowExperimentalOrchardNotes: true,
      );

      final available = IronwoodNoteSet.fromScan(
        notes: scan.notes,
        spends: scan.spends,
      );
      final smallest = available.spendable
          .map((note) => note.value)
          .reduce((a, b) => a < b ? a : b);
      final amount = smallest ~/ 4;

      final withMemo = prepareNativeIronwoodSend(
        network: ZcashNetwork.regtest,
        scan: scan,
        toAddress: kIronwoodProofUnifiedAddress,
        amountZatoshis: amount,
        targetHeight: tipBefore + 1,
        seedHex: _testSeedHex,
        memo: memo,
        regtestNu63ActivationHeight: nu63Activation,
        allowExperimentalIronwoodBuild: true,
        bindings: ffi,
      );
      final withoutMemo = prepareNativeIronwoodSend(
        network: ZcashNetwork.regtest,
        scan: scan,
        toAddress: kIronwoodProofUnifiedAddress,
        amountZatoshis: amount,
        targetHeight: tipBefore + 1,
        seedHex: _testSeedHex,
        regtestNu63ActivationHeight: nu63Activation,
        allowExperimentalIronwoodBuild: true,
        bindings: ffi,
      );
      expect(
        withMemo.plan.feeZatoshis,
        withoutMemo.plan.feeZatoshis,
        reason:
            'a memo adds no action, so it costs nothing — and a caller who '
            're-derived that in Dart would be writing a second ZIP 317',
      );
      expect(
        withMemo.transaction.feeZatoshis,
        withoutMemo.transaction.feeZatoshis,
      );

      final receipt = await broadcastIronwoodSend(
        send: withMemo,
        chainHeight: tipBefore,
        submit: harness!.client.sendRawTransaction,
        isRejection: (error) => error is ZebraRpcException,
      );
      final blockHash = (await harness!.mineBlocks(1)).single;
      expect(
        (await harness!.client.getBlock(blockHash)).transactions,
        contains(receipt.txid),
      );
      final minedHeight = await harness!.client.getBlockCount();

      final afterBlocks = ZcashCompactBlockConversion.fromJson(
        _nativeOk(
          ffi!.compactBlocksFromRawBlocks(
            encodeCompactBlockRequest(
              network: 'regtest',
              rawBlockHex: [await harness!.client.getRawBlock('$minedHeight')],
              regtestNu63ActivationHeight: nu63Activation,
            ),
          ),
        ),
      );
      final after = ZcashScanResult.fromJson(
        _nativeOk(
          ffi!.scanCompactBlocksRaw(
            _regtestScanUfvk(),
            'regtest',
            jsonEncode({'blocks': afterBlocks.toScanEntries()}),
          ),
        ),
        allowExperimentalOrchardNotes: true,
      );
      final delivered = after.notes
          .where((note) => note.pool == 'ironwood' && note.value == amount)
          .toList();
      expect(
        delivered,
        hasLength(1),
        reason: 'the payment arrived, discovered without its memo',
      );

      expect(
        delivered.single.tx,
        isNot(receipt.txid),
        reason: 'the two encodings of one hash are not the same string',
      );
      expect(delivered.single.tx, reverseTxidByteOrder(receipt.txid));
      final rawTransaction = await harness!.client.getRawTransaction(
        receipt.txid,
      );

      final read = <ZcashNoteMemo>[];
      for (var index = 0; index < 8; index++) {
        final memoRead = readNativeNoteMemo(
          network: ZcashNetwork.regtest,
          transactionHex: rawTransaction,
          pool: ZcashMemoPool.ironwood,
          outputIndex: index,
          ufvk: _regtestScanUfvk(),
          minedHeight: minedHeight,
          regtestNu63ActivationHeight: nu63Activation,
          bindings: ffi,
        );
        if (memoRead != null) {
          read.add(memoRead);
        }
      }

      final payment = read.where((m) => m.valueZatoshis == amount).toList();
      expect(payment, hasLength(1));
      expect(
        payment.single.bytes,
        memo,
        reason: 'byte-identical to what the send was given',
      );
      expect(payment.single.text, 'paid, with thanks — 19c');
      expect(payment.single.pool, 'ironwood');

      final change = read.where((m) => m.valueZatoshis != amount).toList();
      expect(
        change,
        isNotEmpty,
        reason: 'this payment left change, and the change note is ours',
      );
      for (final entry in change) {
        expect(entry.isEmpty, isTrue);
        expect(entry.bytes, isNull);
        expect(entry.text, isNull);
      }

      final stranger = deriveNativeAccountMetadata(
        seedHex: '7f' * 32,
        network: ZcashNetwork.regtest,
        bindings: ffi,
      ).ufvk;
      for (var index = 0; index < 8; index++) {
        expect(
          readNativeNoteMemo(
            network: ZcashNetwork.regtest,
            transactionHex: rawTransaction,
            pool: ZcashMemoPool.ironwood,
            outputIndex: index,
            ufvk: stranger,
            minedHeight: minedHeight,
            regtestNu63ActivationHeight: nu63Activation,
            bindings: ffi,
          ),
          isNull,
        );
      }
    });

    test('no Orchard output can be created after activation', () async {
      if (harness == null) return;
      final tip = await harness!.client.getBlockCount();
      expect(
        () => buildNativeOrchardTransaction(
          network: ZcashNetwork.regtest,
          targetHeight: tip + 1,
          regtestNu63ActivationHeight: nu63Activation,
          anchor: const OrchardAnchorSource.tree(''),
          inputs: [
            TransparentBuildInput(
              txid: '22' * 32,
              vout: 0,
              valueZatoshis: 100000,
              secretKeyHex: kIronwoodProofMinerSecretKeyHex,
            ),
          ],
          orchardOutput: const OrchardBuildOutput(
            address: kIronwoodProofUnifiedAddress,
          ),
          allowExperimentalOrchardBuild: true,
          bindings: ffi,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('orchard_pool_closed'),
          ),
        ),
      );
    });
  }, skip: enabled ? false : 'needs ZEBRA_INTEGRATION and ZCASH_FFI_LIB');
}

Map<String, Object?> _nativeOk(String raw) {
  final json = (jsonDecode(raw) as Map).cast<String, Object?>();
  if (json['status'] != 'ok') {
    throw StateError(
      'native build failed [${json['category']}]: ${json['error']}',
    );
  }
  return json;
}

const _testSeedHex =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'
    '202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f';

String _reverseTxidHex(String txid) {
  final bytes = [
    for (var i = 0; i < txid.length; i += 2) txid.substring(i, i + 2),
  ];
  return bytes.reversed.join();
}

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
