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
  pool: 'ironwood',
  nullifier: nullifier,
  commitmentPosition: 0,
  isChange: false,
  recipient: complete ? 'uregtest1example' : null,
  rseed: complete ? '11' * 32 : null,
  rho: complete ? '22' * 32 : null,
  noteVersion: complete ? 'v3' : null,
  witness: complete ? '33' * 40 : null,
);

int _stubFee(List<ZcashScannedNote> spends) =>
    5000 * (spends.length < 2 ? 2 : spends.length);

void main() {
  group('IronwoodInputSelection', () {
    test('one note covers the payment and leaves change', () {
      final notes = IronwoodNoteSet.fromScan(
        notes: [_note(value: 100000, nullifier: 'ab' * 32)],
      );

      final selection = IronwoodInputSelection.select(
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
        reason: 'the four numbers must balance or the build will not',
      );
    });

    test('adds notes until they cover the payment plus its own fee', () {
      final notes = IronwoodNoteSet.fromScan(
        notes: [
          _note(value: 20000, nullifier: 'a1' * 32),
          _note(value: 20000, nullifier: 'a2' * 32),
          _note(value: 20000, nullifier: 'a3' * 32),
        ],
      );

      final selection = IronwoodInputSelection.select(
        notes: notes,
        amountZatoshis: 40000,
        feeForSpends: _stubFee,
      );

      expect(selection.notes, hasLength(3));
      expect(selection.feeZatoshis, 15000);
      expect(selection.inputZatoshis, 60000);
      expect(selection.changeZatoshis, 5000);
    });

    test('takes the smallest notes first', () {
      final notes = IronwoodNoteSet.fromScan(
        notes: [
          _note(value: 900000, nullifier: 'a1' * 32),
          _note(value: 30000, nullifier: 'a2' * 32),
          _note(value: 500000, nullifier: 'a3' * 32),
        ],
      );

      final selection = IronwoodInputSelection.select(
        notes: notes,
        amountZatoshis: 15000,
        feeForSpends: _stubFee,
      );

      expect(selection.notes.single.value, 30000);
    });

    test('a spent note is never selected', () {
      final spent = 'a1' * 32;
      final notes = IronwoodNoteSet.fromScan(
        notes: [
          _note(value: 900000, nullifier: spent),
          _note(value: 80000, nullifier: 'a2' * 32),
        ],
        spends: [
          ZcashObservedSpend(
            height: 210,
            tx: 'bb' * 32,
            pool: 'ironwood',
            nullifier: spent,
            index: 0,
          ),
        ],
      );

      final selection = IronwoodInputSelection.select(
        notes: notes,
        amountZatoshis: 50000,
        feeForSpends: _stubFee,
      );

      expect(selection.notes.single.value, 80000);
      for (final note in selection.notes) {
        expect(note.nullifier, isNot(spent));
      }
    });

    test('distinguishes "not enough money" from "not enough usable notes"', () {
      final incomplete = IronwoodNoteSet.fromScan(
        notes: [
          _note(value: 900000, nullifier: 'a1' * 32, complete: false),
          _note(value: 10000, nullifier: 'a2' * 32),
        ],
      );
      expect(
        () => IronwoodInputSelection.select(
          notes: incomplete,
          amountZatoshis: 500000,
          feeForSpends: _stubFee,
        ),
        throwsA(
          isA<IronwoodSelectionException>()
              .having(
                (e) => e.refusal,
                'refusal',
                IronwoodSelectionRefusal.insufficientSpendableNotes,
              )
              .having((e) => e.message, 'message', contains('Rescan')),
        ),
      );

      final poor = IronwoodNoteSet.fromScan(
        notes: [_note(value: 10000, nullifier: 'a2' * 32)],
      );
      expect(
        () => IronwoodInputSelection.select(
          notes: poor,
          amountZatoshis: 500000,
          feeForSpends: _stubFee,
        ),
        throwsA(
          isA<IronwoodSelectionException>().having(
            (e) => e.refusal,
            'refusal',
            IronwoodSelectionRefusal.insufficientFunds,
          ),
        ),
      );
    });

    test('an empty wallet refuses without asking for a fee quote', () {
      final notes = IronwoodNoteSet.fromScan(notes: const []);
      expect(
        () => IronwoodInputSelection.select(
          notes: notes,
          amountZatoshis: 1000,
          feeForSpends: (_) => fail('no shape exists to be priced'),
        ),
        throwsA(
          isA<IronwoodSelectionException>().having(
            (e) => e.refusal,
            'refusal',
            IronwoodSelectionRefusal.insufficientFunds,
          ),
        ),
      );
    });

    test('respects a note-count bound', () {
      final notes = IronwoodNoteSet.fromScan(
        notes: [
          for (var i = 0; i < 6; i++)
            _note(value: 20000, nullifier: '${i}0' * 32),
        ],
      );

      expect(
        () => IronwoodInputSelection.select(
          notes: notes,
          amountZatoshis: 80000,
          feeForSpends: _stubFee,
          maxNotes: 2,
        ),
        throwsA(
          isA<IronwoodSelectionException>().having(
            (e) => e.refusal,
            'refusal',
            IronwoodSelectionRefusal.tooManyNotes,
          ),
        ),
      );

      final unbounded = IronwoodInputSelection.select(
        notes: notes,
        amountZatoshis: 80000,
        feeForSpends: _stubFee,
      );
      expect(unbounded.notes, hasLength(6));
      expect(unbounded.feeZatoshis, 30000);
      expect(unbounded.changeZatoshis, 10000);
    });

    test('refuses a non-positive amount and a negative fee', () {
      final notes = IronwoodNoteSet.fromScan(
        notes: [_note(value: 100000, nullifier: 'ab' * 32)],
      );
      expect(
        () => IronwoodInputSelection.select(
          notes: notes,
          amountZatoshis: 0,
          feeForSpends: _stubFee,
        ),
        throwsA(
          isA<IronwoodSelectionException>().having(
            (e) => e.refusal,
            'refusal',
            IronwoodSelectionRefusal.invalidAmount,
          ),
        ),
      );
      expect(
        () => IronwoodInputSelection.select(
          notes: notes,
          amountZatoshis: 1000,
          feeForSpends: (_) => -1,
        ),
        throwsA(
          isA<IronwoodSelectionException>().having(
            (e) => e.refusal,
            'refusal',
            IronwoodSelectionRefusal.invalidFee,
          ),
        ),
      );
    });
  });
}
