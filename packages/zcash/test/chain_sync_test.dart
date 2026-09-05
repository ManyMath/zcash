import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

// Internal byte order; `chain` marks a fork.
List<int> _hashBytes(int height, {int chain = 0}) {
  final bytes = List<int>.filled(32, 0);
  bytes[0] = chain;
  bytes[1] = height & 0xff;
  bytes[2] = (height >> 8) & 0xff;
  return bytes;
}

String _hashHex(int height, {int chain = 0}) => [
  for (final b in _hashBytes(height, chain: chain))
    b.toRadixString(16).padLeft(2, '0'),
].join();

String _displayedHashHex(int height, {int chain = 0}) =>
    reverseTxidByteOrder(_hashHex(height, chain: chain));

CompactBlock _block({
  required int height,
  required int chain,
  required int parentChain,
}) {
  final tx = CompactTx()
    ..ironwoodActions.add(
      CompactOrchardAction()..nullifier = List<int>.filled(32, 7),
    );
  return CompactBlock()
    ..height = Int64(height)
    ..hash = _hashBytes(height, chain: chain)
    ..prevHash = _hashBytes(height - 1, chain: parentChain)
    ..vtx.add(tx);
}

class _Source {
  _Source({required this.tip});

  int tip;

  int? forkAt;

  final List<CompactBlockScanRange> fetched = [];
  final List<ScanInputEnvelope> scanned = [];

  int _chainAt(int height) {
    final fork = forkAt;
    return fork == null || height <= fork ? 0 : 1;
  }

  Future<int> chainTip() async => tip;

  Future<ZcashLightwalletdScanSource> fetchRange(int start, int end) async {
    fetched.add(CompactBlockScanRange(start: start, end: end));
    return ZcashLightwalletdScanSource([
      for (var height = start; height <= end; height++)
        _block(
          height: height,
          chain: _chainAt(height),
          parentChain: _chainAt(height - 1),
        ),
    ]);
  }

  Future<TreeState> fetchTreeState(int height) async => TreeState(
    hash: _displayedHashHex(height, chain: _chainAt(height)),
    height: height,
    time: 0,
    ironwood: ShieldedTree(finalState: 'tree-$height'),
  );

  Future<String?> servedBlockHashAt(int height) async =>
      height > tip ? null : _hashHex(height, chain: _chainAt(height));

  Future<ZcashScanResult> scan(ScanInputEnvelope envelope) async {
    scanned.add(envelope);
    final range = envelope.range!;
    return ZcashScanResult(
      scannedBlocks: range.end - range.start + 1,
      discoveredNotes: 1,
      totalValue: 1000,
      scannedHeightRange: range,
      notes: [
        ZcashScannedNote(
          height: range.start,
          tx: 'ab' * 32,
          output: range.start,
          value: 1000,
          pool: 'ironwood',
          nullifier: range.start.toRadixString(16).padLeft(2, '0') * 32,
        ),
      ],
    );
  }
}

ZcashChainSync _syncOver(
  _Source source, {
  required IronwoodNoteStore store,
  int from = 11,
  int rangeSize = 100,
  Future<ZcashScanResult> Function(ScanInputEnvelope)? scan,
}) => ZcashChainSync(
  cursor: ZcashLightwalletdSyncCursor.origin(height: from),
  accountFingerprint: 'chain-sync-test',
  ironwoodStore: store,
  chainTip: source.chainTip,
  fetchRange: source.fetchRange,
  fetchTreeState: source.fetchTreeState,
  scan: scan ?? source.scan,
  servedBlockHashAt: source.servedBlockHashAt,
  rangeSize: rangeSize,
);

