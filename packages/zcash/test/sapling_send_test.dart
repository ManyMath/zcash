import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

final _anchor = '44' * 32;
final _otherPoolAnchor = '55' * 32;

ZcashScannedNote _note({
  required int value,
  required String nullifier,
  bool complete = true,
  String pool = 'sapling',
}) => ZcashScannedNote(
  height: 200,
  tx: 'aa' * 32,
  output: 0,
  value: value,
  pool: pool,
  nullifier: nullifier,
  commitmentPosition: 0,
  isChange: false,
  recipient: complete ? 'zregtestsapling1example' : null,
  rseed: complete ? '11' * 32 : null,
  witness: complete ? '33' * 40 : null,
);

ZcashScanResult _scan({
  required List<ZcashScannedNote> notes,
  List<ZcashObservedSpend> spends = const [],
  bool withSaplingAnchor = true,
  String? orchardAnchor,
}) => ZcashScanResult(
  scannedBlocks: 1,
  discoveredNotes: notes.length,
  totalValue: notes.fold(0, (sum, note) => sum + note.value),
  notes: notes,
  spends: spends,
  saplingAnchor: withSaplingAnchor ? _anchor : null,
  orchardAnchor: orchardAnchor,
);

int _stubFee(List<ZcashScannedNote> spends) =>
    5000 * (spends.length < 2 ? 2 : spends.length);

SaplingBuildResult _built({
  required int fee,
  required int spent,
  required int delivered,
  int spends = 1,
  String proofValidity = 'real',
}) => SaplingBuildResult(
  network: ZcashAddressNetwork.regtest,
  transactionHex: '00' * 64,
  txid: 'ab' * 32,
  version: 'v6',
  consensusBranchId: 'nu6.3',
  expiryHeight: 240,
  feeZatoshis: fee,
  proofValidity: proofValidity,
  transparentVin: 0,
  transparentVout: 0,
  saplingSpends: spends,
  saplingOutputs: 2,
  totalSpentZatoshis: spent,
  totalOutputZatoshis: delivered,
);

