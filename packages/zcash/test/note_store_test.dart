import 'dart:convert';

import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

const _account = 'account-fingerprint-a';
const _otherAccount = 'account-fingerprint-b';

ZcashScannedNote _note({
  required int value,
  required String nullifier,
  String pool = 'ironwood',
  String tx = 'aa',
  int output = 0,
  int height = 200,
}) => ZcashScannedNote(
  height: height,
  tx: tx * 32,
  output: output,
  value: value,
  pool: pool,
  nullifier: nullifier,
  commitmentPosition: 0,
  isChange: false,
  recipient: 'uregtest1example',
  rseed: '11' * 32,
  rho: pool == 'sapling' ? null : '22' * 32,
  noteVersion: pool == 'sapling' ? null : (pool == 'ironwood' ? 'v3' : 'v2'),
  witness: '33' * 40,
);

ZcashObservedSpend _spend({
  required String nullifier,
  String pool = 'ironwood',
  int height = 900,
}) => ZcashObservedSpend(
  height: height,
  tx: 'bb' * 32,
  pool: pool,
  nullifier: nullifier,
  index: 0,
);

ZcashScanResult _scan({
  List<ZcashScannedNote> notes = const [],
  List<ZcashObservedSpend> spends = const [],
  int? from,
  int? to,
}) => ZcashScanResult(
  scannedBlocks: from != null && to != null ? to - from + 1 : 0,
  discoveredNotes: notes.length,
  totalValue: notes.fold(0, (sum, note) => sum + note.value),
  notes: notes,
  spends: spends,
  scannedHeightRange: from != null && to != null
      ? CompactBlockScanRange(start: from, end: to)
      : null,
);

