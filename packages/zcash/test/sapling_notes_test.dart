import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

ZcashScannedNote _saplingNote({
  required int value,
  String? nullifier,
  bool complete = true,
  bool witness = true,
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
  witness: complete && witness ? '33' * 40 : null,
);

ZcashObservedSpend _spend({
  required String nullifier,
  String pool = 'sapling',
}) => ZcashObservedSpend(
  height: 210,
  tx: 'bb' * 32,
  pool: pool,
  nullifier: nullifier,
  index: 0,
);

void main() {
  group('SaplingNoteSet', () {
    test('an unspent, complete note is spendable', () {
      final set = SaplingNoteSet.fromScan(
        notes: [_saplingNote(value: 500000, nullifier: 'ab' * 32)],
      );

      expect(set.spendable, hasLength(1));
      expect(set.spendableZatoshis, 500000);
      expect(set.unspentZatoshis, 500000);
      expect(set.spent, isEmpty);
      expect(set.hasCompleteSpendComponents, isTrue);
    });

    test('a Sapling note needs no rho and no note version', () {
      final note = _saplingNote(value: 500000, nullifier: 'ab' * 32);
      expect(note.rho, isNull);
      expect(note.noteVersion, isNull);

      final set = SaplingNoteSet.fromScan(notes: [note]);
      expect(set.tracked.single.status, SaplingNoteStatus.spendable);
    });

    test('an observed spend removes the note from the spendable set', () {
      final nullifier = 'ab' * 32;
      final set = SaplingNoteSet.fromScan(
        notes: [_saplingNote(value: 500000, nullifier: nullifier)],
        spends: [_spend(nullifier: nullifier)],
      );

      expect(set.spendable, isEmpty);
      expect(set.spendableZatoshis, 0);
      expect(set.unspentZatoshis, 0);
      expect(set.spent, hasLength(1));
      expect(set.spent.single.spend!.height, 210);
      expect(set.tracked.single.status, SaplingNoteStatus.spent);
      expect(set.tracked.single.isUnspent, isFalse);
    });

    test('the same nullifier in another pool does not spend this note', () {
      final nullifier = 'ab' * 32;
      final set = SaplingNoteSet.fromScan(
        notes: [_saplingNote(value: 500000, nullifier: nullifier)],
        spends: [
          _spend(nullifier: nullifier, pool: 'ironwood'),
          _spend(nullifier: nullifier, pool: 'orchard'),
        ],
      );

      expect(set.spent, isEmpty);
      expect(set.spendableZatoshis, 500000);
    });

    test('a note with no nullifier is untrackable, and still money', () {
      final set = SaplingNoteSet.fromScan(
        notes: [_saplingNote(value: 500000, nullifier: null)],
      );

      expect(set.tracked.single.status, SaplingNoteStatus.untrackable);
      expect(set.spendable, isEmpty);
      expect(
        set.unspentZatoshis,
        500000,
        reason: 'nothing observed it spent; the value is still the wallet\'s',
      );
      expect(set.hasCompleteSpendComponents, isFalse);
    });

    test('a note with no witness is incomplete, and still money', () {
      final set = SaplingNoteSet.fromScan(
        notes: [
          _saplingNote(value: 500000, nullifier: 'ab' * 32, witness: false),
        ],
      );

      expect(set.tracked.single.status, SaplingNoteStatus.incomplete);
      expect(set.spendableZatoshis, 0);
      expect(
        set.unspentZatoshis,
        500000,
        reason:
            'a balance of zero here would tell the user their money is gone; '
            'the remedy is a rescan with witness export',
      );
      expect(set.hasCompleteSpendComponents, isFalse);
    });

    test('notes from other pools are not in this set at all', () {
      final set = SaplingNoteSet.fromScan(
        notes: [
          _saplingNote(value: 500000, nullifier: 'ab' * 32),
          _saplingNote(value: 900000, nullifier: 'cd' * 32, pool: 'ironwood'),
          _saplingNote(value: 700000, nullifier: 'ef' * 32, pool: 'orchard'),
        ],
      );

      expect(set.tracked, hasLength(1));
      expect(set.unspentZatoshis, 500000);
      expect(
        set.tracked.every((entry) => entry.note.pool == 'sapling'),
        isTrue,
      );
    });

    test('totals separate what is spendable from what is held', () {
      final set = SaplingNoteSet.fromScan(
        notes: [
          _saplingNote(value: 100000, nullifier: 'ab' * 32),
          _saplingNote(value: 200000, nullifier: 'cd' * 32, witness: false),
          _saplingNote(value: 400000, nullifier: null),
          _saplingNote(value: 800000, nullifier: 'ef' * 32),
        ],
        spends: [_spend(nullifier: 'ef' * 32)],
      );

      expect(set.spendableZatoshis, 100000);
      expect(set.unspentZatoshis, 700000);
      expect(set.spent, hasLength(1));
    });
  });
}
