import 'spend.dart';
import 'transaction.dart';

String? blockHashFromDisplayedHash(String? displayed) {
  final trimmed = displayed?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return reverseTxidByteOrder(trimmed.toLowerCase());
}

class ZcashChainReorgException implements ZcashModelException {
  @override
  final String message;

  final int height;

  final String? expectedPrevHash;

  final String servedPrevHash;

  const ZcashChainReorgException({
    required this.message,
    required this.height,
    required this.expectedPrevHash,
    required this.servedPrevHash,
  });

  @override
  String toString() => 'ZcashChainReorgException: $message';
}

class ZcashReorgTooDeepException implements ZcashModelException {
  @override
  final String message;

  final int lowestHeightSearched;

  const ZcashReorgTooDeepException({
    required this.message,
    required this.lowestHeightSearched,
  });

  @override
  String toString() => 'ZcashReorgTooDeepException: $message';
}

class ZcashChainTrail {
  final List<ZcashChainCheckpoint> checkpoints;

  final int limit;

  const ZcashChainTrail({required this.checkpoints, this.limit = 200});

  factory ZcashChainTrail.empty({int limit = 200}) =>
      ZcashChainTrail(checkpoints: const [], limit: limit);

  bool get isEmpty => checkpoints.isEmpty;

  int? get lowestHeight =>
      checkpoints.isEmpty ? null : checkpoints.first.height;

  int? get highestHeight =>
      checkpoints.isEmpty ? null : checkpoints.last.height;

  String? hashAt(int height) {
    for (final checkpoint in checkpoints) {
      if (checkpoint.height == height) return checkpoint.blockHash;
    }
    return null;
  }

  ZcashChainTrail append(List<ZcashChainCheckpoint> additions) {
    if (additions.isEmpty) return this;
    final combined = [...checkpoints];
    for (final addition in additions) {
      final last = combined.isEmpty ? null : combined.last;
      if (last != null && addition.height != last.height + 1) {
        throw ZcashModelException(
          'a chain trail records the heights a sync accepted, in order: it '
          'holds up to height ${last.height} and was handed height '
          '${addition.height}. A hole in the trail answers a fork-point search '
          'with a height the wallet never verified.',
        );
      }
      combined.add(addition);
    }
    if (combined.length > limit) {
      combined.removeRange(0, combined.length - limit);
    }
    return ZcashChainTrail(checkpoints: combined, limit: limit);
  }

  ZcashChainTrail truncatedTo(int height) => ZcashChainTrail(
    limit: limit,
    checkpoints: [
      for (final checkpoint in checkpoints)
        if (checkpoint.height <= height) checkpoint,
    ],
  );

  static const int version = 1;

  Map<String, Object?> toJson() => {
    'chain_trail_version': version,
    'limit': limit,
    'checkpoints': [
      for (final checkpoint in checkpoints)
        {'height': checkpoint.height, 'block_hash': checkpoint.blockHash},
    ],
  };

  factory ZcashChainTrail.fromJson(Map<String, Object?> json) {
    final documentVersion = json['chain_trail_version'];
    if (documentVersion != version) {
      throw ZcashModelException(
        'chain_trail_version ${documentVersion ?? '(absent)'} is not $version',
      );
    }
    final entries = (json['checkpoints'] as List? ?? const []);
    final checkpoints = <ZcashChainCheckpoint>[];
    for (final entry in entries.cast<Map<String, Object?>>()) {
      final checkpoint = ZcashChainCheckpoint(
        height: (entry['height'] as num).toInt(),
        blockHash: entry['block_hash'] as String,
      );
      final last = checkpoints.isEmpty ? null : checkpoints.last;
      if (last != null && checkpoint.height != last.height + 1) {
        throw ZcashModelException(
          'this chain trail document holds height ${last.height} and then '
          'height ${checkpoint.height}. A trail records the heights a sync '
          'accepted, in order and without holes: restoring one with a gap in '
          'it would answer a fork-point search with a height the wallet never '
          'verified, which is the hole append refuses to make while running.',
        );
      }
      checkpoints.add(checkpoint);
    }
    return ZcashChainTrail(
      limit: (json['limit'] as num?)?.toInt() ?? 200,
      checkpoints: checkpoints,
    );
  }
}

class ZcashChainCheckpoint {
  final int height;

  final String blockHash;

  const ZcashChainCheckpoint({required this.height, required this.blockHash});
}

class ZcashReorgRecovery {
  final int forkHeight;

  final String forkBlockHash;

  final int resumeHeight;

  final int depth;

  const ZcashReorgRecovery({
    required this.forkHeight,
    required this.forkBlockHash,
    required this.resumeHeight,
    required this.depth,
  });

  static Future<ZcashReorgRecovery> find({
    required ZcashChainTrail trail,
    required Future<String?> Function(int height) servedBlockHashAt,
  }) async {
    if (trail.isEmpty) {
      throw ZcashReorgTooDeepException(
        lowestHeightSearched: 0,
        message:
            'this wallet has no chain trail, so there is nothing to compare a '
            'server against and no fork point to find. A sync that kept no '
            'hashes cannot recover from a reorg: rescan from the birthday.',
      );
    }

    for (final checkpoint in trail.checkpoints.reversed) {
      final served = await servedBlockHashAt(checkpoint.height);
      if (served != null && served == checkpoint.blockHash) {
        return ZcashReorgRecovery(
          forkHeight: checkpoint.height,
          forkBlockHash: checkpoint.blockHash,
          resumeHeight: checkpoint.height + 1,
          depth: trail.checkpoints.last.height - checkpoint.height,
        );
      }
    }

    final lowest = trail.lowestHeight!;
    throw ZcashReorgTooDeepException(
      lowestHeightSearched: lowest,
      message:
          'the server disagrees with every height this wallet remembers, down '
          'to $lowest, so the chains parted below the trail. Returning $lowest '
          'anyway would roll back to a block that is itself not on the '
          "server's chain and resume from it, which is a wallet that is "
          'confident and wrong. Rescan from the birthday.',
    );
  }
}
