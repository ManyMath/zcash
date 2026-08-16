import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

const _ironwoodAnchor =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
const _orchardAnchor =
    'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';
const _recipient = 'uregtest1recipient';

ZcashScannedNote _note({
  required int value,
  required String nullifier,
  String pool = 'ironwood',
  bool complete = true,
}) => ZcashScannedNote(
  height: 200,
  tx: 'aa' * 32,
  output: 0,
  value: value,
  pool: pool,
  nullifier: nullifier,
  commitmentPosition: 0,
  isChange: false,
  recipient: complete ? 'uregtest1example' : null,
  rseed: complete ? '11' * 32 : null,
  rho: complete ? '22' * 32 : null,
  noteVersion: complete ? 'v3' : null,
  witness: complete ? '33' * 40 : null,
);

ZcashScanResult _scan({
  required List<ZcashScannedNote> notes,
  List<ZcashObservedSpend> spends = const [],
  String? ironwoodAnchor = _ironwoodAnchor,
  String? orchardAnchor = _orchardAnchor,
}) => ZcashScanResult(
  scannedBlocks: 10,
  discoveredNotes: notes.length,
  totalValue: notes.fold(0, (sum, note) => sum + note.value),
  notes: notes,
  spends: spends,
  orchardAnchor: orchardAnchor,
  ironwoodAnchor: ironwoodAnchor,
);

int _stubFee(List<ZcashScannedNote> spends) =>
    5000 * (spends.length < 2 ? 2 : spends.length);

IronwoodSendPlan _plan({
  required ZcashScanResult scan,
  int amountZatoshis = 50000,
  Iterable<IronwoodSendPlan> inFlight = const [],
  int? maxNotes,
}) => IronwoodSendPlan.fromScan(
  scan: scan,
  recipientAddress: _recipient,
  amountZatoshis: amountZatoshis,
  targetHeight: 300,
  feeForSpends: _stubFee,
  inFlight: inFlight,
  maxNotes: maxNotes,
);

IronwoodBuildResult _built(
  IronwoodSendPlan plan, {
  int? feeZatoshis,
  int? ironwoodOutputZatoshis,
  int? ironwoodChangeZatoshis,
  int? ironwoodInputZatoshis,
  int? ironwoodSpends,
  String? ironwoodAnchor,
}) => IronwoodBuildResult(
  network: ZcashAddressNetwork.regtest,
  transactionHex: 'ff' * 20,
  txid: 'ee' * 32,
  version: 'v6',
  consensusBranchId: 'nu6.3',
  expiryHeight: plan.targetHeight + 40,
  feeZatoshis: feeZatoshis ?? plan.feeZatoshis,
  feeRule: 'zip317',
  proofValidity: 'real',
  ironwoodAnchor: ironwoodAnchor ?? plan.anchorHex,
  ironwoodAnchorSource: 'anchor',
  vin: 0,
  vout: 0,
  ironwoodActions: 2,
  ironwoodSpends: ironwoodSpends ?? plan.notes.length,
  ironwoodChangeOutputs: plan.changeZatoshis > 0 ? 1 : 0,
  totalInputZatoshis: plan.inputZatoshis,
  ironwoodInputZatoshis: ironwoodInputZatoshis ?? plan.inputZatoshis,
  ironwoodChangeZatoshis: ironwoodChangeZatoshis ?? plan.changeZatoshis,
  nonIronwoodOutputZatoshis: 0,
  ironwoodOutputZatoshis: ironwoodOutputZatoshis ?? plan.amountZatoshis,
  rng: 'system',
);

