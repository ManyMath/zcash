import 'dart:convert';

import '../grpc/compact_formats.pb.dart';
import '../grpc/service.pb.dart' as lwd;
import 'chain_reorg.dart';
import 'scan.dart';
import 'spend.dart';
import 'tree_state.dart';

class ZcashLightwalletdScanSource {
  final List<CompactBlock> blocks;

  const ZcashLightwalletdScanSource(this.blocks);

  List<Map<String, Object?>> toScanEntries() => [
    for (final block in blocks)
      {
        'height': block.height.toInt(),
        'data': base64Encode(block.writeToBuffer()),
      },
  ];

  List<CompactBlockScanInput> toScanInputs() => [
    for (final block in blocks)
      CompactBlockScanInput(
        bytes: block.writeToBuffer(),
        height: block.height.toInt(),
      ),
  ];

  List<int> get heights => [for (final b in blocks) b.height.toInt()];

  String? get lastBlockHash =>
      blocks.isEmpty ? null : _hashHexOrNull(blocks.last.hash);

  int get ironwoodActions {
    var total = 0;
    for (final block in blocks) {
      total += _ironwoodActionsIn(block);
    }
    return total;
  }

  int get saplingOutputs {
    var total = 0;
    for (final block in blocks) {
      total += _saplingOutputsIn(block);
    }
    return total;
  }

  int get orchardActions {
    var total = 0;
    for (final block in blocks) {
      total += _orchardActionsIn(block);
    }
    return total;
  }

  int? get ironwoodCommitmentTreeSize =>
      _lastMetadata()?.ironwoodCommitmentTreeSize;

  int? get orchardCommitmentTreeSize =>
      _lastMetadata()?.orchardCommitmentTreeSize;

  int? get saplingCommitmentTreeSize =>
      _lastMetadata()?.saplingCommitmentTreeSize;

  ChainMetadata? _lastMetadata() {
    for (final block in blocks.reversed) {
      if (block.hasChainMetadata()) return block.chainMetadata;
    }
    return null;
  }

  void requireIronwoodParity({required int nodeIronwoodCommitmentTreeSize}) {
    if (nodeIronwoodCommitmentTreeSize <= 0) return;
    final served = ironwoodCommitmentTreeSize;
    if (served != null && served > 0) return;
    throw ZcashModelException(
      'lightwalletd reported an Ironwood commitment tree size of '
      '${served ?? 'nothing'} while the node reports '
      '$nodeIronwoodCommitmentTreeSize for the same chain. This server does '
      'not carry the NU6.3 compact-block fields, so every Ironwood action it '
      'serves decodes as a proto3 default: syncing through it would report no '
      'Ironwood notes and no error.',
    );
  }

  void requireSaplingParity({required int nodeSaplingCommitmentTreeSize}) {
    if (nodeSaplingCommitmentTreeSize <= 0) return;
    final served = saplingCommitmentTreeSize;
    if (served != null && served > 0) return;
    throw ZcashModelException(
      'lightwalletd reported a Sapling commitment tree size of '
      '${served ?? 'nothing'} while the node reports '
      '$nodeSaplingCommitmentTreeSize for the same chain. The Sapling '
      'compact-block fields are as old as compact blocks, so this is not a '
      'server that is too old to know about the pool: it is one that is not '
      'describing the chain it was asked about.',
    );
  }

  void requireOrchardParity({required int nodeOrchardCommitmentTreeSize}) {
    if (nodeOrchardCommitmentTreeSize <= 0) return;
    final served = orchardCommitmentTreeSize;
    if (served != null && served > 0) return;
    throw ZcashModelException(
      'lightwalletd reported an Orchard commitment tree size of '
      '${served ?? 'nothing'} while the node reports '
      '$nodeOrchardCommitmentTreeSize for the same chain. Orchard actions and '
      'Ironwood actions are the same message in different fields, so a server '
      'that serves one and not the other is blind to a pool while looking '
      'healthy in every other answer it gives.',
    );
  }