void main() {
  group('ZcashChainSync', () {
    test('a step fetches, checks, scans, applies and advances', () async {
      final source = _Source(tip: 13);
      final store = IronwoodNoteStore();
      final sync = _syncOver(source, store: store, rangeSize: 2);

      final outcome = await sync.step();

      expect(outcome, isA<ZcashSyncAdvanced>());
      final advanced = outcome as ZcashSyncAdvanced;
      expect(advanced.range.start, 11);
      expect(advanced.range.end, 12);
      expect(source.fetched.single.end, 12);

      expect(sync.cursor.nextHeight, 13);
      expect(sync.cursor.priorIronwoodFrontier, 'tree-12');
      expect(sync.cursor.priorBlockHash, _hashHex(12));
      expect(sync.cursor.trail.highestHeight, 12);
      expect(store.notes.single.height, 11);
      expect(store.coveredThrough, 12);

      final discovered = store.notes.single.nullifier;
      await sync.step();
      expect(source.scanned.last.watchedNullifiers?.ironwood, [discovered]);
      expect(source.scanned.last.watchedNullifiers?.sapling, isEmpty);
    });

    test('syncToTip stops at the height the source reports', () async {
      final source = _Source(tip: 20);
      final store = IronwoodNoteStore();
      final sync = _syncOver(source, store: store, rangeSize: 4);
      final ranges = <CompactBlockScanRange>[];

      final outcome = await sync.syncToTip(
        onAdvanced: (advanced) => ranges.add(advanced.range),
      );

      expect(outcome, isA<ZcashSyncCaughtUp>());
      expect((outcome as ZcashSyncCaughtUp).chainHeight, 20);
      expect(ranges.map((r) => '${r.start}-${r.end}'), [
        '11-14',
        '15-18',
        '19-20',
      ]);
      expect(sync.cursor.nextHeight, 21);
      expect(store.coveredThrough, 20);
    });

    test('a source below the sync is caught up, not an error', () async {
      final source = _Source(tip: 10);
      final sync = _syncOver(source, store: IronwoodNoteStore());

      final outcome = await sync.step();

      expect(outcome, isA<ZcashSyncCaughtUp>());
      expect(source.fetched, isEmpty);
    });

    test('a fork reaches no store and moves no cursor', () async {
      final source = _Source(tip: 20);
      final store = IronwoodNoteStore();
      final sync = _syncOver(source, store: store, rangeSize: 4);
      await sync.syncToTip();

      final before = sync.cursor;
      final notesBefore = store.notes.length;

      source.forkAt = 14;
      source.tip = 24;
      final outcome = await sync.step();

      expect(outcome, isA<ZcashSyncReorged>());
      final reorged = outcome as ZcashSyncReorged;
      expect(reorged.detection.height, 21);
      expect(reorged.recovery.forkHeight, 14);
      expect(reorged.recovery.resumeHeight, 15);
      expect(reorged.recovery.depth, 6);

      expect(
        sync.cursor,
        same(before),
        reason: 'a refused range advances nothing',
      );
      expect(store.notes, hasLength(notesBefore));
      expect(store.coveredThrough, 20);
    });

    test('a reorg below the trail is thrown, not returned', () async {
      final source = _Source(tip: 20);
      final sync = _syncOver(source, store: IronwoodNoteStore(), rangeSize: 4);
      await sync.syncToTip();

      source.forkAt = 5;
      source.tip = 24;
      await expectLater(
        sync.step(),
        throwsA(isA<ZcashReorgTooDeepException>()),
      );
    });

    test('a scan that covered another range is refused', () async {
      final source = _Source(tip: 20);
      final store = IronwoodNoteStore();
      final sync = _syncOver(
        source,
        store: store,
        rangeSize: 4,
        scan: (envelope) async => ZcashScanResult(
          scannedBlocks: 2,
          discoveredNotes: 0,
          totalValue: 0,
          notes: const [],
          scannedHeightRange: const CompactBlockScanRange(start: 11, end: 12),
        ),
      );

      await expectLater(
        sync.step(),
        throwsA(
          isA<ZcashModelException>().having(
            (e) => e.toString(),
            'message',
            contains('requested heights 11-14 and the scan reports 11-12'),
          ),
        ),
      );
      expect(sync.cursor.nextHeight, 11);
      expect(store.coveredThrough, isNull);
    });

    test('a sync with no note store is refused', () {
      final source = _Source(tip: 20);
      expect(
        () => ZcashChainSync(
          cursor: ZcashLightwalletdSyncCursor.origin(height: 11),
          accountFingerprint: 'chain-sync-test',
          chainTip: source.chainTip,
          fetchRange: source.fetchRange,
          fetchTreeState: source.fetchTreeState,
          scan: source.scan,
          servedBlockHashAt: source.servedBlockHashAt,
        ),
        throwsA(isA<ZcashModelException>()),
        reason:
            'a watch set is built out of notes a store already holds, so a '
            'sync that keeps none can never observe a spend',
      );
    });

    group('resuming', () {
      Future<(ZcashChainSync, IronwoodNoteStore, ZcashReorgRecovery)>
      reorgedSync() async {
        final source = _Source(tip: 20);
        final store = IronwoodNoteStore();
        final sync = _syncOver(source, store: store, rangeSize: 4);
        await sync.syncToTip();
        source.forkAt = 14;
        source.tip = 24;
        final outcome = await sync.step() as ZcashSyncReorged;
        return (sync, store, outcome.recovery);
      }

      test('a store still covering the abandoned chain stops it', () async {
        final (sync, store, recovery) = await reorgedSync();

        expect(
          () => sync.resumeFrom(
            recovery: recovery,
            treeState: TreeState(
              hash: _displayedHashHex(14),
              height: 14,
              time: 0,
            ),
          ),
          throwsA(
            isA<ZcashModelException>().having(
              (e) => e.toString(),
              'message',
              allOf(
                contains('rollbackTo(14)'),
                contains('covers through height 20'),
              ),
            ),
          ),
          reason:
              'a reorg is not a spend, so nothing in a later scan removes the '
              'notes the abandoned chain paid',
        );

        expect(store.coveredThrough, 20);
      });

      test(
        'resuming without the fork height\'s tree state is refused',
        () async {
          final (sync, store, recovery) = await reorgedSync();
          store.rollbackTo(recovery.forkHeight);

          expect(
            () => sync.resumeFrom(
              recovery: recovery,
              treeState: TreeState(
                hash: _displayedHashHex(20),
                height: 20,
                time: 0,
                ironwood: const ShieldedTree(finalState: 'tree-20'),
              ),
            ),
            throwsA(
              isA<ZcashModelException>().having(
                (e) => e.toString(),
                'message',
                contains('this tree state is for height 20'),
              ),
            ),
            reason:
                'the frontiers the wallet still holds contain the abandoned '
                'chain\'s leaves',
          );
        },
      );

      test(
        'a tree state from the losing chain at the fork height is refused',
        () async {
          final (sync, store, recovery) = await reorgedSync();
          store.rollbackTo(recovery.forkHeight);

          expect(
            () => sync.resumeFrom(
              recovery: recovery,
              treeState: TreeState(
                hash: _displayedHashHex(14, chain: 1),
                height: 14,
                time: 0,
                ironwood: const ShieldedTree(finalState: 'tree-14'),
              ),
            ),
            throwsA(isA<ZcashChainReorgException>()),
          );
        },
      );

      test('a resumed sync keeps the trail below the fork', () async {
        final (sync, store, recovery) = await reorgedSync();
        store.rollbackTo(recovery.forkHeight);

        sync.resumeFrom(
          recovery: recovery,
          treeState: TreeState(
            hash: _displayedHashHex(14),
            height: 14,
            time: 0,
            ironwood: const ShieldedTree(finalState: 'tree-14'),
          ),
        );

        expect(sync.cursor.nextHeight, 15);
        expect(sync.cursor.priorBlockHash, _hashHex(14));
        expect(sync.cursor.priorIronwoodFrontier, 'tree-14');

        expect(sync.trail.lowestHeight, 11);
        expect(sync.trail.highestHeight, 14);

        final outcome = await sync.syncToTip();
        expect(outcome, isA<ZcashSyncCaughtUp>());
        expect(sync.cursor.nextHeight, 25);
        expect(store.coveredThrough, 24);
        expect(
          store.notes.where((n) => n.height > 14),
          isNotEmpty,
          reason: 'the sync is running again rather than refusing forever',
        );
      });
    });
  });
}
