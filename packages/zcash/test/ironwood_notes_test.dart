import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

ZcashScannedNote _ironwoodNote({
  required int value,
  required String nullifier,
  bool complete = true,
  String noteVersion = 'v3',
  String pool = 'ironwood',
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
  noteVersion: complete ? noteVersion : null,
  witness: complete ? '33' * 40 : null,
);

ZcashObservedSpend _spend({
  required String nullifier,
  String pool = 'ironwood',
}) => ZcashObservedSpend(
  height: 210,
  tx: 'bb' * 32,
  pool: pool,
  nullifier: nullifier,
  index: 0,
);

void main() {
  group('IronwoodNoteSet', () {
    test('an unspent, complete note is spendable', () {
      final set = IronwoodNoteSet.fromScan(
        notes: [_ironwoodNote(value: 500000, nullifier: 'ab' * 32)],
      );

      expect(set.spendable, hasLength(1));
      expect(set.spendableZatoshis, 500000);
      expect(set.unspentZatoshis, 500000);
      expect(set.spent, isEmpty);
      expect(set.hasCompleteSpendComponents, isTrue);
    });

    test('an observed spend removes the note from the spendable set', () {
      final nullifier = 'ab' * 32;
      final set = IronwoodNoteSet.fromScan(
        notes: [_ironwoodNote(value: 500000, nullifier: nullifier)],
        spends: [_spend(nullifier: nullifier)],
      );

      expect(set.spendable, isEmpty);
      expect(set.spendableZatoshis, 0);
      expect(set.unspentZatoshis, 0);
      expect(set.spent, hasLength(1));
      expect(set.spent.single.spend!.height, 210);
      expect(set.tracked.single.status, IronwoodNoteStatus.spent);
    });

    test('the spend join is per pool, not per nullifier', () {
      final nullifier = 'ab' * 32;
      final set = IronwoodNoteSet.fromScan(
        notes: [_ironwoodNote(value: 500000, nullifier: nullifier)],
        spends: [
          _spend(nullifier: nullifier, pool: 'orchard'),
          _spend(nullifier: nullifier, pool: 'sapling'),
        ],
      );

      expect(
        set.spendable,
        hasLength(1),
        reason: 'only an Ironwood spend can consume an Ironwood note',
      );
      expect(set.spent, isEmpty);
    });

    test('notes from other pools are ignored, not rejected', () {
      final set = IronwoodNoteSet.fromScan(
        notes: [
          _ironwoodNote(value: 1, nullifier: 'cd' * 32, pool: 'orchard'),
          _ironwoodNote(value: 2, nullifier: 'ef' * 32, pool: 'sapling'),
          _ironwoodNote(value: 500000, nullifier: 'ab' * 32),
        ],
      );

      expect(set.tracked, hasLength(1));
      expect(set.spendableZatoshis, 500000);
    });

    test('a note with no nullifier is untrackable, never spendable', () {
      final set = IronwoodNoteSet.fromScan(
        notes: [
          ZcashScannedNote(
            height: 200,
            tx: 'aa' * 32,
            output: 0,
            value: 700000,
            pool: 'ironwood',
            recipient: 'uregtest1example',
            rseed: '11' * 32,
            rho: '22' * 32,
            noteVersion: 'v3',
            witness: '33' * 40,
          ),
        ],
      );

      expect(set.tracked.single.status, IronwoodNoteStatus.untrackable);
      expect(set.spendable, isEmpty);
      expect(
        set.unspentZatoshis,
        700000,
        reason: 'the value is still the wallet\'s; only its status is unknown',
      );
    });

    test('a note missing spend components is unspent but not spendable', () {
      final set = IronwoodNoteSet.fromScan(
        notes: [
          _ironwoodNote(value: 900000, nullifier: 'ab' * 32, complete: false),
        ],
      );

      expect(set.tracked.single.status, IronwoodNoteStatus.incomplete);
      expect(set.spendable, isEmpty);
      expect(set.spendableZatoshis, 0);
      expect(set.unspentZatoshis, 900000);
      expect(set.hasCompleteSpendComponents, isFalse);
    });

    test('a v2 note in the Ironwood pool is not spendable', () {
      final set = IronwoodNoteSet.fromScan(
        notes: [
          _ironwoodNote(value: 900000, nullifier: 'ab' * 32, noteVersion: 'v2'),
        ],
      );

      expect(set.tracked.single.status, IronwoodNoteStatus.incomplete);
      expect(set.spendable, isEmpty);
    });

    test('a mixed wallet totals each question separately', () {
      final spentNullifier = 'ab' * 32;
      final set = IronwoodNoteSet.fromScan(
        notes: [
          _ironwoodNote(value: 100, nullifier: spentNullifier),
          _ironwoodNote(value: 200, nullifier: 'cd' * 32),
          _ironwoodNote(value: 400, nullifier: 'ef' * 32, complete: false),
        ],
        spends: [_spend(nullifier: spentNullifier)],
      );

      expect(set.spendableZatoshis, 200);
      expect(set.unspentZatoshis, 600);
      expect(set.spent, hasLength(1));
      expect(set.tracked, hasLength(3));
    });
  });
}
