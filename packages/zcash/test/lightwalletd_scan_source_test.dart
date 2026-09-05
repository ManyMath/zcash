import 'dart:convert';

import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';
import 'package:zcash/lightwalletd_protos.dart' as lwd show TreeState;
import 'package:zcash/zcash.dart';

CompactOrchardAction _action(int seed) =>
    CompactOrchardAction()..nullifier = List<int>.filled(32, seed);

CompactSaplingOutput _output(int seed) =>
    CompactSaplingOutput()..cmu = List<int>.filled(32, seed);

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
  int orchardActions = 0,
  int ironwoodActions = 0,
  int saplingOutputs = 0,
  ChainMetadata? metadata,
  int chain = 0,
  int? parentChain,
  bool omitHash = false,
  bool omitPrevHash = false,
}) {
  final tx = CompactTx()
    ..actions.addAll([for (var i = 0; i < orchardActions; i++) _action(1)])
    ..ironwoodActions.addAll([
      for (var i = 0; i < ironwoodActions; i++) _action(2),
    ])
    ..outputs.addAll([for (var i = 0; i < saplingOutputs; i++) _output(3)]);
  final block = CompactBlock()
    ..height = Int64(height)
    ..vtx.add(tx);
  if (!omitHash) block.hash = _hashBytes(height, chain: chain);
  if (!omitPrevHash) {
    block.prevHash = _hashBytes(height - 1, chain: parentChain ?? chain);
  }
  if (metadata != null) block.chainMetadata = metadata;
  return block;
}