  void requireParityWith(ZcashCommitmentTreeSizes node) {
    final sapling = node.sapling;
    if (sapling != null) {
      requireSaplingParity(nodeSaplingCommitmentTreeSize: sapling);
    }
    final orchard = node.orchard;
    if (orchard != null) {
      requireOrchardParity(nodeOrchardCommitmentTreeSize: orchard);
    }
    final ironwood = node.ironwood;
    if (ironwood != null) {
      requireIronwoodParity(nodeIronwoodCommitmentTreeSize: ironwood);
    }
  }
}

class ZcashCommitmentTreeSizes {
  final int? sapling;
  final int? orchard;
  final int? ironwood;

  const ZcashCommitmentTreeSizes({this.sapling, this.orchard, this.ironwood});
}

TreeState treeStateFromLightwalletd(lwd.TreeState served) => TreeState(
  hash: served.hash,
  height: served.height.toInt(),
  time: served.time,
  sapling: ShieldedTree(finalState: served.saplingTree),
  orchard: ShieldedTree(finalState: served.orchardTree),
  ironwood: ShieldedTree(finalState: served.ironwoodTree),
);

String? _hashHexOrNull(List<int> bytes) {
  if (bytes.isEmpty) return null;
  final buffer = StringBuffer();
  for (final byte in bytes) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

int _saplingOutputsIn(CompactBlock block) {
  var total = 0;
  for (final tx in block.vtx) {
    total += tx.outputs.length;
  }
  return total;
}

int _orchardActionsIn(CompactBlock block) {
  var total = 0;
  for (final tx in block.vtx) {
    total += tx.actions.length;
  }
  return total;
}

int _ironwoodActionsIn(CompactBlock block) {
  var total = 0;
  for (final tx in block.vtx) {
    total += tx.ironwoodActions.length;
  }
  return total;
}

class ZcashLightwalletdSyncCursor {
  final int nextHeight;

  final String? priorSaplingFrontier;
  final String? priorOrchardFrontier;
  final String? priorIronwoodFrontier;

  final int? priorSaplingSize;
  final int? priorOrchardSize;
  final int? priorIronwoodSize;

  final String? priorBlockHash;

  final ZcashChainTrail trail;

  const ZcashLightwalletdSyncCursor({
    required this.nextHeight,
    this.priorSaplingFrontier,
    this.priorOrchardFrontier,
    this.priorIronwoodFrontier,
    this.priorSaplingSize,
    this.priorOrchardSize,
    this.priorIronwoodSize,
    this.priorBlockHash,
    this.trail = const ZcashChainTrail(checkpoints: []),
  });

  factory ZcashLightwalletdSyncCursor.origin({required int height}) =>
      ZcashLightwalletdSyncCursor(
        nextHeight: height,
        priorSaplingSize: 0,
        priorOrchardSize: 0,
        priorIronwoodSize: 0,
      );

  factory ZcashLightwalletdSyncCursor.fromTreeState(
    TreeState state, {
    int? saplingSize,
    int? orchardSize,
    int? ironwoodSize,
  }) => ZcashLightwalletdSyncCursor(
    nextHeight: state.height + 1,
    priorSaplingFrontier: _frontierOf(state.sapling),
    priorOrchardFrontier: _frontierOf(state.orchard),
    priorIronwoodFrontier: _frontierOf(state.ironwood),
    priorSaplingSize: saplingSize,
    priorOrchardSize: orchardSize,
    priorIronwoodSize: ironwoodSize,
    priorBlockHash: blockHashFromDisplayedHash(state.hash),
    trail: _trailFrom(state),
  );

  factory ZcashLightwalletdSyncCursor.resumingAfterReorg({
    required ZcashReorgRecovery recovery,
    required TreeState treeState,
    required ZcashChainTrail trail,
  }) {
    if (treeState.height != recovery.forkHeight) {
      throw ZcashModelException(
        'a sync resumes after a reorg from the tree state at the fork height: '
        'the chains parted after height ${recovery.forkHeight} and this tree '
        'state is for height ${treeState.height}. Resuming with the frontiers '
        'the wallet already held would seed the next range from a tree '
        'containing the abandoned chain\'s leaves, and every witness built on '
        'it would root at an anchor no node holds.',
      );
    }
    final stateHash = blockHashFromDisplayedHash(treeState.hash);
    if (stateHash != null && stateHash != recovery.forkBlockHash) {
      throw ZcashChainReorgException(
        height: recovery.forkHeight,
        expectedPrevHash: recovery.forkBlockHash,
        servedPrevHash: stateHash,
        message:
            'the recovery found both chains holding block '
            '${recovery.forkBlockHash} at height ${recovery.forkHeight}, and '
            'this tree state is for block $stateHash at that height. The fork '
            'point and the frontiers being resumed from are on two different '
            'chains, which is the case the whole recovery exists to end rather '
            'than to reproduce.',
      );
    }
    return ZcashLightwalletdSyncCursor(
      nextHeight: recovery.resumeHeight,
      priorSaplingFrontier: _frontierOf(treeState.sapling),
      priorOrchardFrontier: _frontierOf(treeState.orchard),
      priorIronwoodFrontier: _frontierOf(treeState.ironwood),
      priorBlockHash: recovery.forkBlockHash,
      trail: trail.truncatedTo(recovery.forkHeight),
    );
  }

  static const int version = 1;

  Map<String, Object?> toJson() => {
    'sync_cursor_version': version,
    'next_height': nextHeight,
    'frontier_height': nextHeight - 1,
    if (priorBlockHash != null) 'prior_block_hash': priorBlockHash,
    if (priorBlockHash != null) 'frontier_block_hash': priorBlockHash,
    if (priorSaplingFrontier != null)
      'prior_sapling_frontier': priorSaplingFrontier,
    if (priorOrchardFrontier != null)
      'prior_orchard_frontier': priorOrchardFrontier,
    if (priorIronwoodFrontier != null)
      'prior_ironwood_frontier': priorIronwoodFrontier,
    if (priorSaplingSize != null) 'prior_sapling_size': priorSaplingSize,
    if (priorOrchardSize != null) 'prior_orchard_size': priorOrchardSize,
    if (priorIronwoodSize != null) 'prior_ironwood_size': priorIronwoodSize,
    'trail': trail.toJson(),
  };

  factory ZcashLightwalletdSyncCursor.fromJson(Map<String, Object?> json) {
    final documentVersion = json['sync_cursor_version'];
    if (documentVersion != version) {
      throw ZcashModelException(
        'sync_cursor_version ${documentVersion ?? '(absent)'} is not $version. '
        'A sync position restored from a schema this build only half '
        'understands scans without error and produces witnesses that root '
        'nowhere, so it is refused rather than read as far as it goes.',
      );
    }

    final nextHeight = _requiredInt(json, 'next_height');
    final priorBlockHash = _optionalString(json, 'prior_block_hash');
    final frontierHeight = _requiredInt(json, 'frontier_height');
    final frontierBlockHash = _optionalString(json, 'frontier_block_hash');

    if (frontierHeight != nextHeight - 1) {
      throw ZcashModelException(
        'this document says its frontiers were taken at height '
        '$frontierHeight and that the next range begins at $nextHeight, so the '
        'frontiers are ${(nextHeight - 1 - frontierHeight).abs()} blocks from '
        'where they are about to be used. A frontier is an opaque serialized '
        'tree and nothing about it says which height it belongs to: a scan '
        'seeded from the wrong one succeeds, exports witnesses, and roots them '
        'at an anchor the chain has never had.',
      );
    }
    if ((frontierBlockHash == null) != (priorBlockHash == null)) {
      throw ZcashModelException(
        'frontier_block_hash and prior_block_hash are written together or not '
        'at all: one without the other is a document that names the chain its '
        'frontiers came from in one field and not in the other.',
      );
    }
    if (frontierBlockHash != null && frontierBlockHash != priorBlockHash) {
      throw ZcashModelException(
        'this document says its frontiers were taken from block '
        '$frontierBlockHash and that the sync reached height $frontierHeight at '
        'block $priorBlockHash. The height matches and the chain does not, '
        'which is a reorg arriving through storage rather than through a '
        'server.',
      );
    }

    final trailJson = json['trail'];
    final trail = trailJson == null
        ? ZcashChainTrail.empty()
        : ZcashChainTrail.fromJson(_asObject(trailJson, 'trail'));
    if (trail.isEmpty && priorBlockHash != null) {
      throw ZcashModelException(
        'this document says the sync reached height ${nextHeight - 1} at block '
        '$priorBlockHash and remembers no heights at all. Those two halves '
        'disagree about what the wallet knows: the position can detect a fork '
        'and the empty trail cannot recover from one, so the first reorg of any '
        'depth would be ZcashReorgTooDeepException and a rescan from the '
        'birthday. A sync that genuinely remembers nothing carries no hash '
        'either — that is the bootstrap, and it is written as both absent.',
      );
    }
    if (!trail.isEmpty) {
      final highest = trail.highestHeight!;
      if (highest != nextHeight - 1) {
        throw ZcashModelException(
          'this document\'s trail ends at height $highest and its next range '
          'begins at $nextHeight, so the wallet would resume from a position '
          'whose own block it never recorded. A fork-point search walks the '
          'trail downwards from where the sync is: a trail that stops short '
          'answers with a height nobody verified, and one that runs past is a '
          'position and a chain that disagree.',
        );
      }
      final trailHash = trail.hashAt(highest);
      if (priorBlockHash == null) {
        throw ZcashModelException(
          'this document\'s trail records block $trailHash at height $highest '
          'and the document names no prior_block_hash. A cursor with no hash '
          'accepts any parent at $nextHeight — which is precisely a '
          'sync that re-anchors onto a fork with no error — so '
          'a restore must not be the way to obtain one.',
        );
      }
      if (trailHash != priorBlockHash) {
        throw ZcashModelException(
          'this document\'s trail records block $trailHash at height $highest '
          'and its prior_block_hash is $priorBlockHash. Those are two chains, '
          'and the sync would detect a fork against one of them while '
          'recovering against the other.',
        );
      }
    }

    return ZcashLightwalletdSyncCursor(
      nextHeight: nextHeight,
      priorSaplingFrontier: _optionalString(json, 'prior_sapling_frontier'),
      priorOrchardFrontier: _optionalString(json, 'prior_orchard_frontier'),
      priorIronwoodFrontier: _optionalString(json, 'prior_ironwood_frontier'),
      priorSaplingSize: _optionalInt(json, 'prior_sapling_size'),
      priorOrchardSize: _optionalInt(json, 'prior_orchard_size'),
      priorIronwoodSize: _optionalInt(json, 'prior_ironwood_size'),
      priorBlockHash: priorBlockHash,
      trail: trail,
    );
  }

  ScanInputEnvelope scanInputFor(
    ZcashLightwalletdScanSource source, {
    String? network,
    bool includeSaplingWitnesses = false,
    bool includeOrchardWitnesses = false,
    ZcashWatchedNullifiers? watchedNullifiers,
  }) {
    final range = _requireContinuation(source);
    return ScanInputEnvelope(
      network: network,
      range: CompactBlockScanRange(start: range.start, end: range.end),
      includeSaplingWitnesses: includeSaplingWitnesses,
      priorSaplingFrontier: priorSaplingFrontier,
      includeOrchardWitnesses: includeOrchardWitnesses,
      priorOrchardFrontier: priorOrchardFrontier,
      priorIronwoodFrontier: priorIronwoodFrontier,
      watchedNullifiers: watchedNullifiers,
      blocks: source.toScanInputs(),
    );
  }

  ZcashLightwalletdSyncCursor advance({
    required ZcashLightwalletdScanSource scanned,
    required TreeState treeState,
  }) {
    final range = _requireContinuation(scanned);
    if (treeState.height != range.end) {
      throw ZcashModelException(
        'a sync advances with the tree state at the end of the range it '
        'scanned: the range ends at height ${range.end} and this tree state is '
        'for height ${treeState.height}. A frontier from another height is '
        'another tree, and every witness seeded from it would root at an '
        'anchor the chain has never had.',
      );
    }
    final stateHash = blockHashFromDisplayedHash(treeState.hash);
    if (stateHash != null &&
        range.lastHash != null &&
        stateHash != range.lastHash) {
      throw ZcashChainReorgException(
        height: range.end,
        expectedPrevHash: range.lastHash,
        servedPrevHash: stateHash,
        message:
            'the tree state for height ${range.end} is for block $stateHash and '
            'the range scanned to that height ends at block ${range.lastHash}. '
            'The height matches and the chain does not: a frontier from another '
            'chain is another tree just as surely as one from another height, '
            'and it is the case a height check cannot see.',
      );
    }
    return ZcashLightwalletdSyncCursor(
      nextHeight: range.end + 1,
      priorSaplingFrontier: _frontierOf(treeState.sapling),
      priorOrchardFrontier: _frontierOf(treeState.orchard),
      priorIronwoodFrontier: _frontierOf(treeState.ironwood),
      priorSaplingSize: range.saplingSize,
      priorOrchardSize: range.orchardSize,
      priorIronwoodSize: range.ironwoodSize,
      priorBlockHash: range.lastHash,
      trail: trail.append(range.checkpoints),
    );
  }

  _ContinuedRange _requireContinuation(ZcashLightwalletdScanSource source) {
    final blocks = source.blocks;
    if (blocks.isEmpty) {
      throw ZcashModelException(
        'a lightwalletd sync range carries no blocks. An empty range advances '
        'nothing and cannot be distinguished from a server that answered with '
        'nothing, so it is refused rather than treated as progress.',
      );
    }

    final heights = source.heights;
    if (heights.first != nextHeight) {
      throw ZcashModelException(
        'this sync has reached height ${nextHeight - 1} and the served range '
        'begins at height ${heights.first}, not $nextHeight. Note commitment '
        'tree sizes are cumulative: the blocks in between appended leaves that '
        'shift the position of every note after them, and nothing in the '
        'served blocks can recover them. Re-fetch from $nextHeight.',
      );
    }
    for (var i = 1; i < heights.length; i++) {
      if (heights[i] != heights[i - 1] + 1) {
        throw ZcashModelException(
          'lightwalletd served heights ${heights[i - 1]} and ${heights[i]} '
          'consecutively, which leaves a hole inside the range. The tree sizes '
          'are cumulative, so scanning across it would position every '
          'subsequent note wrongly and report no error.',
        );
      }
    }

    _requireChained(blocks, heights);

    return _ContinuedRange(
      start: heights.first,
      end: heights.last,
      lastHash: _hashHexOrNull(blocks.last.hash),
      checkpoints: [
        for (var i = 0; i < blocks.length; i++)
          ZcashChainCheckpoint(
            height: heights[i],
            blockHash: _hashHexOrNull(blocks[i].hash)!,
          ),
      ],
      saplingSize: _walkSizes(
        blocks,
        priorSaplingSize,
        'Sapling',
        _saplingOutputsIn,
        (m) => m.saplingCommitmentTreeSize,
      ),
      orchardSize: _walkSizes(
        blocks,
        priorOrchardSize,
        'Orchard',
        _orchardActionsIn,
        (m) => m.orchardCommitmentTreeSize,
      ),
      ironwoodSize: _walkSizes(
        blocks,
        priorIronwoodSize,
        'Ironwood',
        _ironwoodActionsIn,
        (m) => m.ironwoodCommitmentTreeSize,
      ),
    );
  }

  void _requireChained(List<CompactBlock> blocks, List<int> heights) {
    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      final hash = _hashHexOrNull(block.hash);
      final prev = _hashHexOrNull(block.prevHash);
      if (hash == null || prev == null) {
        throw ZcashModelException(
          'the block served for height ${heights[i]} carries '
          '${hash == null ? 'no hash of its own' : 'no parent hash'}. Heights '
          'and cumulative tree sizes are the same on a fork as on the chain the '
          'wallet is on, so the hashes are the only evidence of which chain '
          'this is: a range that omits them cannot be checked and is refused '
          'rather than assumed to continue.',
        );
      }
      if (i > 0) {
        final previous = _hashHexOrNull(blocks[i - 1].hash);
        if (prev == previous) continue;
        throw ZcashModelException(
          'the block served for height ${heights[i]} names $prev as its parent, '
          'and the block served for height ${heights[i - 1]} beside it is '
          '$previous. The range does not chain to itself, so this is one answer '
          'contradicting itself rather than a fork to recover from: re-fetch '
          'it. Scanning it would place the notes in the later blocks at '
          'positions the chain does not have.',
        );
      }

      final expected = priorBlockHash;
      if (expected == null || prev == expected) continue;
      throw ZcashChainReorgException(
        height: heights[i],
        expectedPrevHash: expected,
        servedPrevHash: prev,
        message:
            'this sync reached height ${nextHeight - 1} at block $expected, and '
            'the block served for height $nextHeight names $prev as its parent. '
            'The heights continue and the chain does not: the server is '
            'describing a fork the wallet is not on. Asking again returns the '
            'same blocks, so what has to happen instead is to find the height '
            'at which the two chains still agree, unlearn everything above it, '
            'and resume from there.',
      );
    }
  }

  int? _walkSizes(
    List<CompactBlock> blocks,
    int? prior,
    String pool,
    int Function(CompactBlock) leavesIn,
    int Function(ChainMetadata) declaredBy,
  ) {
    var running = prior;
    for (final block in blocks) {
      final leaves = leavesIn(block);
      if (running != null) running += leaves;
      if (!block.hasChainMetadata()) continue;
      final declared = declaredBy(block.chainMetadata);
      if (running == null) {
        running = declared;
        continue;
      }
      if (declared != running) {
        throw ZcashModelException(
          'the server declares a cumulative $pool commitment tree size of '
          '$declared at height ${block.height}, and this sync has accumulated '
          '$running there. The two disagree, so either the range does not '
          'continue where this sync left off or the server is describing a '
          'different chain. Scanning anyway would place notes at positions the '
          'chain does not have and produce witnesses that root nowhere.',
        );
      }
    }
    return running;
  }
}

