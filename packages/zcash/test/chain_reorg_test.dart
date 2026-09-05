import 'dart:convert';

import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

// Internal byte order; `chain` marks a fork.
String _hashHex(int height, {int chain = 0}) {
  final bytes = List<int>.filled(32, 0);
  bytes[0] = chain;
  bytes[1] = height & 0xff;
  bytes[2] = (height >> 8) & 0xff;
  return [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();
}

List<int> _hashBytes(int height, {int chain = 0}) {
  final hex = _hashHex(height, chain: chain);
  return [
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
}

CompactBlock _block(int height, {int chain = 0, int? parentChain}) =>
    CompactBlock()
      ..height = Int64(height)
      ..hash = _hashBytes(height, chain: chain)
      ..prevHash = _hashBytes(height - 1, chain: parentChain ?? chain);

ZcashChainTrail _trail(
  Iterable<int> heights, {
  int chain = 0,
  int limit = 200,
}) => ZcashChainTrail(
  limit: limit,
  checkpoints: [
    for (final height in heights)
      ZcashChainCheckpoint(
        height: height,
        blockHash: _hashHex(height, chain: chain),
      ),
  ],
);

Future<String?> Function(int) _server({required int chain, required int tip}) =>
    (height) async => height > tip ? null : _hashHex(height, chain: chain);

ZcashScannedNote _note({
  required int value,
  required String nullifier,
  required int height,
  String tx = 'aa',
  int output = 0,
}) => ZcashScannedNote(
  height: height,
  tx: tx * 32,
  output: output,
  value: value,
  pool: 'ironwood',
  nullifier: nullifier,
  commitmentPosition: 0,
  isChange: false,
  recipient: 'uregtest1example',
  rseed: '11' * 32,
  rho: '22' * 32,
  noteVersion: 'v3',
  witness: '33' * 40,
);

ZcashScanResult _scan({
  List<ZcashScannedNote> notes = const [],
  List<ZcashObservedSpend> spends = const [],
  required int from,
  required int to,
}) => ZcashScanResult(
  scannedBlocks: to - from + 1,
  discoveredNotes: notes.length,
  totalValue: notes.fold(0, (sum, note) => sum + note.value),
  notes: notes,
  spends: spends,
  scannedHeightRange: CompactBlockScanRange(start: from, end: to),
);

void main() {
  group('ZcashChainTrail', () {
    test('a sync appends every height it accepted', () {
      final cursor = ZcashLightwalletdSyncCursor.origin(height: 11);
      final next = cursor.advance(
        scanned: ZcashLightwalletdScanSource([
          _block(11),
          _block(12),
          _block(13),
        ]),
        treeState: TreeState(
          hash: reverseTxidByteOrder(_hashHex(13)),
          height: 13,
          time: 0,
        ),
      );

      expect(next.trail.checkpoints.map((c) => c.height), [11, 12, 13]);
      expect(next.trail.hashAt(12), _hashHex(12));
      expect(next.trail.highestHeight, 13);
    });

    test('a sync bootstrapped from a tree state starts on that block', () {
      final cursor = ZcashLightwalletdSyncCursor.fromTreeState(
        TreeState(
          hash: reverseTxidByteOrder(_hashHex(10)),
          height: 10,
          time: 0,
        ),
      );

      expect(cursor.trail.checkpoints.single.height, 10);
      expect(cursor.trail.hashAt(10), _hashHex(10));
    });

    test('the trail is bounded, oldest first out', () {
      var trail = _trail([], limit: 3);
      for (var height = 1; height <= 6; height++) {
        trail = trail.append([
          ZcashChainCheckpoint(height: height, blockHash: _hashHex(height)),
        ]);
      }

      expect(trail.checkpoints.map((c) => c.height), [4, 5, 6]);
      expect(
        trail.hashAt(1),
        isNull,
        reason:
            'a wallet cannot keep every hash, and what it dropped it must not '
            'claim to remember',
      );
    });

    test('a hole in the trail is refused', () {
      expect(
        () => _trail([
          1,
          2,
        ]).append([ZcashChainCheckpoint(height: 4, blockHash: _hashHex(4))]),
        throwsA(isA<ZcashModelException>()),
        reason:
            'a trail with a hole answers a fork-point search with a height the '
            'wallet never verified',
      );
    });

    test(
      'a trail survives a restart, and refuses a version it cannot read',
      () {
        final trail = _trail([7, 8, 9]);
        final restored = ZcashChainTrail.fromJson(
          jsonDecode(jsonEncode(trail.toJson())) as Map<String, Object?>,
        );

        expect(restored.checkpoints.map((c) => c.height), [7, 8, 9]);
        expect(restored.hashAt(9), _hashHex(9));
        expect(restored.limit, trail.limit);

        expect(
          () => ZcashChainTrail.fromJson({'chain_trail_version': 2}),
          throwsA(isA<ZcashModelException>()),
        );
        expect(
          () => ZcashChainTrail.fromJson({'checkpoints': []}),
          throwsA(isA<ZcashModelException>()),
          reason: 'an absent version is not version 1',
        );
      },
    );

    test('a restored trail is refused a hole that append would refuse', () {
      expect(
        () => ZcashChainTrail.fromJson({
          'chain_trail_version': ZcashChainTrail.version,
          'checkpoints': [
            {'height': 7, 'block_hash': _hashHex(7)},
            {'height': 9, 'block_hash': _hashHex(9)},
          ],
        }),
        throwsA(
          isA<ZcashModelException>().having(
            (e) => e.toString(),
            'message',
            contains('holds height 7 and then height 9'),
          ),
        ),
      );
    });
  });

  group('ZcashReorgRecovery', () {
    test(
      'the fork point is the last agreeing height, not the first that is not',
      () async {
        final served = <int>[];
        final result = await ZcashReorgRecovery.find(
          trail: _trail([1, 2, 3, 4, 5]),
          servedBlockHashAt: (height) async {
            served.add(height);
            return height <= 3 ? _hashHex(height) : _hashHex(height, chain: 1);
          },
        );

        expect(result.forkHeight, 3);
        expect(result.forkBlockHash, _hashHex(3));
        expect(result.resumeHeight, 4);
        expect(result.depth, 2);
        expect(served, [
          5,
          4,
          3,
        ], reason: 'the walk is downwards and stops at the first agreement');
      },
    );

    test('a reorg deeper than the trail is refused, not guessed', () async {
      await expectLater(
        ZcashReorgRecovery.find(
          trail: _trail([100, 101, 102]),
          servedBlockHashAt: _server(chain: 1, tip: 102),
        ),
        throwsA(
          isA<ZcashReorgTooDeepException>().having(
            (e) => e.lowestHeightSearched,
            'lowest',
            100,
          ),
        ),
      );
    });

    test(
      'a wallet with no trail is told to rescan rather than given a height',
      () async {
        await expectLater(
          ZcashReorgRecovery.find(
            trail: ZcashChainTrail.empty(),
            servedBlockHashAt: _server(chain: 0, tip: 100),
          ),
          throwsA(isA<ZcashReorgTooDeepException>()),
        );
      },
    );

    test('a server that is merely behind resolves to its own tip', () async {
      final recovery = await ZcashReorgRecovery.find(
        trail: _trail([10, 11, 12, 13]),
        servedBlockHashAt: _server(chain: 0, tip: 11),
      );

      expect(recovery.forkHeight, 11);
      expect(recovery.resumeHeight, 12);
      expect(recovery.depth, 2);
    });
  });

  group('the wallet state a reorg withdraws', () {
    const spentNote = 'ab';
    const forkNote = 'cd';

    test(
      'rolling a store back to the fork point moves the balance both ways',
      () {
        final store = IronwoodNoteStore();
        store.apply(
          _scan(
            notes: [
              _note(value: 100000, nullifier: spentNote * 32, height: 100),
            ],
            from: 1,
            to: 500,
          ),
          accountFingerprint: 'account-a',
        );
        store.apply(
          _scan(
            notes: [
              _note(
                value: 700000,
                nullifier: forkNote * 32,
                height: 620,
                tx: 'dd',
              ),
            ],
            spends: [
              ZcashObservedSpend(
                height: 640,
                tx: 'bb' * 32,
                pool: 'ironwood',
                nullifier: spentNote * 32,
                index: 0,
              ),
            ],
            from: 501,
            to: 700,
          ),
          accountFingerprint: 'account-a',
        );
        expect(store.noteSet.unspentZatoshis, 700000);

        store.rollbackTo(600);

        expect(
          store.noteSet.unspentZatoshis,
          100000,
          reason:
              'the fork note is gone and the note whose spend was only on the '
              'fork is owned again',
        );
        expect(store.notes.map((n) => n.nullifier), [spentNote * 32]);
        expect(store.spends, isEmpty);
        expect(store.coveredThrough, 600);
      },
    );

    test('a recovery names the height the stores are rolled back to', () async {
      final recovery = await ZcashReorgRecovery.find(
        trail: _trail([598, 599, 600, 601, 602]),
        servedBlockHashAt: (height) async =>
            height <= 600 ? _hashHex(height) : _hashHex(height, chain: 1),
      );

      final store = IronwoodNoteStore();
      store.apply(
        _scan(
          notes: [_note(value: 500, nullifier: forkNote * 32, height: 601)],
          from: 598,
          to: 602,
        ),
        accountFingerprint: 'account-a',
      );
      expect(store.noteSet.unspentZatoshis, 500);

      store.rollbackTo(recovery.forkHeight);

      expect(store.noteSet.unspentZatoshis, 0);
      expect(store.coveredThrough, 600);
      expect(recovery.resumeHeight, 601);
    });
  });
}