void main() {
  group('ZcashLightwalletdScanSource', () {
    test('a scan entry is the block\'s own bytes and declared height', () {
      final block = _block(height: 42, ironwoodActions: 1);
      final entries = ZcashLightwalletdScanSource([block]).toScanEntries();

      expect(entries, hasLength(1));
      expect(entries.single['height'], 42);
      expect(
        entries.single['data'],
        base64Encode(block.writeToBuffer()),
        reason:
            'a compact block is already what the scanner reads, so the join '
            'must not re-encode it',
      );
    });

    test('Ironwood and Orchard actions are counted apart', () {
      final source = ZcashLightwalletdScanSource([
        _block(height: 1, orchardActions: 2),
        _block(height: 2, ironwoodActions: 3),
      ]);

      expect(source.orchardActions, 2);
      expect(source.ironwoodActions, 3);
      expect(source.heights, [1, 2]);
    });

    test('a server that said nothing is not a server that said zero', () {
      final silent = ZcashLightwalletdScanSource([_block(height: 1)]);
      expect(silent.ironwoodCommitmentTreeSize, isNull);

      final stated = ZcashLightwalletdScanSource([
        _block(
          height: 1,
          metadata: ChainMetadata()..ironwoodCommitmentTreeSize = 0,
        ),
      ]);
      expect(stated.ironwoodCommitmentTreeSize, 0);
    });

    test('tree sizes come from the last block that carried metadata', () {
      final source = ZcashLightwalletdScanSource([
        _block(
          height: 1,
          metadata: ChainMetadata()..ironwoodCommitmentTreeSize = 4,
        ),
        _block(height: 2),
      ]);

      expect(
        source.ironwoodCommitmentTreeSize,
        4,
        reason:
            'the cumulative size is a property of the chain up to the range, '
            'so the most recent statement of it is the answer',
      );
    });

    test('parity passes when the server and the node agree', () {
      final source = ZcashLightwalletdScanSource([
        _block(
          height: 1,
          ironwoodActions: 1,
          metadata: ChainMetadata()..ironwoodCommitmentTreeSize = 2,
        ),
      ]);

      expect(
        () => source.requireIronwoodParity(nodeIronwoodCommitmentTreeSize: 2),
        returnsNormally,
      );
    });

    test('parity says nothing about a chain with no Ironwood notes', () {
      final source = ZcashLightwalletdScanSource([_block(height: 1)]);

      expect(
        () => source.requireIronwoodParity(nodeIronwoodCommitmentTreeSize: 0),
        returnsNormally,
      );
    });

    test('a pre-NU6.3 server is refused rather than believed', () {
      for (final source in [
        ZcashLightwalletdScanSource([_block(height: 1)]),
        ZcashLightwalletdScanSource([
          _block(
            height: 1,
            metadata: ChainMetadata()..ironwoodCommitmentTreeSize = 0,
          ),
        ]),
      ]) {
        expect(
          () => source.requireIronwoodParity(nodeIronwoodCommitmentTreeSize: 7),
          throwsA(
            isA<ZcashModelException>().having(
              (e) => e.toString(),
              'message',
              allOf(contains('NU6.3'), contains('no error')),
            ),
          ),
        );
      }
    });
  });

  group('per-pool parity', () {
    test('Sapling parity is its own check', () {
      final silent = ZcashLightwalletdScanSource([
        _block(
          height: 1,
          metadata: ChainMetadata()..saplingCommitmentTreeSize = 0,
        ),
      ]);
      expect(
        () => silent.requireSaplingParity(nodeSaplingCommitmentTreeSize: 4),
        throwsA(
          isA<ZcashModelException>().having(
            (e) => e.toString(),
            'message',
            contains('Sapling'),
          ),
        ),
      );
      expect(
        () => silent.requireSaplingParity(nodeSaplingCommitmentTreeSize: 0),
        returnsNormally,
        reason: 'an empty pool on both sides is agreement, not a defect',
      );
    });

    test('Orchard parity is its own check', () {
      final source = ZcashLightwalletdScanSource([
        _block(
          height: 1,
          orchardActions: 2,
          metadata: ChainMetadata()
            ..orchardCommitmentTreeSize = 2
            ..ironwoodCommitmentTreeSize = 0,
        ),
      ]);
      expect(
        () => source.requireOrchardParity(nodeOrchardCommitmentTreeSize: 2),
        returnsNormally,
      );

      expect(
        () => source.requireIronwoodParity(nodeIronwoodCommitmentTreeSize: 2),
        throwsA(isA<ZcashModelException>()),
      );
    });

    test('a pool the server never mentioned is not a pool it called empty', () {
      final silent = ZcashLightwalletdScanSource([_block(height: 1)]);
      expect(
        () => silent.requireOrchardParity(nodeOrchardCommitmentTreeSize: 9),
        throwsA(
          isA<ZcashModelException>().having(
            (e) => e.toString(),
            'message',
            contains('nothing'),
          ),
        ),
      );
    });
  });

  group('ZcashLightwalletdSyncCursor', () {
    TreeState treeStateAt(
      int height, {
      String? sapling,
      String? orchard,
      String? ironwood,
      int chain = 0,
    }) => TreeState(
      hash: _displayedHashHex(height, chain: chain),
      height: height,
      time: 0,
      sapling: ShieldedTree(finalState: sapling),
      orchard: ShieldedTree(finalState: orchard),
      ironwood: ShieldedTree(finalState: ironwood),
    );

    test('a scan request carries the prior frontiers into the range', () {
      final cursor = ZcashLightwalletdSyncCursor.fromTreeState(
        treeStateAt(10, sapling: 'aa', orchard: 'bb', ironwood: 'cc'),
      );
      final source = ZcashLightwalletdScanSource([
        _block(
          height: 11,
          ironwoodActions: 2,
          metadata: ChainMetadata()..ironwoodCommitmentTreeSize = 9,
        ),
      ]);

      final json = cursor
          .scanInputFor(
            source,
            network: 'regtest',
            includeOrchardWitnesses: true,
          )
          .toJson();

      expect(json['prior_sapling_frontier'], 'aa');
      expect(json['prior_orchard_frontier'], 'bb');
      expect(json['prior_ironwood_frontier'], 'cc');
      expect(json['include_orchard_witnesses'], true);
      expect(json['range'], {'start': 11, 'end': 11});
      expect((json['blocks'] as List).single, {
        'data': isA<String>(),
        'height': 11,
      });
    });

    test('a watch set travels into the range under its own pool', () {
      final json = ZcashLightwalletdSyncCursor.origin(height: 11)
          .scanInputFor(
            ZcashLightwalletdScanSource([_block(height: 11)]),
            watchedNullifiers: ZcashWatchedNullifiers.forPool('ironwood', [
              'ab' * 32,
            ]),
          )
          .toJson();

      expect(json['watched_nullifiers'], {
        'ironwood': ['ab' * 32],
      });
    });

    test(
      'an empty tree state is a frontier of nothing, not of empty string',
      () {
        final cursor = ZcashLightwalletdSyncCursor.fromTreeState(
          treeStateAt(10, ironwood: ''),
        );
        expect(cursor.priorIronwoodFrontier, isNull);
        expect(cursor.nextHeight, 11);
      },
    );

    test('a range that does not begin where the last one ended is refused', () {
      final cursor = ZcashLightwalletdSyncCursor.origin(height: 1);

      for (final first in [2, 5]) {
        expect(
          () => cursor.scanInputFor(
            ZcashLightwalletdScanSource([_block(height: first)]),
          ),
          throwsA(
            isA<ZcashModelException>().having(
              (e) => e.toString(),
              'message',
              allOf(contains('cumulative'), contains('Re-fetch from 1')),
            ),
          ),
          reason:
              'the skipped blocks appended leaves that shift every note '
              'position after them, and no later scan recovers them',
        );
      }
    });

    test('a range that overlaps the last one is refused too', () {
      final cursor = ZcashLightwalletdSyncCursor.origin(height: 5);
      expect(
        () => cursor.scanInputFor(
          ZcashLightwalletdScanSource([_block(height: 4), _block(height: 5)]),
        ),
        throwsA(isA<ZcashModelException>()),
      );
    });

    test('a hole inside a served range is refused', () {
      final cursor = ZcashLightwalletdSyncCursor.origin(height: 1);
      expect(
        () => cursor.scanInputFor(
          ZcashLightwalletdScanSource([
            _block(height: 1),
            _block(height: 2),
            _block(height: 4),
          ]),
        ),
        throwsA(
          isA<ZcashModelException>().having(
            (e) => e.toString(),
            'message',
            contains('hole inside the range'),
          ),
        ),
      );
    });

    test('an empty range is refused rather than counted as progress', () {
      expect(
        () => ZcashLightwalletdSyncCursor.origin(
          height: 1,
        ).scanInputFor(const ZcashLightwalletdScanSource([])),
        throwsA(isA<ZcashModelException>()),
      );
    });

    test(
      'a served size that disagrees with the accumulated one is refused',
      () {
        final cursor = ZcashLightwalletdSyncCursor(
          nextHeight: 11,
          priorIronwoodSize: 4,
        );

        expect(
          () => cursor.scanInputFor(
            ZcashLightwalletdScanSource([
              _block(
                height: 11,
                ironwoodActions: 2,
                metadata: ChainMetadata()..ironwoodCommitmentTreeSize = 9,
              ),
            ]),
          ),
          throwsA(
            isA<ZcashModelException>().having(
              (e) => e.toString(),
              'message',
              allOf(contains('Ironwood'), contains('9'), contains('6')),
            ),
          ),
        );
      },
    );

    test('each pool is accounted for separately', () {
      final cursor = ZcashLightwalletdSyncCursor(
        nextHeight: 11,
        priorOrchardSize: 0,
        priorIronwoodSize: 0,
      );
      final metadata = ChainMetadata()
        ..orchardCommitmentTreeSize = 2
        ..ironwoodCommitmentTreeSize = 0;

      expect(
        () => cursor.scanInputFor(
          ZcashLightwalletdScanSource([
            _block(height: 11, orchardActions: 2, metadata: metadata),
          ]),
        ),
        returnsNormally,
      );

      expect(
        () => cursor.scanInputFor(
          ZcashLightwalletdScanSource([
            _block(height: 11, ironwoodActions: 2, metadata: metadata),
          ]),
        ),
        throwsA(isA<ZcashModelException>()),
        reason:
            'two Ironwood leaves against an Ironwood size of zero is a '
            'disagreement, whatever the Orchard field says',
      );
    });

    test('Sapling outputs advance the Sapling size', () {
      final cursor = ZcashLightwalletdSyncCursor(
        nextHeight: 11,
        priorSaplingSize: 7,
      );
      expect(
        () => cursor.scanInputFor(
          ZcashLightwalletdScanSource([
            _block(
              height: 11,
              saplingOutputs: 3,
              metadata: ChainMetadata()..saplingCommitmentTreeSize = 10,
            ),
          ]),
        ),
        returnsNormally,
      );
    });

    test('advancing needs the tree state at the end of the range', () {
      final cursor = ZcashLightwalletdSyncCursor.origin(height: 1);
      final source = ZcashLightwalletdScanSource([
        _block(height: 1),
        _block(height: 2),
      ]);

      expect(
        () => cursor.advance(scanned: source, treeState: treeStateAt(1)),
        throwsA(
          isA<ZcashModelException>().having(
            (e) => e.toString(),
            'message',
            contains('another tree'),
          ),
        ),
        reason:
            'a frontier from the middle of the range is a different tree '
            'from the one the next range builds on',
      );
      expect(
        () => cursor.advance(scanned: source, treeState: treeStateAt(2)),
        returnsNormally,
      );
    });

    test('the next cursor carries the frontier and the sizes forward', () {
      final first = ZcashLightwalletdSyncCursor.origin(height: 11);
      final source = ZcashLightwalletdScanSource([
        _block(
          height: 11,
          ironwoodActions: 2,
          saplingOutputs: 1,
          metadata: ChainMetadata()
            ..ironwoodCommitmentTreeSize = 2
            ..saplingCommitmentTreeSize = 1,
        ),
        _block(
          height: 12,
          ironwoodActions: 1,
          metadata: ChainMetadata()
            ..ironwoodCommitmentTreeSize = 3
            ..saplingCommitmentTreeSize = 1,
        ),
      ]);

      final next = first.advance(
        scanned: source,
        treeState: treeStateAt(12, ironwood: 'ff', sapling: 'ee'),
      );

      expect(next.nextHeight, 13);
      expect(next.priorIronwoodFrontier, 'ff');
      expect(next.priorSaplingFrontier, 'ee');
      expect(next.priorIronwoodSize, 3);
      expect(next.priorSaplingSize, 1);
      expect(next.priorOrchardSize, 0);

      expect(
        () => next.scanInputFor(
          ZcashLightwalletdScanSource([_block(height: 14)]),
        ),
        throwsA(isA<ZcashModelException>()),
      );
    });

    test(
      'a sync started from a tree state learns its sizes from the server',
      () {
        final cursor = ZcashLightwalletdSyncCursor.fromTreeState(
          treeStateAt(10, ironwood: 'cc'),
        );
        expect(cursor.priorIronwoodSize, isNull);

        final source = ZcashLightwalletdScanSource([
          _block(
            height: 11,
            ironwoodActions: 2,
            metadata: ChainMetadata()..ironwoodCommitmentTreeSize = 9,
          ),
        ]);
        expect(() => cursor.scanInputFor(source), returnsNormally);

        final next = cursor.advance(
          scanned: source,
          treeState: treeStateAt(11, ironwood: 'dd'),
        );
        expect(next.priorIronwoodSize, 9);
        expect(
          () => next.scanInputFor(
            ZcashLightwalletdScanSource([
              _block(
                height: 12,
                ironwoodActions: 1,
                metadata: ChainMetadata()..ironwoodCommitmentTreeSize = 11,
              ),
            ]),
          ),
          throwsA(isA<ZcashModelException>()),
          reason: 'one leaf on a tree of nine ends at ten, not eleven',
        );
      },
    );

    group('the chain the sync is on', () {
      test('a served range is chained onto the sync, and the hash carried', () {
        final cursor = ZcashLightwalletdSyncCursor(
          nextHeight: 11,
          priorIronwoodSize: 0,
          priorBlockHash: _hashHex(10),
        );
        final source = ZcashLightwalletdScanSource([
          _block(height: 11),
          _block(height: 12),
        ]);

        expect(() => cursor.scanInputFor(source), returnsNormally);
        final next = cursor.advance(
          scanned: source,
          treeState: treeStateAt(12),
        );
        expect(next.priorBlockHash, _hashHex(12));
        expect(source.lastBlockHash, _hashHex(12));
      });

      test('a fork the heights and sizes agree with is refused by type', () {
        final cursor = ZcashLightwalletdSyncCursor(
          nextHeight: 11,
          priorIronwoodSize: 0,
          priorBlockHash: _hashHex(10),
        );

        final fork = ZcashLightwalletdScanSource([
          _block(height: 11, chain: 1),
          _block(height: 12, chain: 1),
        ]);

        expect(
          () => cursor.scanInputFor(fork),
          throwsA(
            isA<ZcashChainReorgException>()
                .having((e) => e.height, 'height', 11)
                .having((e) => e.expectedPrevHash, 'expected', _hashHex(10))
                .having(
                  (e) => e.servedPrevHash,
                  'served',
                  _hashHex(10, chain: 1),
                ),
          ),
          reason:
              'a re-fetch cannot see this case: re-fetching the '
              'range returns the same blocks, so the caller has to react to it '
              'differently and needs the type to tell it apart',
        );
      });

      test('a range that does not chain to itself is not a reorg', () {
        final cursor = ZcashLightwalletdSyncCursor.origin(height: 11);
        final source = ZcashLightwalletdScanSource([
          _block(height: 11),
          _block(height: 12, parentChain: 1),
        ]);

        expect(
          () => cursor.scanInputFor(source),
          throwsA(
            allOf(
              isA<ZcashModelException>(),
              isNot(isA<ZcashChainReorgException>()),
              predicate<Object>(
                (e) => e.toString().contains('does not chain to itself'),
              ),
            ),
          ),
        );
      });

      test('a range that omits the hashes is refused, not assumed', () {
        final cursor = ZcashLightwalletdSyncCursor.origin(height: 11);

        for (final source in [
          ZcashLightwalletdScanSource([_block(height: 11, omitHash: true)]),
          ZcashLightwalletdScanSource([_block(height: 11, omitPrevHash: true)]),
        ]) {
          expect(
            () => cursor.scanInputFor(source),
            throwsA(isA<ZcashModelException>()),
            reason:
                'both routes into the scanner fill these in, so a range without '
                'them is one this check cannot run on — and treating that as '
                'agreement lets any server switch the check off by omission',
          );
        }
      });

      test(
        'a tree state at the right height on the wrong chain is refused',
        () {
          final cursor = ZcashLightwalletdSyncCursor.origin(height: 11);
          final source = ZcashLightwalletdScanSource([_block(height: 11)]);

          expect(
            () => cursor.advance(
              scanned: source,
              treeState: treeStateAt(11, chain: 1),
            ),
            throwsA(
              isA<ZcashChainReorgException>().having(
                (e) => e.height,
                'height',
                11,
              ),
            ),
          );
        },
      );

      test('the two byte orders are converted, and in this direction', () {
        // Pins the direction, not just symmetry: displayed is the reversal.
        final displayed = _displayedHashHex(10);
        expect(displayed, isNot(_hashHex(10)));
        expect(blockHashFromDisplayedHash(displayed), _hashHex(10));

        final cursor = ZcashLightwalletdSyncCursor.fromTreeState(
          treeStateAt(10),
        );
        expect(cursor.priorBlockHash, _hashHex(10));
        expect(
          () => cursor.scanInputFor(
            ZcashLightwalletdScanSource([_block(height: 11)]),
          ),
          returnsNormally,
        );
      });

      test('a sync told no hash adopts the first one it is served', () {
        final cursor = ZcashLightwalletdSyncCursor.origin(height: 11);
        expect(cursor.priorBlockHash, isNull);

        final source = ZcashLightwalletdScanSource([
          _block(height: 11, chain: 1),
        ]);
        expect(() => cursor.scanInputFor(source), returnsNormally);

        final next = cursor.advance(
          scanned: source,
          treeState: treeStateAt(11, chain: 1),
        );
        expect(next.priorBlockHash, _hashHex(11, chain: 1));
        expect(
          () => next.scanInputFor(
            ZcashLightwalletdScanSource([_block(height: 12)]),
          ),
          throwsA(isA<ZcashChainReorgException>()),
          reason: 'the chain it adopted is the chain it now holds servers to',
        );
      });
    });

    group('closing and reopening', () {
      ZcashLightwalletdSyncCursor syncedCursor() {
        var cursor = ZcashLightwalletdSyncCursor.fromTreeState(
          treeStateAt(10, sapling: 'aa', orchard: 'bb', ironwood: 'cc'),
          saplingSize: 4,
          orchardSize: 5,
          ironwoodSize: 6,
        );
        for (var height = 11; height <= 13; height++) {
          final source = ZcashLightwalletdScanSource([
            _block(height: height, ironwoodActions: 1),
          ]);
          cursor = cursor.advance(
            scanned: source,
            treeState: treeStateAt(
              height,
              sapling: 'aa$height',
              orchard: 'bb$height',
              ironwood: 'cc$height',
            ),
          );
        }
        return cursor;
      }

      Map<String, Object?> documentOf(ZcashLightwalletdSyncCursor cursor) =>
          (jsonDecode(jsonEncode(cursor.toJson())) as Map)
              .cast<String, Object?>();

      test('a written position reopens as the same position', () {
        final cursor = syncedCursor();
        final restored = ZcashLightwalletdSyncCursor.fromJson(
          documentOf(cursor),
        );

        expect(restored.nextHeight, 14);
        expect(restored.priorSaplingFrontier, 'aa13');
        expect(restored.priorOrchardFrontier, 'bb13');
        expect(restored.priorIronwoodFrontier, 'cc13');
        expect(restored.priorSaplingSize, cursor.priorSaplingSize);
        expect(restored.priorOrchardSize, cursor.priorOrchardSize);
        expect(restored.priorIronwoodSize, cursor.priorIronwoodSize);
        expect(restored.priorBlockHash, _hashHex(13));

        expect(restored.trail.lowestHeight, 10);
        expect(restored.trail.highestHeight, 13);
        expect(restored.trail.hashAt(11), _hashHex(11));

        expect(
          () => restored.scanInputFor(
            ZcashLightwalletdScanSource([_block(height: 14)]),
          ),
          returnsNormally,
        );
        expect(
          () => restored.scanInputFor(
            ZcashLightwalletdScanSource([
              _block(height: 14, chain: 1, parentChain: 1),
            ]),
          ),
          throwsA(isA<ZcashChainReorgException>()),
          reason: 'a reopened sync knows which chain it is on',
        );
      });

      test('a bootstrap position survives with nothing in it', () {
        final restored = ZcashLightwalletdSyncCursor.fromJson(
          documentOf(ZcashLightwalletdSyncCursor.origin(height: 11)),
        );
        expect(restored.nextHeight, 11);
        expect(restored.priorBlockHash, isNull);
        expect(restored.priorIronwoodFrontier, isNull);
        expect(restored.priorIronwoodSize, 0);
        expect(restored.trail.isEmpty, isTrue);
      });

      test('an absent or unknown version is refused, not read anyway', () {
        final document = documentOf(syncedCursor());

        expect(
          () => ZcashLightwalletdSyncCursor.fromJson(
            {...document}..remove('sync_cursor_version'),
          ),
          throwsA(isA<ZcashModelException>()),
        );
        expect(
          () => ZcashLightwalletdSyncCursor.fromJson({
            ...document,
            'sync_cursor_version': 2,
          }),
          throwsA(
            isA<ZcashModelException>().having(
              (e) => e.toString(),
              'message',
              contains('is not 1'),
            ),
          ),
        );
      });

      test('frontiers stamped for another height are refused', () {
        final document = documentOf(syncedCursor());

        expect(
          () => ZcashLightwalletdSyncCursor.fromJson({
            ...document,
            'next_height': 20,
            'trail': ZcashChainTrail.empty().toJson(),
          }),
          throwsA(
            isA<ZcashModelException>().having(
              (e) => e.toString(),
              'message',
              contains('6 blocks from where they are about to be used'),
            ),
          ),
        );
      });

      test('frontiers from another chain at the right height are refused', () {
        final document = documentOf(syncedCursor());

        expect(
          () => ZcashLightwalletdSyncCursor.fromJson({
            ...document,
            'frontier_block_hash': _hashHex(13, chain: 1),
          }),
          throwsA(
            isA<ZcashModelException>().having(
              (e) => e.toString(),
              'message',
              contains('The height matches and the chain does not'),
            ),
          ),
        );
      });

      test('a trail that stops short of the position is refused', () {
        final trail = ZcashChainTrail(
          checkpoints: [
            for (var height = 10; height <= 12; height++)
              ZcashChainCheckpoint(height: height, blockHash: _hashHex(height)),
          ],
        );

        expect(
          () => ZcashLightwalletdSyncCursor.fromJson({
            ...documentOf(syncedCursor()),
            'trail': trail.toJson(),
          }),
          throwsA(
            isA<ZcashModelException>().having(
              (e) => e.toString(),
              'message',
              contains('trail ends at height 12'),
            ),
          ),
        );
      });

      test('a trail with a hole in it is refused', () {
        final holed = {
          'chain_trail_version': ZcashChainTrail.version,
          'limit': 200,
          'checkpoints': [
            {'height': 10, 'block_hash': _hashHex(10)},
            {'height': 13, 'block_hash': _hashHex(13)},
          ],
        };

        expect(
          () => ZcashLightwalletdSyncCursor.fromJson({
            ...documentOf(syncedCursor()),
            'trail': holed,
          }),
          throwsA(
            isA<ZcashModelException>().having(
              (e) => e.toString(),
              'message',
              contains('holds height 10 and then height 13'),
            ),
          ),
        );
      });

      test('a trail describing another chain than the position is refused', () {
        final forked = ZcashChainTrail(
          checkpoints: [
            for (var height = 10; height <= 13; height++)
              ZcashChainCheckpoint(
                height: height,
                blockHash: _hashHex(height, chain: 1),
              ),
          ],
        );

        expect(
          () => ZcashLightwalletdSyncCursor.fromJson({
            ...documentOf(syncedCursor()),
            'trail': forked.toJson(),
          }),
          throwsA(
            isA<ZcashModelException>().having(
              (e) => e.toString(),
              'message',
              contains('two chains'),
            ),
          ),
          reason:
              'the sync would detect a fork against one chain and recover '
              'against the other',
        );
      });

      test('a remembered block with no position hash is refused', () {
        final document = documentOf(syncedCursor())
          ..remove('prior_block_hash')
          ..remove('frontier_block_hash');

        expect(
          () => ZcashLightwalletdSyncCursor.fromJson(document),
          throwsA(
            isA<ZcashModelException>().having(
              (e) => e.toString(),
              'message',
              contains('accepts any parent'),
            ),
          ),
        );
      });

      test('a position that remembers no height at all is refused', () {
        expect(
          () => ZcashLightwalletdSyncCursor.fromJson({
            ...documentOf(syncedCursor()),
            'trail': ZcashChainTrail.empty().toJson(),
          }),
          throwsA(
            isA<ZcashModelException>().having(
              (e) => e.toString(),
              'message',
              contains('remembers no heights at all'),
            ),
          ),
        );
      });

      test('a position hash with no frontier stamp is refused', () {
        expect(
          () => ZcashLightwalletdSyncCursor.fromJson(
            documentOf(syncedCursor())..remove('frontier_block_hash'),
          ),
          throwsA(
            isA<ZcashModelException>().having(
              (e) => e.toString(),
              'message',
              contains('together or not at all'),
            ),
          ),
        );
      });
    });
  });

  group('requireParityWith', () {
    final seeing = ZcashLightwalletdScanSource([
      _block(
        height: 11,
        ironwoodActions: 1,
        metadata: ChainMetadata()..ironwoodCommitmentTreeSize = 4,
      ),
    ]);
    final blind = ZcashLightwalletdScanSource([
      _block(
        height: 11,
        metadata: ChainMetadata()..ironwoodCommitmentTreeSize = 0,
      ),
    ]);

    test('refuses a server that cannot see a pool the chain has', () {
      expect(
        () => blind.requireParityWith(
          const ZcashCommitmentTreeSizes(ironwood: 4),
        ),
        throwsA(
          isA<ZcashModelException>().having(
            (e) => e.toString(),
            'message',
            contains('NU6.3 compact-block fields'),
          ),
        ),
      );
    });

    test('a pool with no second opinion asserts nothing', () {
      expect(
        () => blind.requireParityWith(const ZcashCommitmentTreeSizes()),
        returnsNormally,
      );
    });

    test('accepts a server that sees what the chain has', () {
      expect(
        () => seeing.requireParityWith(
          const ZcashCommitmentTreeSizes(sapling: 0, orchard: 0, ironwood: 4),
        ),
        returnsNormally,
      );
    });
  });

  group('treeStateFromLightwalletd', () {
    test('carries the hash in the order the cursor turns around', () {
      final cursor = ZcashLightwalletdSyncCursor.fromTreeState(
        treeStateFromLightwalletd(
          lwd.TreeState()
            ..height = Int64(210)
            ..hash = _displayedHashHex(210)
            ..saplingTree = 'sapling-frontier'
            ..orchardTree = 'orchard-frontier'
            ..ironwoodTree = 'ironwood-frontier',
        ),
      );

      expect(cursor.nextHeight, 211);
      expect(cursor.priorSaplingFrontier, 'sapling-frontier');
      expect(cursor.priorOrchardFrontier, 'orchard-frontier');
      expect(cursor.priorIronwoodFrontier, 'ironwood-frontier');
      expect(cursor.priorBlockHash, _hashHex(210));
      expect(cursor.trail.checkpoints.single.height, 210);
    });

    test('an empty tree stays empty rather than becoming a frontier', () {
      final cursor = ZcashLightwalletdSyncCursor.fromTreeState(
        treeStateFromLightwalletd(
          lwd.TreeState()
            ..height = Int64(9)
            ..hash = _displayedHashHex(9),
        ),
      );

      expect(cursor.priorSaplingFrontier, isNull);
      expect(cursor.priorOrchardFrontier, isNull);
      expect(cursor.priorIronwoodFrontier, isNull);
    });
  });
}