void main() {
  group('SaplingSendPlan', () {
    test('plans a payment out of one scan', () {
      final plan = SaplingSendPlan.fromScan(
        scan: _scan(notes: [_note(value: 100000, nullifier: 'ab' * 32)]),
        recipientAddress: 'zregtestsapling1recipient',
        changeAddress: 'zregtestsapling1mine',
        amountZatoshis: 50000,
        targetHeight: 200,
        feeForSpends: _stubFee,
      );

      expect(plan.notes, hasLength(1));
      expect(plan.feeZatoshis, 10000);
      expect(plan.changeZatoshis, 40000);
      expect(plan.inputZatoshis, 100000);
      expect(
        plan.anchorHex,
        _anchor,
        reason: 'the anchor comes from the same scan the notes did',
      );
      expect(plan.spentNullifiers, {'ab' * 32});
    });

    test('a scan with no Sapling anchor is refused, never substituted', () {
      expect(
        () => SaplingSendPlan.fromScan(
          scan: _scan(
            notes: [_note(value: 100000, nullifier: 'ab' * 32)],
            withSaplingAnchor: false,
            orchardAnchor: _otherPoolAnchor,
          ),
          recipientAddress: 'zregtestsapling1recipient',
          changeAddress: 'zregtestsapling1mine',
          amountZatoshis: 50000,
          targetHeight: 200,
          feeForSpends: _stubFee,
        ),
        throwsA(
          isA<SaplingSendException>().having(
            (e) => e.refusal,
            'refusal',
            SaplingSendRefusal.noSaplingAnchor,
          ),
        ),
      );
    });

    test('change with nowhere to go is refused', () {
      expect(
        () => SaplingSendPlan.fromScan(
          scan: _scan(notes: [_note(value: 100000, nullifier: 'ab' * 32)]),
          recipientAddress: 'zregtestsapling1recipient',
          changeAddress: '',
          amountZatoshis: 50000,
          targetHeight: 200,
          feeForSpends: _stubFee,
        ),
        throwsA(
          isA<SaplingSendException>().having(
            (e) => e.refusal,
            'refusal',
            SaplingSendRefusal.invalidChangeAddress,
          ),
        ),
      );
    });

    test('an empty recipient is refused', () {
      expect(
        () => SaplingSendPlan.fromScan(
          scan: _scan(notes: [_note(value: 100000, nullifier: 'ab' * 32)]),
          recipientAddress: '',
          changeAddress: 'zregtestsapling1mine',
          amountZatoshis: 50000,
          targetHeight: 200,
          feeForSpends: _stubFee,
        ),
        throwsA(
          isA<SaplingSendException>().having(
            (e) => e.refusal,
            'refusal',
            SaplingSendRefusal.invalidRecipient,
          ),
        ),
      );
    });

    test('an in-flight plan keeps its notes off a second payment', () {
      final scan = _scan(
        notes: [
          _note(value: 100000, nullifier: 'ab' * 32),
          _note(value: 900000, nullifier: 'cd' * 32),
        ],
      );
      SaplingSendPlan plan({Iterable<SaplingSendPlan> inFlight = const []}) =>
          SaplingSendPlan.fromScan(
            scan: scan,
            recipientAddress: 'zregtestsapling1recipient',
            changeAddress: 'zregtestsapling1mine',
            amountZatoshis: 50000,
            targetHeight: 200,
            feeForSpends: _stubFee,
            inFlight: inFlight,
          );

      final first = plan();
      final unreserved = plan();
      final reserved = plan(inFlight: [first]);

      expect(
        unreserved.spentNullifiers,
        first.spentNullifiers,
        reason: 'without the reservation the same notes are chosen again',
      );
      expect(
        reserved.spentNullifiers.intersection(first.spentNullifiers),
        isEmpty,
      );
    });

    test('notes in flight are reported apart from insufficient funds', () {
      final scan = _scan(notes: [_note(value: 100000, nullifier: 'ab' * 32)]);
      final first = SaplingSendPlan.fromScan(
        scan: scan,
        recipientAddress: 'zregtestsapling1recipient',
        changeAddress: 'zregtestsapling1mine',
        amountZatoshis: 50000,
        targetHeight: 200,
        feeForSpends: _stubFee,
      );

      expect(
        () => SaplingSendPlan.fromScan(
          scan: scan,
          recipientAddress: 'zregtestsapling1recipient',
          changeAddress: 'zregtestsapling1mine',
          amountZatoshis: 50000,
          targetHeight: 200,
          feeForSpends: _stubFee,
          inFlight: [first],
        ),
        throwsA(
          isA<SaplingSendException>()
              .having(
                (e) => e.refusal,
                'refusal',
                SaplingSendRefusal.notesInFlight,
              )
              .having((e) => e.message, 'message', contains('double spend')),
        ),
      );
    });

    test('a wallet that never had the money says so instead', () {
      final scan = _scan(notes: [_note(value: 100000, nullifier: 'ab' * 32)]);
      final first = SaplingSendPlan.fromScan(
        scan: scan,
        recipientAddress: 'zregtestsapling1recipient',
        changeAddress: 'zregtestsapling1mine',
        amountZatoshis: 50000,
        targetHeight: 200,
        feeForSpends: _stubFee,
      );

      expect(
        () => SaplingSendPlan.fromScan(
          scan: scan,
          recipientAddress: 'zregtestsapling1recipient',
          changeAddress: 'zregtestsapling1mine',
          amountZatoshis: 5000000,
          targetHeight: 200,
          feeForSpends: _stubFee,
          inFlight: [first],
        ),
        throwsA(isA<SaplingSelectionException>()),
      );
    });

    test('only Sapling notes are planned with', () {
      final plan = SaplingSendPlan.fromScan(
        scan: _scan(
          notes: [
            _note(value: 900000, nullifier: 'ab' * 32),
            _note(value: 100000, nullifier: 'cd' * 32, pool: 'ironwood'),
          ],
        ),
        recipientAddress: 'zregtestsapling1recipient',
        changeAddress: 'zregtestsapling1mine',
        amountZatoshis: 50000,
        targetHeight: 200,
        feeForSpends: _stubFee,
      );

      expect(plan.notes.single.pool, 'sapling');
    });
  });

  group('SaplingPreparedSend', () {
    SaplingSendPlan plan() => SaplingSendPlan.fromScan(
      scan: _scan(notes: [_note(value: 100000, nullifier: 'ab' * 32)]),
      recipientAddress: 'zregtestsapling1recipient',
      changeAddress: 'zregtestsapling1mine',
      amountZatoshis: 50000,
      targetHeight: 200,
      feeForSpends: _stubFee,
    );

    test('pairs a plan with the transaction that pays it', () {
      final p = plan();
      final prepared = SaplingPreparedSend(
        plan: p,
        transaction: _built(fee: 10000, spent: 100000, delivered: 90000),
      );

      expect(prepared.txid, 'ab' * 32);
      expect(prepared.expiryHeight, 240);
      expect(prepared.plan.feeZatoshis, 10000);
    });

    test('a fee that is not the quoted fee is fatal', () {
      expect(
        () => SaplingPreparedSend(
          plan: plan(),
          transaction: _built(fee: 15000, spent: 100000, delivered: 90000),
        ),
        throwsA(
          isA<SaplingSendException>().having(
            (e) => e.refusal,
            'refusal',
            SaplingSendRefusal.planBuildMismatch,
          ),
        ),
      );
    });

    test('a different delivered total is fatal', () {
      expect(
        () => SaplingPreparedSend(
          plan: plan(),
          transaction: _built(fee: 10000, spent: 100000, delivered: 80000),
        ),
        throwsA(isA<SaplingSendException>()),
      );
    });

    test('a different spend count is fatal', () {
      expect(
        () => SaplingPreparedSend(
          plan: plan(),
          transaction: _built(
            fee: 10000,
            spent: 100000,
            delivered: 90000,
            spends: 2,
          ),
        ),
        throwsA(isA<SaplingSendException>()),
      );
    });

    test('placeholder proofs are refused', () {
      expect(
        () => SaplingPreparedSend(
          plan: plan(),
          transaction: _built(
            fee: 10000,
            spent: 100000,
            delivered: 90000,
            proofValidity: 'placeholder',
          ),
        ),
        throwsA(
          isA<SaplingSendException>().having(
            (e) => e.message,
            'message',
            contains('never be broadcast'),
          ),
        ),
      );
    });
  });

  group('a memo on a Sapling payment', () {
    test('rides on the plan and encodes as the builder wants it', () {
      final plan = SaplingSendPlan.fromScan(
        scan: _scan(notes: [_note(value: 100000, nullifier: 'ab' * 32)]),
        recipientAddress: 'zregtestsapling1recipient',
        changeAddress: 'zregtestsapling1mine',
        amountZatoshis: 50000,
        targetHeight: 200,
        feeForSpends: _stubFee,
        memo: Uint8List.fromList([0xde, 0xad, 0xbe, 0xef]),
      );

      expect(plan.memoHex, 'deadbeef');
      expect(plan.changeZatoshis, greaterThan(0));
    });

    test('an over-long memo is refused before anything is selected', () {
      expect(
        () => SaplingSendPlan.fromScan(
          scan: _scan(notes: [_note(value: 100000, nullifier: 'ab' * 32)]),
          recipientAddress: 'zregtestsapling1recipient',
          changeAddress: 'zregtestsapling1mine',
          amountZatoshis: 50000,
          targetHeight: 200,
          feeForSpends: (spends) => fail('the memo is refused before pricing'),
          memo: Uint8List(maxMemoLengthBytes + 1),
        ),
        throwsA(
          isA<SaplingSendException>().having(
            (e) => e.refusal,
            'refusal',
            SaplingSendRefusal.invalidMemo,
          ),
        ),
      );
    });

    test('a memo to a transparent recipient is refused', () {
      expect(
        () => SaplingSendPlan.fromScan(
          scan: _scan(notes: [_note(value: 100000, nullifier: 'ab' * 32)]),
          recipientAddress: 'tmExampleTransparentAddress',
          changeAddress: 'zregtestsapling1mine',
          amountZatoshis: 50000,
          targetHeight: 200,
          feeForSpends: _stubFee,
          memo: Uint8List.fromList([1, 2, 3]),
        ),
        throwsA(
          isA<SaplingSendException>().having(
            (e) => e.refusal,
            'refusal',
            SaplingSendRefusal.invalidMemo,
          ),
        ),
      );
    });

    test('a transparent recipient without a memo is still a payment', () {
      final plan = SaplingSendPlan.fromScan(
        scan: _scan(notes: [_note(value: 100000, nullifier: 'ab' * 32)]),
        recipientAddress: 'tmExampleTransparentAddress',
        changeAddress: 'zregtestsapling1mine',
        amountZatoshis: 50000,
        targetHeight: 200,
        feeForSpends: _stubFee,
      );

      expect(plan.amountZatoshis, 50000);
      expect(plan.memoHex, isNull);
    });

    test('the memo does not move the fee the plan was quoted', () {
      for (final memo in [
        null,
        Uint8List.fromList([1, 2, 3]),
      ]) {
        final plan = SaplingSendPlan.fromScan(
          scan: _scan(notes: [_note(value: 100000, nullifier: 'ab' * 32)]),
          recipientAddress: 'zregtestsapling1recipient',
          changeAddress: 'zregtestsapling1mine',
          amountZatoshis: 50000,
          targetHeight: 200,
          feeForSpends: _stubFee,
          memo: memo,
        );
        expect(plan.feeZatoshis, 10000);
        expect(plan.changeZatoshis, 40000);
      }
    });
  });
}
