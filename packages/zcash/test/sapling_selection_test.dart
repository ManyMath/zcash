import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

ZcashScannedNote _note({
  required int value,
  required String nullifier,
  bool complete = true,
}) => ZcashScannedNote(
  height: 200,
  tx: 'aa' * 32,
  output: 0,
  value: value,
  pool: 'sapling',
  nullifier: nullifier,
  commitmentPosition: 0,
  isChange: false,
  recipient: complete ? 'zregtestsapling1example' : null,
  rseed: complete ? '11' * 32 : null,
  witness: complete ? '33' * 40 : null,
);

int _stubFee(List<ZcashScannedNote> spends) =>
    5000 * (spends.length < 2 ? 2 : spends.length);

void main() {
  group('SaplingInputSelection', () {
    test('one note covers the payment and leaves change', () {
      final notes = SaplingNoteSet.fromScan(
        notes: [_note(value: 100000, nullifier: 'ab' * 32)],
      );

      final selection = SaplingInputSelection.select(
        notes: notes,
        amountZatoshis: 50000,
        feeForSpends: _stubFee,
      );

      expect(selection.notes, hasLength(1));
      expect(selection.feeZatoshis, 10000);
      expect(selection.inputZatoshis, 100000);
      expect(selection.changeZatoshis, 40000);
      expect(
        selection.inputZatoshis,
        selection.amountZatoshis +
            selection.feeZatoshis +
            selection.changeZatoshis,
        reason: 'the selection must balance or the build cannot',
      );
    });

    test('the fee is re-quoted as notes are added', () {
      final quoted = <int>[];
      final notes = SaplingNoteSet.fromScan(
        notes: [
          _note(value: 30000, nullifier: 'ab' * 32),
          _note(value: 30000, nullifier: 'cd' * 32),
          _note(value: 30000, nullifier: 'ef' * 32),
        ],
      );

      final selection = SaplingInputSelection.select(
        notes: notes,
        amountZatoshis: 60000,
        feeForSpends: (spends) {
          quoted.add(spends.length);
          return _stubFee(spends);
        },
      );

      expect(quoted, [1, 2, 3]);
      expect(selection.notes, hasLength(3));
      expect(selection.feeZatoshis, 15000);
      expect(selection.changeZatoshis, 15000);
    });

    test('notes are taken smallest first', () {
      final notes = SaplingNoteSet.fromScan(
        notes: [
          _note(value: 900000, nullifier: 'ab' * 32),
          _note(value: 100000, nullifier: 'cd' * 32),
        ],
      );

      final selection = SaplingInputSelection.select(
        notes: notes,
        amountZatoshis: 50000,
        feeForSpends: _stubFee,
      );

      expect(selection.notes.single.value, 100000);
    });

    test('a shortfall of spendable notes is not a shortfall of money', () {
      final notes = SaplingNoteSet.fromScan(
        notes: [
          _note(value: 10000, nullifier: 'ab' * 32),
          _note(value: 900000, nullifier: 'cd' * 32, complete: false),
        ],
      );

      expect(
        () => SaplingInputSelection.select(
          notes: notes,
          amountZatoshis: 500000,
          feeForSpends: _stubFee,
        ),
        throwsA(
          isA<SaplingSelectionException>()
              .having(
                (e) => e.refusal,
                'refusal',
                SaplingSelectionRefusal.insufficientSpendableNotes,
              )
              .having((e) => e.message, 'message', contains('Rescan')),
        ),
      );
    });

    test('a genuine shortfall says so', () {
      final notes = SaplingNoteSet.fromScan(
        notes: [_note(value: 10000, nullifier: 'ab' * 32)],
      );

      expect(
        () => SaplingInputSelection.select(
          notes: notes,
          amountZatoshis: 500000,
          feeForSpends: _stubFee,
        ),
        throwsA(
          isA<SaplingSelectionException>().having(
            (e) => e.refusal,
            'refusal',
            SaplingSelectionRefusal.insufficientFunds,
          ),
        ),
      );
    });

    test('an empty wallet refuses without asking for a quote', () {
      var quotes = 0;
      final notes = SaplingNoteSet.fromScan(notes: const []);

      expect(
        () => SaplingInputSelection.select(
          notes: notes,
          amountZatoshis: 50000,
          feeForSpends: (spends) {
            quotes += 1;
            return _stubFee(spends);
          },
        ),
        throwsA(isA<SaplingSelectionException>()),
      );
      expect(
        quotes,
        0,
        reason: 'there is no shape to price when there are no notes',
      );
    });

    test('maxNotes bounds a selection that would not be relayable', () {
      final notes = SaplingNoteSet.fromScan(
        notes: [
          _note(value: 30000, nullifier: 'ab' * 32),
          _note(value: 30000, nullifier: 'cd' * 32),
          _note(value: 30000, nullifier: 'ef' * 32),
        ],
      );

      expect(
        () => SaplingInputSelection.select(
          notes: notes,
          amountZatoshis: 60000,
          feeForSpends: _stubFee,
          maxNotes: 2,
        ),
        throwsA(
          isA<SaplingSelectionException>().having(
            (e) => e.refusal,
            'refusal',
            SaplingSelectionRefusal.tooManyNotes,
          ),
        ),
      );
    });

    test('a non-positive amount is refused', () {
      final notes = SaplingNoteSet.fromScan(
        notes: [_note(value: 100000, nullifier: 'ab' * 32)],
      );

      for (final amount in [0, -1]) {
        expect(
          () => SaplingInputSelection.select(
            notes: notes,
            amountZatoshis: amount,
            feeForSpends: _stubFee,
          ),
          throwsA(
            isA<SaplingSelectionException>().having(
              (e) => e.refusal,
              'refusal',
              SaplingSelectionRefusal.invalidAmount,
            ),
          ),
        );
      }
    });

    test('a negative fee from the quote is refused', () {
      final notes = SaplingNoteSet.fromScan(
        notes: [_note(value: 100000, nullifier: 'ab' * 32)],
      );

      expect(
        () => SaplingInputSelection.select(
          notes: notes,
          amountZatoshis: 50000,
          feeForSpends: (spends) => -1,
        ),
        throwsA(
          isA<SaplingSelectionException>().having(
            (e) => e.refusal,
            'refusal',
            SaplingSelectionRefusal.invalidFee,
          ),
        ),
      );
    });

    test('only Sapling notes are ever selected', () {
      final notes = SaplingNoteSet.fromScan(
        notes: [
          _note(value: 900000, nullifier: 'ab' * 32),
          ZcashScannedNote(
            height: 200,
            tx: 'aa' * 32,
            output: 1,
            value: 100000,
            pool: 'ironwood',
            nullifier: 'cd' * 32,
            commitmentPosition: 1,
            isChange: false,
            recipient: 'uregtest1example',
            rseed: '11' * 32,
            rho: '22' * 32,
            noteVersion: 'v3',
            witness: '33' * 40,
          ),
        ],
      );

      final selection = SaplingInputSelection.select(
        notes: notes,
        amountZatoshis: 50000,
        feeForSpends: _stubFee,
      );

      expect(selection.notes.single.pool, 'sapling');
    });
  });
}
