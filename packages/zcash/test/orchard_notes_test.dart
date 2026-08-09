import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

ZcashScannedNote _orchardNote({
  required int value,
  String? nullifier,
  bool complete = true,
  bool witness = true,
  String noteVersion = 'v2',
  String pool = 'orchard',
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
  witness: complete && witness ? '33' * 40 : null,
);

ZcashObservedSpend _spend({
  required String nullifier,
  String pool = 'orchard',
}) => ZcashObservedSpend(
  height: 210,
  tx: 'bb' * 32,
  pool: pool,
  nullifier: nullifier,
  index: 0,
);

void main() {
  group('OrchardNoteSet', () {
    test('a complete unspent note is migratable, not spendable', () {
      final set = OrchardNoteSet.fromScan(
        notes: [_orchardNote(value: 500000, nullifier: 'ab' * 32)],
      );

      expect(set.migratable, hasLength(1));
      expect(set.migratableZatoshis, 500000);
      expect(set.unspentZatoshis, 500000);
      expect(set.tracked.single.status, OrchardNoteStatus.migratable);
      expect(set.hasCompleteSpendComponents, isTrue);
    });

    test('an observed spend removes the note', () {
      final nullifier = 'ab' * 32;
      final set = OrchardNoteSet.fromScan(
        notes: [_orchardNote(value: 500000, nullifier: nullifier)],
        spends: [_spend(nullifier: nullifier)],
      );

      expect(set.migratableZatoshis, 0);
      expect(set.unspentZatoshis, 0);
      expect(set.spent, hasLength(1));
      expect(set.spent.single.spend!.height, 210);
    });

    test('the same nullifier in another pool does not spend this note', () {
      final nullifier = 'ab' * 32;
      final set = OrchardNoteSet.fromScan(
        notes: [_orchardNote(value: 500000, nullifier: nullifier)],
        spends: [
          _spend(nullifier: nullifier, pool: 'ironwood'),
          _spend(nullifier: nullifier, pool: 'sapling'),
        ],
      );

      expect(set.spent, isEmpty);
      expect(set.migratableZatoshis, 500000);
    });

    test('a note with no rho cannot be rebuilt, and is still money', () {
      final note = ZcashScannedNote(
        height: 200,
        tx: 'aa' * 32,
        output: 0,
        value: 500000,
        pool: 'orchard',
        nullifier: 'ab' * 32,
        commitmentPosition: 0,
        isChange: false,
        recipient: 'uregtest1example',
        rseed: '11' * 32,
        noteVersion: 'v2',
        witness: '33' * 40,
      );
      final set = OrchardNoteSet.fromScan(notes: [note]);

      expect(set.tracked.single.status, OrchardNoteStatus.incomplete);
      expect(set.migratableZatoshis, 0);
      expect(
        set.unspentZatoshis,
        500000,
        reason: 'the value is the wallet\'s; a rescan is what recovers it',
      );
    });

    test('a v3 note is not an Orchard note however it is labelled', () {
      final set = OrchardNoteSet.fromScan(
        notes: [
          _orchardNote(value: 500000, nullifier: 'ab' * 32, noteVersion: 'v3'),
        ],
      );

      expect(set.tracked.single.status, OrchardNoteStatus.incomplete);
      expect(set.migratableZatoshis, 0);
    });

    test('a note with no witness is incomplete, and still money', () {
      final set = OrchardNoteSet.fromScan(
        notes: [
          _orchardNote(value: 500000, nullifier: 'ab' * 32, witness: false),
        ],
      );

      expect(set.tracked.single.status, OrchardNoteStatus.incomplete);
      expect(set.migratableZatoshis, 0);
      expect(set.unspentZatoshis, 500000);
      expect(set.hasCompleteSpendComponents, isFalse);
    });

    test('a note with no nullifier is untrackable, and still money', () {
      final set = OrchardNoteSet.fromScan(
        notes: [_orchardNote(value: 500000, nullifier: null)],
      );

      expect(set.tracked.single.status, OrchardNoteStatus.untrackable);
      expect(set.migratableZatoshis, 0);
      expect(set.unspentZatoshis, 500000);
    });

    test('Ironwood notes are not in this set at all', () {
      final set = OrchardNoteSet.fromScan(
        notes: [
          _orchardNote(value: 500000, nullifier: 'ab' * 32),
          _orchardNote(
            value: 900000,
            nullifier: 'cd' * 32,
            noteVersion: 'v3',
            pool: 'ironwood',
          ),
        ],
      );

      expect(set.tracked, hasLength(1));
      expect(set.unspentZatoshis, 500000);
    });
  });
}