void main() {
  group('IronwoodSendPlan', () {
    test('plans a payment out of the notes a scan discovered', () {
      final plan = _plan(
        scan: _scan(notes: [_note(value: 100000, nullifier: 'ab' * 32)]),
      );

      expect(plan.recipientAddress, _recipient);
      expect(plan.amountZatoshis, 50000);
      expect(plan.notes, hasLength(1));
      expect(plan.feeZatoshis, 10000);
      expect(plan.changeZatoshis, 40000);
      expect(
        plan.inputZatoshis,
        plan.amountZatoshis + plan.feeZatoshis + plan.changeZatoshis,
        reason: 'the four numbers must balance or the build will not',
      );
      expect(plan.spentNullifiers, {'ab' * 32});
    });

    test('anchors the payment to the scan\'s Ironwood tree, not its Orchard '
        'one', () {
      final plan = _plan(
        scan: _scan(notes: [_note(value: 100000, nullifier: 'ab' * 32)]),
      );

      expect(plan.anchorHex, _ironwoodAnchor);
      expect(plan.anchorHex, isNot(_orchardAnchor));
    });

    test('refuses a scan with no Ironwood anchor rather than borrowing the '
        'Orchard one', () {
      final scan = _scan(
        notes: [_note(value: 100000, nullifier: 'ab' * 32)],
        ironwoodAnchor: null,
      );

      expect(
        () => _plan(scan: scan),
        throwsA(
          isA<IronwoodSendException>()
              .having(
                (e) => e.refusal,
                'refusal',
                IronwoodSendRefusal.noIronwoodAnchor,
              )
              .having((e) => e.message, 'message', contains('different tree')),
        ),
      );
    });

    test('refuses an empty recipient', () {
      expect(
        () => IronwoodSendPlan.fromScan(
          scan: _scan(notes: [_note(value: 100000, nullifier: 'ab' * 32)]),
          recipientAddress: '',
          amountZatoshis: 1000,
          targetHeight: 300,
          feeForSpends: _stubFee,
        ),
        throwsA(
          isA<IronwoodSendException>().having(
            (e) => e.refusal,
            'refusal',
            IronwoodSendRefusal.invalidRecipient,
          ),
        ),
      );
    });

    test('never selects a note the scan saw spent', () {
      final scan = _scan(
        notes: [
          _note(value: 900000, nullifier: 'a1' * 32),
          _note(value: 100000, nullifier: 'a2' * 32),
        ],
        spends: [
          ZcashObservedSpend(
            height: 210,
            tx: 'bb' * 32,
            pool: 'ironwood',
            nullifier: 'a1' * 32,
            index: 0,
          ),
        ],
      );

      final plan = _plan(scan: scan);

      expect(plan.spentNullifiers, {'a2' * 32});
    });

    test('does not spend a note a payment already in flight committed', () {
      final scan = _scan(
        notes: [
          _note(value: 100000, nullifier: 'a1' * 32),
          _note(value: 900000, nullifier: 'a2' * 32),
        ],
      );

      final first = _plan(scan: scan);
      expect(first.spentNullifiers, {'a1' * 32});

      final second = _plan(scan: scan, inFlight: [first]);

      expect(second.spentNullifiers, {'a2' * 32});
      expect(
        second.spentNullifiers.intersection(first.spentNullifiers),
        isEmpty,
        reason: 'two unconfirmed payments may not consume one note',
      );
    });

    test('says the money is in flight rather than absent when it is', () {
      final scan = _scan(
        notes: [
          _note(value: 100000, nullifier: 'a1' * 32),
          _note(value: 100000, nullifier: 'a2' * 32),
        ],
      );

      final first = _plan(scan: scan, amountZatoshis: 150000);
      expect(first.notes, hasLength(2));

      expect(
        () => _plan(scan: scan, amountZatoshis: 50000, inFlight: [first]),
        throwsA(
          isA<IronwoodSendException>()
              .having(
                (e) => e.refusal,
                'refusal',
                IronwoodSendRefusal.notesInFlight,
              )
              .having((e) => e.message, 'message', contains('double spend')),
        ),
      );
    });

    test('still reports insufficient funds when the in-flight notes are not '
        'the reason', () {
      final scan = _scan(
        notes: [
          _note(value: 100000, nullifier: 'a1' * 32),
          _note(value: 100000, nullifier: 'a2' * 32),
        ],
      );

      final first = _plan(scan: scan, amountZatoshis: 50000);

      expect(
        () => _plan(scan: scan, amountZatoshis: 5000000, inFlight: [first]),
        throwsA(
          isA<IronwoodSelectionException>().having(
            (e) => e.refusal,
            'refusal',
            IronwoodSelectionRefusal.insufficientFunds,
          ),
        ),
      );
    });

    test('passes selection refusals through unchanged', () {
      final scan = _scan(
        notes: [
          _note(value: 30000, nullifier: 'a1' * 32),
          _note(value: 30000, nullifier: 'a2' * 32),
        ],
      );

      expect(
        () => _plan(scan: scan, amountZatoshis: 40000, maxNotes: 1),
        throwsA(
          isA<IronwoodSelectionException>().having(
            (e) => e.refusal,
            'refusal',
            IronwoodSelectionRefusal.tooManyNotes,
          ),
        ),
      );
    });

    test('ignores the other pools\' notes', () {
      final scan = _scan(
        notes: [
          _note(value: 900000, nullifier: 'a1' * 32, pool: 'orchard'),
          _note(value: 100000, nullifier: 'a2' * 32),
        ],
      );

      final plan = _plan(scan: scan);

      expect(plan.spentNullifiers, {'a2' * 32});
    });
  });

  group('IronwoodPreparedSend', () {
    test('pairs the plan with the transaction that pays it', () {
      final plan = _plan(
        scan: _scan(notes: [_note(value: 100000, nullifier: 'ab' * 32)]),
      );

      final prepared = IronwoodPreparedSend(
        plan: plan,
        transaction: _built(plan),
      );

      expect(prepared.transactionHex, 'ff' * 20);
      expect(prepared.txid, 'ee' * 32);
      expect(prepared.expiryHeight, 340);
      expect(prepared.plan.feeZatoshis, plan.feeZatoshis);
    });

    test('refuses a transaction whose fee is not the fee that was quoted', () {
      final plan = _plan(
        scan: _scan(notes: [_note(value: 100000, nullifier: 'ab' * 32)]),
      );

      expect(
        () => IronwoodPreparedSend(
          plan: plan,
          transaction: _built(plan, feeZatoshis: plan.feeZatoshis + 5000),
        ),
        throwsA(
          isA<IronwoodSendException>()
              .having(
                (e) => e.refusal,
                'refusal',
                IronwoodSendRefusal.planBuildMismatch,
              )
              .having((e) => e.message, 'message', contains('fee')),
        ),
      );
    });

    test('refuses a transaction that pays a different amount', () {
      final plan = _plan(
        scan: _scan(notes: [_note(value: 100000, nullifier: 'ab' * 32)]),
      );

      expect(
        () => IronwoodPreparedSend(
          plan: plan,
          transaction: _built(plan, ironwoodOutputZatoshis: 1),
        ),
        throwsA(
          isA<IronwoodSendException>().having(
            (e) => e.refusal,
            'refusal',
            IronwoodSendRefusal.planBuildMismatch,
          ),
        ),
      );
    });

    test('refuses a transaction that spends other notes or another anchor', () {
      final plan = _plan(
        scan: _scan(notes: [_note(value: 100000, nullifier: 'ab' * 32)]),
      );

      expect(
        () => IronwoodPreparedSend(
          plan: plan,
          transaction: _built(plan, ironwoodSpends: 2),
        ),
        throwsA(
          isA<IronwoodSendException>().having(
            (e) => e.refusal,
            'refusal',
            IronwoodSendRefusal.planBuildMismatch,
          ),
        ),
      );
      expect(
        () => IronwoodPreparedSend(
          plan: plan,
          transaction: _built(plan, ironwoodAnchor: _orchardAnchor),
        ),
        throwsA(
          isA<IronwoodSendException>().having(
            (e) => e.refusal,
            'refusal',
            IronwoodSendRefusal.planBuildMismatch,
          ),
        ),
      );
    });

    test('accepts an anchor that differs only in hex case', () {
      final plan = _plan(
        scan: _scan(notes: [_note(value: 100000, nullifier: 'ab' * 32)]),
      );

      expect(
        IronwoodPreparedSend(
          plan: plan,
          transaction: _built(
            plan,
            ironwoodAnchor: _ironwoodAnchor.toUpperCase(),
          ),
        ).plan.anchorHex,
        _ironwoodAnchor,
      );
    });
  });

  group('a memo on an Ironwood payment', () {
    test('rides on the plan and encodes as the builder wants it', () {
      final plan = IronwoodSendPlan.fromScan(
        scan: _scan(notes: [_note(value: 400000, nullifier: 'ab' * 32)]),
        recipientAddress: _recipient,
        amountZatoshis: 100000,
        targetHeight: 300,
        feeForSpends: (spends) => 15000,
        memo: Uint8List.fromList([0xde, 0xad, 0xbe, 0xef]),
      );

      expect(plan.memo, [0xde, 0xad, 0xbe, 0xef]);
      expect(plan.memoHex, 'deadbeef');
    });

    test('a payment without one carries no memo at all', () {
      final plan = IronwoodSendPlan.fromScan(
        scan: _scan(notes: [_note(value: 400000, nullifier: 'ab' * 32)]),
        recipientAddress: _recipient,
        amountZatoshis: 100000,
        targetHeight: 300,
        feeForSpends: (spends) => 15000,
      );

      expect(plan.memo, isNull);
      expect(plan.memoHex, isNull);
    });

    test('an over-long memo is refused before anything is selected', () {
      expect(
        () => IronwoodSendPlan.fromScan(
          scan: _scan(notes: [_note(value: 400000, nullifier: 'ab' * 32)]),
          recipientAddress: _recipient,
          amountZatoshis: 100000,
          targetHeight: 300,
          feeForSpends: (spends) => fail('the memo is refused before pricing'),
          memo: Uint8List(maxMemoLengthBytes + 1),
        ),
        throwsA(
          isA<IronwoodSendException>().having(
            (e) => e.refusal,
            'refusal',
            IronwoodSendRefusal.invalidMemo,
          ),
        ),
      );
    });

    test('a memo exactly at the bound is accepted', () {
      final plan = IronwoodSendPlan.fromScan(
        scan: _scan(notes: [_note(value: 400000, nullifier: 'ab' * 32)]),
        recipientAddress: _recipient,
        amountZatoshis: 100000,
        targetHeight: 300,
        feeForSpends: (spends) => 15000,
        memo: Uint8List(maxMemoLengthBytes),
      );

      expect(plan.memo, hasLength(maxMemoLengthBytes));
    });

    test('a memo to a transparent recipient is refused', () {
      expect(
        () => IronwoodSendPlan.fromScan(
          scan: _scan(notes: [_note(value: 400000, nullifier: 'ab' * 32)]),
          recipientAddress: 'tmExampleTransparentAddress',
          amountZatoshis: 100000,
          targetHeight: 300,
          feeForSpends: (spends) => 15000,
          memo: Uint8List.fromList([1, 2, 3]),
        ),
        throwsA(
          isA<IronwoodSendException>().having(
            (e) => e.refusal,
            'refusal',
            IronwoodSendRefusal.invalidMemo,
          ),
        ),
      );
    });

    test('the memo does not move the fee the plan was quoted', () {
      final shapes = <int>[];
      for (final memo in [
        null,
        Uint8List.fromList([1, 2, 3]),
      ]) {
        final plan = IronwoodSendPlan.fromScan(
          scan: _scan(notes: [_note(value: 400000, nullifier: 'ab' * 32)]),
          recipientAddress: _recipient,
          amountZatoshis: 100000,
          targetHeight: 300,
          feeForSpends: (spends) {
            shapes.add(spends.length);
            return 15000;
          },
          memo: memo,
        );
        expect(plan.feeZatoshis, 15000);
        expect(plan.changeZatoshis, 400000 - 100000 - 15000);
      }
      expect(shapes.toSet(), hasLength(1));
    });
  });
}
