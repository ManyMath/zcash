import 'dart:convert';

import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

const _anchor =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
const _recipient = 'uregtest1recipient';
const _txid =
    '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';

ZcashScannedNote _note(String nullifier, int value) => ZcashScannedNote(
  height: 200,
  tx: 'aa' * 32,
  output: nullifier.codeUnitAt(1),
  value: value,
  pool: 'ironwood',
  nullifier: nullifier,
  commitmentPosition: 0,
  recipient: 'uregtest1change',
  rseed: '11' * 32,
  rho: '22' * 32,
  noteVersion: 'v3',
  witness: '33' * 40,
);

ZcashScanResult _scan(List<ZcashScannedNote> notes) => ZcashScanResult(
  scannedBlocks: 1,
  discoveredNotes: notes.length,
  totalValue: notes.fold(0, (sum, note) => sum + note.value),
  notes: notes,
  ironwoodAnchor: _anchor,
);

int _fee(List<ZcashScannedNote> notes) => 10000;

IronwoodSendPlan _plan(
  ZcashScanResult scan, {
  IronwoodNoteReservations? reservations,
  int targetHeight = 300,
}) => IronwoodSendPlan.fromScan(
  scan: scan,
  recipientAddress: _recipient,
  amountZatoshis: 50000,
  targetHeight: targetHeight,
  feeForSpends: _fee,
  reservations: reservations,
);

IronwoodPreparedSend _prepared(IronwoodSendPlan plan) => IronwoodPreparedSend(
  plan: plan,
  transaction: IronwoodBuildResult(
    network: ZcashAddressNetwork.regtest,
    transactionHex: 'ff' * 20,
    txid: _txid,
    version: 'v6',
    expiryHeight: 340,
    feeZatoshis: plan.feeZatoshis,
    feeRule: 'zip317',
    proofValidity: 'real',
    ironwoodAnchor: plan.anchorHex,
    ironwoodAnchorSource: 'anchor',
    vin: 0,
    vout: 0,
    ironwoodActions: 2,
    ironwoodSpends: plan.notes.length,
    ironwoodChangeOutputs: 1,
    totalInputZatoshis: plan.inputZatoshis,
    ironwoodInputZatoshis: plan.inputZatoshis,
    ironwoodChangeZatoshis: plan.changeZatoshis,
    nonIronwoodOutputZatoshis: 0,
    ironwoodOutputZatoshis: plan.amountZatoshis,
    rng: 'system',
  ),
);

ProposalOutput _paymentOutput(IronwoodDestinationPool destination) {
  final isSapling = destination == IronwoodDestinationPool.sapling;
  if (!isSapling && destination != IronwoodDestinationPool.transparent) {
    throw ArgumentError.value(destination, 'destination');
  }
  final receiver = isSapling
      ? ZcashAddressReceiverType.sapling
      : ZcashAddressReceiverType.p2pkh;
  return resolveProposalOutput(
    recipient: ProposalRecipient(
      address: isSapling
          ? 'zregtestExactSaplingReceiver'
          : 'tmExactTransparentReceiver',
      amountZatoshis: 50000,
      pool: isSapling
          ? ProposalOutputPool.sapling
          : ProposalOutputPool.transparent,
    ),
    address: ZcashAddressMetadata(
      network: ZcashAddressNetwork.regtest,
      receiverType: receiver,
      pool: isSapling ? ZcashAddressPool.sapling : ZcashAddressPool.transparent,
      receivers: ZcashAddressReceiverPresence(
        sprout: false,
        orchard: false,
        sapling: isSapling,
        transparent: !isSapling,
        transparentKind: isSapling ? null : 'p2pkh',
        unknown: 0,
        total: 1,
      ),
    ),
    network: ZcashAddressNetwork.regtest,
    targetHeight: 300,
    transactionExpiryHeight: 340,
    currentUnixTime: 1000,
  );
}

