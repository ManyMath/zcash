@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zcash_flutter/zcash_flutter.dart';
import 'harness.dart';

// Needs an Ironwood-aware ZEBRA_BIN, the Sapling MPC parameters in
// ZCASH_SAPLING_SPEND_PARAMS/OUTPUT_PARAMS, and a ZCASH_FFI_LIB with
// sapling-spend-build, orchard-tx-build, ironwood-tx-build,
// orchard-note-discovery and ironwood-note-discovery.
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
      ffiLib.isNotEmpty &&
      spendParams.isNotEmpty &&
      outputParams.isNotEmpty;

  ZebraHarness? harness;
  ZcashFfiBindings? ffi;
  String? saplingAddress;
  int? shieldBlockHeight;
  int? shieldedValue;
  ZcashScannedNote? shieldedNote;
  String? saplingAnchor;
  String? spendTxHex;
  String? spendTxid;
  int? spendFeeZatoshis;
  int? spendBlockHeight;

  setUpAll(() async {
    if (!enabled) return;
    ffi = ZcashFfiBindings.open(ffiLib);
    harness = await ZebraHarness.start(
      nu63ActivationHeight: nu63Activation,
      minerAddress: kIronwoodProofMinerAddress,
    );
    await harness!.mineBlocks(maturityHeight);
    await _mineTo(harness!, nu63Activation + 2);
  });

  tearDownAll(() async {
    if (harness == null) return;
    await harness!.shutdown();
    harness = null;
  });

  group(
    'Live Sapling send',
    () {
      test('the chain is past NU6.3 and holds a spendable coinbase', () async {
        if (harness == null) return;
        final info = await harness!.client.getBlockchainInfo();
        expect(
          info.upgrades['37a5165b']!.status,
          'active',
          reason: 'the whole proof runs on the branch mainnet is on',
        );

        final decoded = _nativeOk(
          ffi!.ufvkToAddress(_regtestScanUfvk(ffiLib), 'regtest', 0),
        );
        final receivers = (decoded['addresses'] as Map).cast<String, Object?>();
        saplingAddress = receivers['sapling'] as String?;
        expect(
          saplingAddress,
          startsWith('zregtestsapling'),
          reason:
              'the note has to be paid to a regtest-encoded Sapling receiver, or '
              'the regtest builder will not decode it — the failure 13h closed',
        );
      });

      test('a transparent coinbase is shielded into the Sapling pool', () async {
        if (harness == null || saplingAddress == null) return;

        final tip = await harness!.client.getBlockCount();
        final utxos = await harness!.client.getAddressUtxos([
          kIronwoodProofMinerAddress,
        ]);
        final matured = utxos.where((u) => u.height <= tip - 100).toList();
        expect(
          matured,
          isNotEmpty,
          reason: 'need a matured coinbase to shield',
        );
        final coinbase = matured.first;
        final inputs = [
          TransparentBuildInput(
            txid: coinbase.txid,
            vout: coinbase.outputIndex,
            valueZatoshis: coinbase.satoshis,
            secretKeyHex: kIronwoodProofMinerSecretKeyHex,
          ),
        ];
        final quote = quoteNativeSaplingFee(
          network: ZcashNetwork.regtest,
          targetHeight: tip + 1,
          regtestNu63ActivationHeight: nu63Activation,
          seedHex: _testSeedHex,
          inputs: inputs,
          outputs: [SaplingBuildOutput(address: saplingAddress!)],
          allowExperimentalSaplingBuild: true,
          bindings: ffi,
        );
        expect(quote.feeRule, 'zip317');
        expect(quote.consensusBranchId, 'nu6.3');
        expect(quote.isFunded, isTrue);
        expect(quote.totalInputZatoshis, coinbase.satoshis);

        final built = buildNativeSaplingTransaction(
          network: ZcashNetwork.regtest,
          targetHeight: tip + 1,
          regtestNu63ActivationHeight: nu63Activation,
          seedHex: _testSeedHex,
          inputs: inputs,
          outputs: [SaplingBuildOutput(address: saplingAddress!)],
          spendParamsPath: spendParams,
          outputParamsPath: outputParams,
          allowExperimentalSaplingBuild: true,
          bindings: ffi,
        );

        expect(
          built.feeZatoshis,
          quote.feeZatoshis,
          reason:
              'the quote must be the fee the build charges — this transaction is '
              'about to be accepted and mined at exactly this fee',
        );
        expect(
          built.totalOutputZatoshis,
          quote.maxOutputZatoshis,
          reason:
              'the remainder output took exactly what the quote said it could',
        );

        expect(
          built.hasRealProofs,
          isTrue,
          reason:
              'the mock prover produces all-zero proofs; a node rejects those, '
              'and this suite would then be proving nothing',
        );
        expect(built.consensusBranchId, 'nu6.3');
        expect(built.version, 'v6');
        expect(built.transparentVin, 1);
        expect(built.transparentVout, 0);
        expect(built.transparentInputZatoshis, coinbase.satoshis);
        expect(built.saplingSpends, 0);
        expect(built.totalSpentZatoshis, 0);

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
          reason:
              'value entering the Sapling pool, mined by a real node — the note '
              'the rest of this file spends',
        );
        shieldBlockHeight = await harness!.client.getBlockCount();
        shieldedValue = built.totalOutputZatoshis;
      });

      test(
        'the shielded note is discovered by a scan with no lightwalletd',
        () async {
          if (harness == null || shieldBlockHeight == null) return;

          final scanned = _scanRange(ffi!, ffiLib, [
            await harness!.client.getRawBlock('$shieldBlockHeight'),
          ], nu63Activation);

          final notes = scanned.notes
              .where((n) => n.pool == 'sapling')
              .toList();
          expect(
            notes,
            hasLength(1),
            reason:
                'the shielding transaction created exactly one Sapling note',
          );
          final note = notes.single;
          expect(note.value, shieldedValue);
          expect(note.recipient, saplingAddress);
          expect(
            note.rseed,
            isNotNull,
            reason:
                'a note cannot be rebuilt for a spend without its randomness',
          );
          expect(note.witness, isNotNull);
          expect(note.nullifier, isNotNull);
          expect(scanned.saplingAnchor, isNotNull);
          expect(
            scanned.orchardAnchor,
            isNull,
            reason:
                'nothing has been paid into an Orchard-family pool on this chain, '
                'and an anchor from the wrong tree is the mistake this shape of '
                'result exists to make impossible',
          );

          shieldedNote = note;
          saplingAnchor = scanned.saplingAnchor;
        },
      );

      test('the scanned note is spent, broadcast and mined', () async {
        if (harness == null || shieldedNote == null) return;

        final note = shieldedNote!;
        final tip = await harness!.client.getBlockCount();

        final spendNotes = [
          SaplingBuildSpendNote(
            valueZatoshis: note.value,
            recipientAddress: note.recipient,
            rseedHex: note.rseed,
            witnessHex: note.witness,
            anchorHex: saplingAnchor,
          ),
        ];
        final quote = quoteNativeSaplingFee(
          network: ZcashNetwork.regtest,
          targetHeight: tip + 1,
          regtestNu63ActivationHeight: nu63Activation,
          seedHex: _testSeedHex,
          spendNotes: spendNotes,
          outputs: [SaplingBuildOutput(address: saplingAddress!)],
          allowExperimentalSaplingBuild: true,
          bindings: ffi,
        );
        expect(quote.saplingSpends, 1);
        expect(quote.totalInputZatoshis, note.value);
        expect(quote.isFunded, isTrue);

        final built = buildNativeSaplingTransaction(
          network: ZcashNetwork.regtest,
          targetHeight: tip + 1,
          regtestNu63ActivationHeight: nu63Activation,
          seedHex: _testSeedHex,
          spendNotes: spendNotes,
          outputs: [SaplingBuildOutput(address: saplingAddress!)],
          spendParamsPath: spendParams,
          outputParamsPath: outputParams,
          allowExperimentalSaplingBuild: true,
          bindings: ffi,
        );

        expect(built.feeZatoshis, quote.feeZatoshis);
        expect(built.totalOutputZatoshis, quote.maxOutputZatoshis);
        expect(built.hasRealProofs, isTrue);
        expect(built.consensusBranchId, 'nu6.3');
        expect(built.version, 'v6');
        expect(built.saplingSpends, 1);
        expect(built.transparentVin, 0);
        expect(built.totalSpentZatoshis, note.value);

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
              'a Sapling note this repo created, scanned, and spent — accepted '
              'and mined by a real node under NU6.3',
        );
        spendTxHex = built.transactionHex;
        spendTxid = built.txid;
        spendFeeZatoshis = built.feeZatoshis;
        spendBlockHeight = await harness!.client.getBlockCount();
      });

      test('the same spend is refused the second time', () async {
        if (harness == null || spendTxHex == null) return;
        await expectLater(
          harness!.client.sendRawTransaction(spendTxHex!),
          throwsA(isA<ZebraRpcException>()),
        );
      });

      test('a rescan sees the note spent and the payment arrive', () async {
        if (harness == null || spendBlockHeight == null) return;

        final rawBlocks = <String>[
          for (var h = shieldBlockHeight!; h <= spendBlockHeight!; h++)
            await harness!.client.getRawBlock('$h'),
        ];
        final scanned = _scanRange(
          ffi!,
          ffiLib,
          rawBlocks,
          nu63Activation,
          watched: ZcashWatchedNullifiers(sapling: [shieldedNote!.nullifier!]),
        );

        final spends = scanned.spends
            .where((s) => s.nullifier == shieldedNote!.nullifier)
            .toList();
        expect(
          spends,
          hasLength(1),
          reason:
              'the note was spent on this chain, and the nullifier the scanner '
              'exported for it is the one the spending transaction revealed — a '
              'comparison no offline test can make',
        );
        expect(spends.single.pool, 'sapling');
        expect(spends.single.height, spendBlockHeight);
        // Scans use protocol byte order; RPC txids are displayed (reversed).
        expect(spends.single.tx, reverseTxidByteOrder(spendTxid!));

        final arrived = scanned.notes
            .where((n) => n.pool == 'sapling' && n.height == spendBlockHeight)
            .toList();
        expect(arrived, hasLength(1));
        expect(
          arrived.single.value,
          shieldedNote!.value - spendFeeZatoshis!,
          reason:
              'the payment took the remainder, which is the note minus the fee '
              'the builder quoted and the node accepted',
        );
        expect(
          arrived.single.nullifier,
          isNot(shieldedNote!.nullifier),
          reason: 'a new note has its own nullifier',
        );

        final tail = [await harness!.client.getRawBlock('$spendBlockHeight')];
        final incremental = _scanRange(
          ffi!,
          ffiLib,
          tail,
          nu63Activation,
          watched: ZcashWatchedNullifiers(sapling: [shieldedNote!.nullifier!]),
        );
        expect(incremental.spends, hasLength(1));
        expect(incremental.spends.single.nullifier, shieldedNote!.nullifier);
        expect(
          incremental.spends.single.noteIndex,
          isNull,
          reason: 'this scan never saw the note, which is the ordinary case',
        );

        // Spends match on (pool, nullifier), so Ironwood finds nothing.
        final crossed = _scanRange(
          ffi!,
          ffiLib,
          tail,
          nu63Activation,
          watched: ZcashWatchedNullifiers(ironwood: [shieldedNote!.nullifier!]),
        );
        expect(crossed.spends, isEmpty);
      });

      test('the send API pays out of a scan in one call', () async {
        if (harness == null || spendBlockHeight == null) return;

        final tip = await harness!.client.getBlockCount();
        final rawBlocks = <String>[
          for (var h = shieldBlockHeight!; h <= tip; h++)
            await harness!.client.getRawBlock('$h'),
        ];
        final scanned = _scanRange(ffi!, ffiLib, rawBlocks, nu63Activation);

        final available = SaplingNoteSet.fromScan(
          notes: scanned.notes,
          spends: scanned.spends,
        );
        expect(
          available.spendable,
          isNotEmpty,
          reason:
              'the spend above paid this account, so it still holds Sapling',
        );
        expect(
          available.tracked.any(
            (entry) => entry.status == SaplingNoteStatus.spent,
          ),
          isTrue,
          reason: 'the note the previous steps spent must be resolved as gone',
        );

        final smallest = available.spendable
            .map((note) => note.value)
            .reduce((a, b) => a < b ? a : b);
        final amount = smallest ~/ 4;

        final prepared = prepareNativeSaplingSend(
          network: ZcashNetwork.regtest,
          scan: scanned,
          toAddress: saplingAddress!,
          changeAddress: saplingAddress!,
          amountZatoshis: amount,
          targetHeight: tip + 1,
          seedHex: _testSeedHex,
          spendParamsPath: spendParams,
          outputParamsPath: outputParams,
          regtestNu63ActivationHeight: nu63Activation,
          allowExperimentalSaplingBuild: true,
          bindings: ffi,
        );

        expect(prepared.plan.notes, isNotEmpty);
        expect(prepared.plan.anchorHex, scanned.saplingAnchor);
        expect(prepared.transaction.consensusBranchId, 'nu6.3');
        expect(prepared.transaction.hasRealProofs, isTrue);
        expect(prepared.transaction.feeZatoshis, prepared.plan.feeZatoshis);
        expect(
          prepared.transaction.totalOutputZatoshis,
          prepared.plan.amountZatoshis + prepared.plan.changeZatoshis,
        );

        final txid = await harness!.client.sendRawTransaction(
          prepared.transactionHex,
        );
        expect(txid, prepared.txid);
        final hash = (await harness!.mineBlocks(1)).single;
        expect(
          (await harness!.client.getBlock(hash)).transactions,
          contains(txid),
          reason:
              'a Sapling payment a wallet could make with one call, mined by a '
              'real node',
        );

        final afterTip = await harness!.client.getBlockCount();
        final after = _scanRange(ffi!, ffiLib, [
          for (var h = shieldBlockHeight!; h <= afterTip; h++)
            await harness!.client.getRawBlock('$h'),
        ], nu63Activation);
        final held = SaplingNoteSet.fromScan(
          notes: after.notes,
          spends: after.spends,
        );
        expect(held.spendable.length, greaterThanOrEqualTo(2));

        final nextAmount =
            held.spendable
                .map((note) => note.value)
                .reduce((a, b) => a < b ? a : b) ~/
            4;
        SaplingPreparedSend plan({
          Iterable<SaplingSendPlan> inFlight = const [],
        }) => prepareNativeSaplingSend(
          network: ZcashNetwork.regtest,
          scan: after,
          toAddress: saplingAddress!,
          changeAddress: saplingAddress!,
          amountZatoshis: nextAmount,
          targetHeight: afterTip + 1,
          seedHex: _testSeedHex,
          spendParamsPath: spendParams,
          outputParamsPath: outputParams,
          inFlight: inFlight,
          regtestNu63ActivationHeight: nu63Activation,
          allowExperimentalSaplingBuild: true,
          bindings: ffi,
        );

        final first = plan();
        final unreserved = plan();
        final reserved = plan(inFlight: [first.plan]);

        expect(
          unreserved.plan.spentNullifiers,
          first.plan.spentNullifiers,
          reason:
              'selection is deterministic, so without the reservation the second '
              'payment consumes the notes the first one already committed',
        );
        expect(
          reserved.plan.spentNullifiers.intersection(
            first.plan.spentNullifiers,
          ),
          isEmpty,
        );

        await harness!.client.sendRawTransaction(first.transactionHex);
        final firstHash = (await harness!.mineBlocks(1)).single;
        expect(
          (await harness!.client.getBlock(firstHash)).transactions,
          contains(first.txid),
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
        if (harness == null || spendBlockHeight == null) return;

        Future<ZcashScanResult> scanToTip({
          ZcashWatchedNullifiers? watched,
        }) async {
          final tip = await harness!.client.getBlockCount();
          return _scanRange(
            ffi!,
            ffiLib,
            [
              for (var h = shieldBlockHeight!; h <= tip; h++)
                await harness!.client.getRawBlock('$h'),
            ],
            nu63Activation,
            watched: watched,
          );
        }

        final scanned = await scanToTip();
        final available = SaplingNoteSet.fromScan(
          notes: scanned.notes,
          spends: scanned.spends,
        );
        final smallest = available.spendable
            .map((note) => note.value)
            .reduce((a, b) => a < b ? a : b);
        final tip = await harness!.client.getBlockCount();

        final send = prepareNativeSaplingSend(
          network: ZcashNetwork.regtest,
          scan: scanned,
          toAddress: saplingAddress!,
          changeAddress: saplingAddress!,
          amountZatoshis: smallest ~/ 4,
          targetHeight: tip + 1,
          seedHex: _testSeedHex,
          spendParamsPath: spendParams,
          outputParamsPath: outputParams,
          regtestNu63ActivationHeight: nu63Activation,
          allowExperimentalSaplingBuild: true,
          bindings: ffi,
        );

        final receipt = await broadcastSaplingSend(
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
            sapling: receipt.committedNullifiers.toList(),
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

        final resolved = SaplingNoteSet.fromScan(
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
    },
    skip: enabled
        ? false
        : 'needs ZEBRA_INTEGRATION, ZCASH_FFI_LIB, and the Sapling MPC parameters',
  );
}

ZcashScanResult _scanRange(
  ZcashFfiBindings ffi,
  String ffiLib,
  List<String> rawBlockHex,
  int nu63Activation, {
  ZcashWatchedNullifiers? watched,
}) {
  final converted = ZcashCompactBlockConversion.fromJson(
    _nativeOk(
      ffi.compactBlocksFromRawBlocks(
        encodeCompactBlockRequest(
          network: 'regtest',
          rawBlockHex: rawBlockHex,
          regtestNu63ActivationHeight: nu63Activation,
        ),
      ),
    ),
  );
  return ZcashScanResult.fromJson(
    _nativeOk(
      ffi.scanCompactBlocksRaw(
        _regtestScanUfvk(ffiLib),
        'regtest',
        jsonEncode({
          'include_sapling_witnesses': true,
          'blocks': converted.toScanEntries(),
          if (watched != null) 'watched_nullifiers': watched.toJson(),
        }),
      ),
    ),
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

const _testSeedHex =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'
    '202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f';

String _regtestScanUfvk(String ffiLib) {
  final metadata = deriveNativeAccountMetadata(
    seedHex: _testSeedHex,
    network: ZcashNetwork.regtest,
    bindings: ZcashFfiBindings.open(ffiLib),
  );
  return metadata.ufvk;
}

Future<void> _mineTo(ZebraHarness harness, int height) async {
  final current = await harness.client.getBlockCount();
  if (current >= height) return;
  await harness.mineBlocks(height - current);
}