Map<String, Object?> _asObject(Object? value, String field) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) return value.cast<String, Object?>();
  throw ZcashModelException('"$field" must be an object');
}

int _requiredInt(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is num) return value.toInt();
  throw ZcashModelException(
    'a sync cursor document must carry an integer "$field"',
  );
}

int? _optionalInt(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value == null) return null;
  if (value is num) return value.toInt();
  throw ZcashModelException('"$field" must be an integer');
}

String? _optionalString(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value == null) return null;
  if (value is String) return value;
  throw ZcashModelException('"$field" must be a string');
}

ZcashChainTrail _trailFrom(TreeState state) {
  final hash = blockHashFromDisplayedHash(state.hash);
  if (hash == null) return ZcashChainTrail.empty();
  return ZcashChainTrail(
    checkpoints: [ZcashChainCheckpoint(height: state.height, blockHash: hash)],
  );
}

class _ContinuedRange {
  final int start;
  final int end;
  final String? lastHash;
  final List<ZcashChainCheckpoint> checkpoints;
  final int? saplingSize;
  final int? orchardSize;
  final int? ironwoodSize;

  const _ContinuedRange({
    required this.start,
    required this.end,
    required this.lastHash,
    required this.checkpoints,
    required this.saplingSize,
    required this.orchardSize,
    required this.ironwoodSize,
  });
}

String? _frontierOf(ShieldedTree? tree) {
  final state = tree?.finalState?.trim();
  if (state == null || state.isEmpty) return null;
  return state;
}