IronwoodPreparedPayment _preparedPayment(
  IronwoodDestinationPool destination, {
  String txid = _txid,
}) {
  final output = _paymentOutput(destination);
  final plan = IronwoodPaymentPlan.fromScan(
    scan: _scan([_note('a1' * 32, 100000)]),
    output: output,
    targetHeight: 300,
    expiryHeight: 340,
    feeForSpends: _fee,
  );
  final isSapling = destination == IronwoodDestinationPool.sapling;
  return IronwoodPreparedPayment(
    plan: plan,
    transaction: IronwoodBuildResult(
      network: ZcashAddressNetwork.regtest,
      transactionHex: 'ee' * 20,
      txid: txid,
      version: 'v6',
      expiryHeight: 340,
      feeZatoshis: plan.feeZatoshis,
      feeRule: 'zip317',
      proofValidity: 'real',
      ironwoodAnchor: plan.anchorHex,
      ironwoodAnchorSource: 'anchor',
      vin: 0,
      vout: isSapling ? 0 : 1,
      saplingOutputs: isSapling ? 2 : 0,
      ironwoodActions: 1,
      ironwoodSpends: plan.notes.length,
      totalInputZatoshis: plan.inputZatoshis,
      ironwoodInputZatoshis: plan.inputZatoshis,
      nonIronwoodOutputZatoshis: plan.amountZatoshis,
      ironwoodOutputZatoshis: plan.changeZatoshis,
      rng: 'system',
    ),
  );
}