void main() {
  group('IronwoodNoteStore', () {
    test(
      'a spend seen by a later scan resolves a note seen by an earlier one',
      () {
        final store = IronwoodNoteStore();
        final note = _note(value: 500000, nullifier: 'ab' * 32, height: 100);

        store.apply(
          _scan(notes: [note], from: 1, to: 500),
          accountFingerprint: _account,
        );
        expect(store.noteSet.unspentZatoshis, 500000);

        final later = _scan(
          spends: [_spend(nullifier: 'ab' * 32, height: 900)],
          from: 501,
          to: 1000,
        );

        expect(
          IronwoodNoteSet.fromScan(
            notes: later.notes,
            spends: later.spends,
          ).tracked,
          isEmpty,
        );

        store.apply(later, accountFingerprint: _account);

        expect(store.noteSet.unspentZatoshis, 0);
        expect(store.noteSet.spent, hasLength(1));
        expect(store.noteSet.spent.single.spend?.height, 900);
        expect(store.coveredFrom, 1);
        expect(store.coveredThrough, 1000);
      },
    );

    test('applying the same scan twice changes nothing', () {
      final store = IronwoodNoteStore();
      final scan = _scan(
        notes: [
          _note(value: 100000, nullifier: 'ab' * 32, tx: 'aa'),
          _note(value: 200000, nullifier: 'cd' * 32, tx: 'aa', output: 1),
        ],
        spends: [_spend(nullifier: 'cd' * 32)],
        from: 1,
        to: 1000,
      );

      store.apply(scan, accountFingerprint: _account);
      store.apply(scan, accountFingerprint: _account);

      expect(store.notes, hasLength(2));
      expect(store.spends, hasLength(1));
      expect(store.noteSet.unspentZatoshis, 100000);
      expect(store.coveredFrom, 1);
      expect(store.coveredThrough, 1000);
    });

    test('a note out of a store carries no witness and is never spendable', () {
      final store = IronwoodNoteStore();
      final scanned = _note(value: 500000, nullifier: 'ab' * 32, height: 100);
      expect(scanned.witness, isNotNull);

      store.apply(
        _scan(notes: [scanned], from: 1, to: 500),
        accountFingerprint: _account,
      );

      expect(store.notes.single.witness, isNull);
      expect(store.noteSet.spendableZatoshis, 0);
      expect(store.noteSet.spendable, isEmpty);
      expect(store.noteSet.unspentZatoshis, 500000);
      expect(
        store.noteSet.tracked.single.status,
        IronwoodNoteStatus.incomplete,
      );
      expect(
        IronwoodNoteSet.fromScan(notes: [scanned]).spendableZatoshis,
        500000,
      );
    });

    test(
      'a re-report that lost its nullifier does not revive a spent note',
      () {
        final store = IronwoodNoteStore();
        store.apply(
          _scan(
            notes: [_note(value: 500000, nullifier: 'ab' * 32, height: 100)],
            from: 1,
            to: 500,
          ),
          accountFingerprint: _account,
        );
        store.apply(
          _scan(
            spends: [_spend(nullifier: 'ab' * 32, height: 900)],
            from: 501,
            to: 1000,
          ),
          accountFingerprint: _account,
        );
        expect(store.noteSet.unspentZatoshis, 0);

        store.apply(
          _scan(
            notes: [
              ZcashScannedNote(
                height: 100,
                tx: 'aa' * 32,
                output: 0,
                value: 500000,
                pool: 'ironwood',
              ),
            ],
            from: 90,
            to: 1000,
          ),
          accountFingerprint: _account,
        );

        expect(store.notes.single.nullifier, 'ab' * 32);
        expect(store.noteSet.unspentZatoshis, 0);
        expect(store.noteSet.spent, hasLength(1));
      },
    );

    test('a scan that found something but names no range is refused', () {
      final store = IronwoodNoteStore();
      store.apply(_scan(from: 100, to: 200), accountFingerprint: _account);

      final unplaceable = ZcashScanResult(
        scannedBlocks: 350,
        discoveredNotes: 1,
        totalValue: 500000,
        notes: [_note(value: 500000, nullifier: 'ab' * 32, height: 550)],
      );

      try {
        store.apply(unplaceable, accountFingerprint: _account);
        fail('expected the unplaceable scan to be refused');
      } on NoteStoreException catch (e) {
        expect(e.refusal, NoteStoreRefusal.unknownRange);
        expect(e.missingRange, isNull);
      }

      expect(store.notes, isEmpty);
      expect(store.coveredThrough, 200);
    });

    test('a note with no nullifier is kept, and stays untrackable', () {
      final store = IronwoodNoteStore();
      store.apply(
        _scan(
          notes: [_note(value: 700, nullifier: 'ef' * 32, height: 5)],
          from: 1,
          to: 10,
        ),
        accountFingerprint: _account,
      );
      final untrackable = ZcashScannedNote(
        height: 15,
        tx: 'cc' * 32,
        output: 0,
        value: 300,
        pool: 'ironwood',
      );
      store.apply(
        _scan(notes: [untrackable], from: 11, to: 20),
        accountFingerprint: _account,
      );

      expect(store.notes, hasLength(2));
      expect(store.noteSet.unspentZatoshis, 1000);
      expect(
        store.noteSet.tracked.where(
          (e) => e.status == IronwoodNoteStatus.untrackable,
        ),
        hasLength(1),
      );
    });

    test('a scan starting above the covered range is refused', () {
      final store = IronwoodNoteStore();
      store.apply(_scan(from: 1, to: 500), accountFingerprint: _account);

      try {
        store.apply(_scan(from: 601, to: 700), accountFingerprint: _account);
        fail('expected the gap to be refused');
      } on NoteStoreException catch (e) {
        expect(e.refusal, NoteStoreRefusal.coverageGap);
        expect(e.missingRange?.start, 501);
        expect(e.missingRange?.end, 600);
      }

      expect(store.coveredThrough, 500);
    });

    test('a scan ending below the covered range is refused too', () {
      final store = IronwoodNoteStore();
      store.apply(_scan(from: 500, to: 600), accountFingerprint: _account);

      try {
        store.apply(_scan(from: 100, to: 200), accountFingerprint: _account);
        fail('expected the gap to be refused');
      } on NoteStoreException catch (e) {
        expect(e.refusal, NoteStoreRefusal.coverageGap);
        expect(e.missingRange?.start, 201);
        expect(e.missingRange?.end, 499);
      }
    });

    test('a contiguous scan is accepted and extends coverage', () {
      final store = IronwoodNoteStore();
      store.apply(_scan(from: 1, to: 500), accountFingerprint: _account);
      store.apply(_scan(from: 501, to: 700), accountFingerprint: _account);
      store.apply(_scan(from: 400, to: 900), accountFingerprint: _account);

      expect(store.coveredFrom, 1);
      expect(store.coveredThrough, 900);
    });

    test('an empty scan advances nothing and is not an error', () {
      final store = IronwoodNoteStore();
      store.apply(_scan(from: 1, to: 500), accountFingerprint: _account);
      store.apply(_scan(), accountFingerprint: _account);

      expect(store.coveredFrom, 1);
      expect(store.coveredThrough, 500);
    });

    test('rollback restores the earlier view', () {
      final store = IronwoodNoteStore();
      store.apply(
        _scan(
          notes: [_note(value: 100000, nullifier: 'ab' * 32, height: 100)],
          from: 1,
          to: 500,
        ),
        accountFingerprint: _account,
      );
      store.apply(
        _scan(
          notes: [
            _note(value: 200000, nullifier: 'cd' * 32, tx: 'dd', height: 800),
          ],
          spends: [_spend(nullifier: 'ab' * 32, height: 900)],
          from: 501,
          to: 1000,
        ),
        accountFingerprint: _account,
      );
      expect(store.noteSet.unspentZatoshis, 200000);

      store.rollbackTo(700);

      expect(store.notes, hasLength(1));
      expect(store.spends, isEmpty);
      expect(store.noteSet.unspentZatoshis, 100000);
      expect(store.coveredFrom, 1);
      expect(store.coveredThrough, 700);
    });

    test('rolling back below everything covered leaves no coverage', () {
      final store = IronwoodNoteStore();
      store.apply(_scan(from: 500, to: 900), accountFingerprint: _account);

      store.rollbackTo(100);

      expect(store.coveredFrom, isNull);
      expect(store.coveredThrough, isNull);
      store.apply(_scan(from: 9000, to: 9100), accountFingerprint: _account);
      expect(store.coveredFrom, 9000);
    });

    test('a scan tagged with another account is refused', () {
      final store = IronwoodNoteStore();
      store.apply(
        _scan(
          notes: [_note(value: 100000, nullifier: 'ab' * 32)],
          from: 1,
          to: 500,
        ),
        accountFingerprint: _account,
      );

      try {
        store.apply(
          _scan(
            notes: [_note(value: 999, nullifier: 'cd' * 32, tx: 'dd')],
            from: 501,
            to: 600,
          ),
          accountFingerprint: _otherAccount,
        );
        fail('expected the foreign account to be refused');
      } on NoteStoreException catch (e) {
        expect(e.refusal, NoteStoreRefusal.foreignAccount);
        expect(e.message, isNot(contains(_otherAccount)));
        expect(e.message, isNot(contains(_account)));
      }

      expect(store.notes, hasLength(1));
      expect(store.accountFingerprint, _account);
    });

    test('the fingerprint is recorded on first use', () {
      final store = IronwoodNoteStore();
      expect(store.accountFingerprint, isNull);
      store.apply(_scan(from: 1, to: 10), accountFingerprint: _account);
      expect(store.accountFingerprint, _account);
    });
  });

  group('SaplingNoteStore', () {
    test('keeps only Sapling notes and resolves them across scans', () {
      final store = SaplingNoteStore();
      store.apply(
        _scan(
          notes: [
            _note(value: 400000, nullifier: 'ab' * 32, pool: 'sapling'),
            _note(value: 900000, nullifier: 'cd' * 32, tx: 'dd'),
          ],
          from: 1,
          to: 500,
        ),
        accountFingerprint: _account,
      );

      expect(store.notes, hasLength(1));
      expect(store.noteSet.unspentZatoshis, 400000);
      expect(store.noteSet.spendableZatoshis, 0);

      store.apply(
        _scan(
          spends: [_spend(nullifier: 'ab' * 32, pool: 'sapling')],
          from: 501,
          to: 1000,
        ),
        accountFingerprint: _account,
      );

      expect(store.noteSet.unspentZatoshis, 0);
    });
  });

  group('OrchardNoteStore', () {
    test(
      'what it holds is Orchard value a fresh witness would make movable',
      () {
        final store = OrchardNoteStore();
        store.apply(
          _scan(
            notes: [
              _note(value: 300000, nullifier: 'ab' * 32, pool: 'orchard'),
            ],
            from: 1,
            to: 500,
          ),
          accountFingerprint: _account,
        );

        expect(store.noteSet.unspentZatoshis, 300000);
        expect(store.noteSet.migratableZatoshis, 0);
        expect(
          store.noteSet.tracked.single.status,
          OrchardNoteStatus.incomplete,
        );
      },
    );
  });

  group('the three stores side by side', () {
    test('one spend of shared nullifier bytes takes one pool\'s note', () {
      final shared = 'ab' * 32;
      final scan = _scan(
        notes: [
          _note(value: 100, nullifier: shared, pool: 'sapling', tx: 'a1'),
          _note(value: 200, nullifier: shared, pool: 'orchard', tx: 'a2'),
          _note(value: 300, nullifier: shared, pool: 'ironwood', tx: 'a3'),
        ],
        from: 1,
        to: 500,
      );
      final sapling = SaplingNoteStore();
      final orchard = OrchardNoteStore();
      final ironwood = IronwoodNoteStore();
      sapling.apply(scan, accountFingerprint: _account);
      orchard.apply(scan, accountFingerprint: _account);
      ironwood.apply(scan, accountFingerprint: _account);

      final spend = _scan(
        spends: [_spend(nullifier: shared, pool: 'ironwood')],
        from: 501,
        to: 1000,
      );
      sapling.apply(spend, accountFingerprint: _account);
      orchard.apply(spend, accountFingerprint: _account);
      ironwood.apply(spend, accountFingerprint: _account);

      expect(ironwood.noteSet.unspentZatoshis, 0);
      expect(sapling.noteSet.unspentZatoshis, 100);
      expect(orchard.noteSet.unspentZatoshis, 200);
      expect(sapling.spends, isEmpty);
      expect(orchard.spends, isEmpty);
      expect(ironwood.spends, hasLength(1));
    });

    test('each store watches only its own pool\'s bytes', () {
      final shared = 'ab' * 32;
      final scan = _scan(
        notes: [
          _note(value: 100, nullifier: shared, pool: 'sapling', tx: 'a1'),
          _note(value: 300, nullifier: shared, pool: 'ironwood', tx: 'a3'),
        ],
        from: 1,
        to: 500,
      );
      final sapling = SaplingNoteStore()
        ..apply(scan, accountFingerprint: _account);
      final ironwood = IronwoodNoteStore()
        ..apply(scan, accountFingerprint: _account);

      expect(sapling.watchSet.sapling, [shared]);
      expect(sapling.watchSet.orchard, isEmpty);
      expect(sapling.watchSet.ironwood, isEmpty);
      expect(ironwood.watchSet.ironwood, [shared]);
      expect(ironwood.watchSet.sapling, isEmpty);

      final composed = ZcashWatchedNullifiers(
        sapling: sapling.nullifiersToWatch,
        ironwood: ironwood.nullifiersToWatch,
      );
      expect(composed.sapling, [shared]);
      expect(composed.ironwood, [shared]);
      expect(composed.orchard, isEmpty);
    });
  });

  group('the watch set a store yields', () {
    test('a note already seen spent is not watched again', () {
      final store = IronwoodNoteStore();
      store.apply(
        _scan(
          notes: [
            _note(value: 100000, nullifier: 'ab' * 32, tx: 'a1'),
            _note(value: 200000, nullifier: 'cd' * 32, tx: 'a2'),
          ],
          from: 1,
          to: 500,
        ),
        accountFingerprint: _account,
      );
      expect(store.nullifiersToWatch, ['ab' * 32, 'cd' * 32]);

      store.apply(
        _scan(spends: [_spend(nullifier: 'ab' * 32)], from: 501, to: 1000),
        accountFingerprint: _account,
      );

      expect(store.nullifiersToWatch, ['cd' * 32]);
    });

    test('an untrackable note is money, and is watched by nothing', () {
      final store = IronwoodNoteStore();
      store.apply(
        _scan(
          notes: [
            ZcashScannedNote(
              height: 100,
              tx: 'cc' * 32,
              output: 0,
              value: 250000,
              pool: 'ironwood',
            ),
          ],
          from: 1,
          to: 500,
        ),
        accountFingerprint: _account,
      );

      expect(store.nullifiersToWatch, isEmpty);
      expect(store.watchSet.isEmpty, isTrue);
      expect(store.noteSet.unspentZatoshis, 250000);
      expect(store.noteSet.spendableZatoshis, 0);
      expect(store.noteSet.untrackableZatoshis, 250000);
    });
  });

  group('surviving a restart', () {
    IronwoodNoteStore populated() {
      final store = IronwoodNoteStore();
      store.apply(
        _scan(
          notes: [
            _note(value: 100000, nullifier: 'ab' * 32, tx: 'a1', height: 100),
            _note(value: 200000, nullifier: 'cd' * 32, tx: 'a2', height: 150),
          ],
          from: 1,
          to: 500,
        ),
        accountFingerprint: _account,
      );
      store.apply(
        _scan(
          spends: [_spend(nullifier: 'ab' * 32, height: 900)],
          from: 501,
          to: 1000,
        ),
        accountFingerprint: _account,
      );
      return store;
    }

    test('a store round-trips through real JSON', () {
      final store = populated();

      final restored = IronwoodNoteStore.fromJson(
        jsonDecode(jsonEncode(store.toJson())) as Map<String, Object?>,
      );

      expect(restored.accountFingerprint, _account);
      expect(restored.coveredFrom, 1);
      expect(restored.coveredThrough, 1000);
      expect(restored.notes.map((n) => n.tx), store.notes.map((n) => n.tx));
      expect(restored.notes.map((n) => n.nullifier), ['ab' * 32, 'cd' * 32]);
      expect(restored.spends.single.nullifier, 'ab' * 32);
      expect(restored.nullifiersToWatch, ['cd' * 32]);

      expect(restored.noteSet.unspentZatoshis, store.noteSet.unspentZatoshis);
      expect(restored.noteSet.unspentZatoshis, 200000);
      expect(restored.noteSet.spendableZatoshis, 0);
      expect(restored.notes.every((note) => note.witness == null), isTrue);
    });

    test('a restored store keeps its coverage, and its refusals', () {
      final restored = IronwoodNoteStore.fromJson(populated().toJson());

      try {
        restored.apply(
          _scan(from: 1100, to: 1200),
          accountFingerprint: _account,
        );
        fail('expected the gap to be refused');
      } on NoteStoreException catch (e) {
        expect(e.refusal, NoteStoreRefusal.coverageGap);
        expect(e.missingRange?.start, 1001);
        expect(e.missingRange?.end, 1099);
      }

      restored.apply(
        _scan(
          notes: [_note(value: 50000, nullifier: 'ef' * 32, tx: 'a3')],
          from: 1001,
          to: 1100,
        ),
        accountFingerprint: _account,
      );
      expect(restored.coveredThrough, 1100);
      expect(restored.noteSet.unspentZatoshis, 250000);
    });

    test('an unknown note_store_version is refused, not half-parsed', () {
      final document = populated().toJson();
      document['note_store_version'] = 999;

      try {
        IronwoodNoteStore.fromJson(document);
        fail('expected the version to be refused');
      } on NoteStoreException catch (e) {
        expect(e.refusal, NoteStoreRefusal.unsupportedVersion);
      }

      document.remove('note_store_version');
      expect(
        () => IronwoodNoteStore.fromJson(document),
        throwsA(
          isA<NoteStoreException>().having(
            (e) => e.refusal,
            'refusal',
            NoteStoreRefusal.unsupportedVersion,
          ),
        ),
      );
    });

    test('another pool\'s document is refused', () {
      final document = populated().toJson();

      expect(
        () => SaplingNoteStore.fromJson(document),
        throwsA(
          isA<NoteStoreException>().having(
            (e) => e.refusal,
            'refusal',
            NoteStoreRefusal.wrongPool,
          ),
        ),
      );
    });

    test('a malformed document is refused', () {
      final document = populated().toJson();
      (document['notes'] as List).first.remove('value');

      expect(
        () => IronwoodNoteStore.fromJson(document),
        throwsA(
          isA<NoteStoreException>().having(
            (e) => e.refusal,
            'refusal',
            NoteStoreRefusal.malformed,
          ),
        ),
      );
    });

    test('an empty store round-trips', () {
      final restored = IronwoodNoteStore.fromJson(IronwoodNoteStore().toJson());

      expect(restored.accountFingerprint, isNull);
      expect(restored.coveredFrom, isNull);
      expect(restored.notes, isEmpty);
      expect(restored.noteSet.unspentZatoshis, 0);
    });
  });
}