void main() {
  for (final destination in const [
    IronwoodDestinationPool.transparent,
    IronwoodDestinationPool.sapling,
  ]) {
    test(
      '${destination.name} payment remains exact and reserved across restart',
      () {
        final payment = _preparedPayment(destination);
        final pending = IronwoodPendingSendState()
          ..addPreparedPayment(payment, createdHeight: 299);

        final restored = IronwoodPendingSendState.fromJson(
          (jsonDecode(jsonEncode(pending.toJson())) as Map)
              .cast<String, Object?>(),
        );
        final record = restored.records.single;
        expect(record.actualDestinationPool, destination);
        expect(record.recipient, payment.plan.output.encodedAddress);
        expect(record.sourcePool, ShieldedPendingSourcePool.ironwood);
        expect(record.selectedNullifiers, payment.plan.spentNullifiers);
        expect(restored.reservedNullifiersAt(300), {'a1' * 32});
        expect(
          restored.requireBroadcastablePayment(payment, chainHeight: 300),
          same(record),
        );
      },
    );
  }

  test(
    'a rejected transparent payment releases its exact reservation',
    () async {
      final payment = _preparedPayment(IronwoodDestinationPool.transparent);
      final pending = IronwoodPendingSendState()
        ..addPreparedPayment(payment, createdHeight: 299);

      await expectLater(
        broadcastIronwoodPayment(
          payment: payment,
          pendingSends: pending,
          chainHeight: 300,
          isRejection: (_) => true,
          submit: (_) async => throw StateError('mempool rejection'),
        ),
        throwsA(
          isA<IronwoodBroadcastException>().having(
            (error) => error.refusal,
            'refusal',
            IronwoodBroadcastRefusal.rejected,
          ),
        ),
      );

      expect(pending.records, isEmpty);
      expect(pending.reservedNullifiersAt(300), isEmpty);
    },
  );

  test(
    'an indeterminate Sapling payment remains reserved after restart',
    () async {
      final payment = _preparedPayment(IronwoodDestinationPool.sapling);
      final pending = IronwoodPendingSendState()
        ..addPreparedPayment(payment, createdHeight: 299);

      await expectLater(
        broadcastIronwoodPayment(
          payment: payment,
          pendingSends: pending,
          chainHeight: 300,
          submit: (_) async => throw StateError('connection reset'),
        ),
        throwsA(
          isA<IronwoodBroadcastException>().having(
            (error) => error.refusal,
            'refusal',
            IronwoodBroadcastRefusal.undetermined,
          ),
        ),
      );

      final restored = IronwoodPendingSendState.fromJson(pending.toJson());
      expect(
        restored.records.single.broadcastState,
        IronwoodPendingBroadcastState.indeterminate,
      );
      expect(restored.reservedNullifiersAt(300), {'a1' * 32});
    },
  );

  test(
    'an acknowledged transparent payment returns the exact receipt',
    () async {
      final payment = _preparedPayment(IronwoodDestinationPool.transparent);
      final pending = IronwoodPendingSendState()
        ..addPreparedPayment(payment, createdHeight: 299);

      final receipt = await broadcastIronwoodPayment(
        payment: payment,
        pendingSends: pending,
        chainHeight: 300,
        submit: (transactionHex) async {
          expect(transactionHex, payment.transactionHex);
          return payment.txid;
        },
      );

      expect(receipt.plan, same(payment.plan));
      expect(receipt.txid, payment.txid);
      expect(receipt.expiryHeight, payment.expiryHeight);
      expect(receipt.broadcastAtHeight, 300);
      expect(receipt.committedNullifiers, payment.plan.spentNullifiers);
      expect(
        pending.records.single.broadcastState,
        IronwoodPendingBroadcastState.acknowledged,
      );
    },
  );

  test('restart before confirmation keeps every selected note reserved', () {
    final notes = [_note('a1' * 32, 100000), _note('a2' * 32, 900000)];
    final scan = _scan(notes);
    final first = _plan(scan);
    final pending = IronwoodPendingSendState()
      ..addPrepared(
        _prepared(first),
        actualDestinationPool: IronwoodDestinationPool.ironwood,
        createdHeight: 299,
      );

    final restored = IronwoodPendingSendState.fromJson(
      (jsonDecode(jsonEncode(pending.toJson())) as Map).cast<String, Object?>(),
    );
    final record = restored.records.single;
    expect(record.transactionHex, 'ff' * 20);
    expect(record.txid, _txid);
    expect(record.selectedNullifiers, {'a1' * 32});
    expect(record.recipient, _recipient);
    expect(record.actualDestinationPool, IronwoodDestinationPool.ironwood);
    expect(record.amountZatoshis, 50000);
    expect(record.feeZatoshis, 10000);
    expect(record.expiryHeight, 340);
    expect(record.createdHeight, 299);
    expect(record.broadcastState, IronwoodPendingBroadcastState.prepared);
    expect(restored.toString(), isNot(contains(record.transactionHex)));
    expect(restored.toString(), isNot(contains(_recipient)));

    final second = _plan(scan, reservations: restored);
    expect(second.spentNullifiers, {'a2' * 32});
  });

  test('wallet state serialization owns the pending reservations', () {
    final scan = _scan([_note('a1' * 32, 100000)]);
    final prepared = _prepared(_plan(scan));
    final wallet = ZcashWalletSyncState.atBirthday(
      network: ZcashAddressNetwork.regtest,
      cursor: ZcashLightwalletdSyncCursor.origin(height: 300),
      accountFingerprint: 'account-0',
    );
    wallet.pendingIronwoodSends.addPrepared(
      prepared,
      actualDestinationPool: IronwoodDestinationPool.ironwood,
      createdHeight: 299,
    );

    final restored = ZcashWalletSyncState.fromJson(
      (jsonDecode(jsonEncode(wallet.toJson())) as Map).cast<String, Object?>(),
    );

    expect(restored.pendingIronwoodSends.records.single.txid, _txid);
    expect(
      () => _plan(scan, reservations: restored.pendingIronwoodSends),
      throwsA(
        isA<IronwoodSendException>().having(
          (error) => error.refusal,
          'refusal',
          IronwoodSendRefusal.notesInFlight,
        ),
      ),
    );
  });

  test('an indeterminate submission remains reserved across restart', () async {
    final scan = _scan([_note('a1' * 32, 100000)]);
    final plan = _plan(scan);
    final prepared = _prepared(plan);
    final pending = IronwoodPendingSendState()
      ..addPrepared(
        prepared,
        actualDestinationPool: IronwoodDestinationPool.ironwood,
        createdHeight: 299,
      );

    await expectLater(
      broadcastIronwoodSend(
        send: prepared,
        pendingSends: pending,
        chainHeight: 300,
        submit: (_) async => throw Exception('connection reset'),
      ),
      throwsA(
        isA<IronwoodBroadcastException>().having(
          (error) => error.refusal,
          'refusal',
          IronwoodBroadcastRefusal.undetermined,
        ),
      ),
    );

    expect(
      pending.records.single.broadcastState,
      IronwoodPendingBroadcastState.indeterminate,
    );
    final restored = IronwoodPendingSendState.fromJson(pending.toJson());
    expect(restored.reservedNullifiersAt(300), {'a1' * 32});
  });

  test(
    'expiry releases notes but requires a newly built transaction',
    () async {
      final note = _note('a1' * 32, 100000);
      final scan = _scan([note]);
      final plan = _plan(scan);
      final prepared = _prepared(plan);
      final pending = IronwoodPendingSendState()
        ..addPrepared(
          prepared,
          actualDestinationPool: IronwoodDestinationPool.ironwood,
          createdHeight: 299,
        );

      expect(pending.reservedNullifiersAt(339), {'a1' * 32});
      expect(pending.reservedNullifiersAt(340), isEmpty);
      expect(
        _plan(scan, reservations: pending, targetHeight: 341).spentNullifiers,
        {'a1' * 32},
      );

      await expectLater(
        broadcastIronwoodSend(
          send: prepared,
          pendingSends: pending,
          chainHeight: 340,
          submit: (_) async => _txid,
        ),
        throwsA(
          isA<IronwoodPendingSendException>()
              .having(
                (error) => error.refusal,
                'refusal',
                IronwoodPendingSendRefusal.expiredRequiresRebuild,
              )
              .having(
                (error) => error.message,
                'message',
                contains('build a new transaction'),
              ),
        ),
      );
    },
  );

  test('recovered durable records are revalidated at broadcast time', () {
    final scan = _scan([_note('a1' * 32, 100000)]);
    final prepared = _prepared(_plan(scan));
    final pending = IronwoodPendingSendState()
      ..addPrepared(
        prepared,
        actualDestinationPool: IronwoodDestinationPool.ironwood,
        createdHeight: 299,
      );
    final recovered = IronwoodPendingSendRecord.fromJson(
      (jsonDecode(jsonEncode(pending.records.single.toJson())) as Map)
          .cast<String, Object?>(),
    );

    expect(
      () => pending.requireBroadcastableRecord(
        recovered,
        chainHeight: recovered.expiryHeight,
      ),
      throwsA(
        isA<IronwoodPendingSendException>().having(
          (error) => error.refusal,
          'refusal',
          IronwoodPendingSendRefusal.expiredRequiresRebuild,
        ),
      ),
    );
  });

  test('a matching mined spend confirms the durable pending send', () async {
    final scan = _scan([_note('a1' * 32, 100000)]);
    final plan = _plan(scan);
    final prepared = _prepared(plan);
    final pending = IronwoodPendingSendState()
      ..addPrepared(
        prepared,
        actualDestinationPool: IronwoodDestinationPool.ironwood,
        createdHeight: 299,
      );
    await broadcastIronwoodSend(
      send: prepared,
      pendingSends: pending,
      chainHeight: 300,
      submit: (_) async => _txid,
    );

    pending.reconcileWithScan(
      scan: ZcashScanResult(
        scannedBlocks: 1,
        discoveredNotes: 0,
        totalValue: 0,
        notes: const [],
        spends: [
          ZcashObservedSpend(
            height: 305,
            tx: reverseTxidByteOrder(_txid),
            pool: 'ironwood',
            nullifier: 'a1' * 32,
            index: 0,
          ),
        ],
      ),
      canonicalBlockHashAt: (height) => height == 305 ? 'bb' * 32 : null,
      scannedBlockHashAt: (height) => height == 305 ? 'bb' * 32 : null,
    );

    final confirmed = pending.records.single;
    expect(
      confirmed.broadcastState,
      IronwoodPendingBroadcastState.acknowledged,
    );
    expect(confirmed.confirmedHeight, 305);
    expect(confirmed.confirmedBlockHash, 'bb' * 32);
    expect(
      IronwoodPendingSendState.fromJson(
        pending.toJson(),
      ).records.single.isConfirmed,
      isTrue,
    );
  });

  test('a reorg of the confirming block returns the send to pending', () async {
    final scan = _scan([_note('a1' * 32, 100000)]);
    final plan = _plan(scan);
    final prepared = _prepared(plan);
    final pending = IronwoodPendingSendState()
      ..addPrepared(
        prepared,
        actualDestinationPool: IronwoodDestinationPool.ironwood,
        createdHeight: 299,
      );
    await broadcastIronwoodSend(
      send: prepared,
      pendingSends: pending,
      chainHeight: 300,
      submit: (_) async => _txid,
    );
    pending.reconcileWithScan(
      scan: ZcashScanResult(
        scannedBlocks: 1,
        discoveredNotes: 0,
        totalValue: 0,
        notes: const [],
        spends: [
          ZcashObservedSpend(
            height: 305,
            tx: reverseTxidByteOrder(_txid),
            pool: 'ironwood',
            nullifier: 'a1' * 32,
            index: 0,
          ),
        ],
      ),
      canonicalBlockHashAt: (_) => 'bb' * 32,
      scannedBlockHashAt: (_) => 'bb' * 32,
    );
    expect(pending.records.single.isConfirmed, isTrue);

    pending.reconcileWithScan(
      scan: ZcashScanResult(
        scannedBlocks: 1,
        discoveredNotes: 0,
        totalValue: 0,
        notes: const [],
        spends: [
          ZcashObservedSpend(
            height: 305,
            tx: reverseTxidByteOrder(_txid),
            pool: 'ironwood',
            nullifier: 'a1' * 32,
            index: 0,
          ),
        ],
      ),
      canonicalBlockHashAt: (height) => height == 305 ? 'cc' * 32 : null,
      scannedBlockHashAt: (height) => height == 305 ? 'bb' * 32 : null,
    );

    final reorged = pending.records.single;
    expect(reorged.isConfirmed, isFalse);
    expect(reorged.broadcastState, IronwoodPendingBroadcastState.acknowledged);
    expect(pending.reservedNullifiersAt(306), {'a1' * 32});
  });
}
