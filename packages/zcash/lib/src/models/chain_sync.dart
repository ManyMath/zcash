import 'chain_reorg.dart';
import 'lightwalletd_scan_source.dart';
import 'note_store.dart';
import 'scan.dart';
import 'spend.dart';
import 'tree_state.dart';

sealed class ZcashSyncOutcome {
  const ZcashSyncOutcome();
}

class ZcashSyncAdvanced extends ZcashSyncOutcome {
  final CompactBlockScanRange range;

  final ZcashScanResult scan;

  final ZcashLightwalletdSyncCursor cursor;

  const ZcashSyncAdvanced({
    required this.range,
    required this.scan,
    required this.cursor,
  });
}

class ZcashSyncCaughtUp extends ZcashSyncOutcome {
  final int chainHeight;

  const ZcashSyncCaughtUp({required this.chainHeight});
}

class ZcashSyncReorged extends ZcashSyncOutcome {
  final ZcashReorgRecovery recovery;

  final ZcashChainReorgException detection;

  const ZcashSyncReorged({required this.recovery, required this.detection});
}

class ZcashChainSync {
  ZcashChainSync({
    required ZcashLightwalletdSyncCursor cursor,
    required this.accountFingerprint,
    required this.chainTip,
    required this.fetchRange,
    required this.fetchTreeState,
    required this.scan,
    required this.servedBlockHashAt,
    this.saplingStore,
    this.orchardStore,
    this.ironwoodStore,
    this.network,
    this.includeSaplingWitnesses = false,
    this.includeOrchardWitnesses = false,
    this.rangeSize = 100,
  }) : _cursor = cursor {
    if (saplingStore == null && orchardStore == null && ironwoodStore == null) {
      throw ZcashModelException(
        'a sync with no note store advances a cursor and remembers nothing: '
        'the notes it discovers are dropped, and the spends it would have '
        'watched for can never be watched, because a watch set is built out of '
        'notes a store already holds.',
      );
    }
    if (rangeSize < 1) {
      throw ZcashModelException('a sync range covers at least one block');
    }
  }

  final Future<int> Function() chainTip;

  final Future<ZcashLightwalletdScanSource> Function(int start, int end)
  fetchRange;

  final Future<TreeState> Function(int height) fetchTreeState;

  final Future<ZcashScanResult> Function(ScanInputEnvelope envelope) scan;

  final Future<String?> Function(int height) servedBlockHashAt;

  final String accountFingerprint;

  final SaplingNoteStore? saplingStore;
  final OrchardNoteStore? orchardStore;
  final IronwoodNoteStore? ironwoodStore;

  final String? network;

  final bool includeSaplingWitnesses;
  final bool includeOrchardWitnesses;

  final int rangeSize;

  ZcashLightwalletdSyncCursor _cursor;
  bool _stepping = false;

  ZcashLightwalletdSyncCursor get cursor => _cursor;

  ZcashChainTrail get trail => _cursor.trail;

  ZcashWatchedNullifiers get watchSet => ZcashWatchedNullifiers(
    sapling: saplingStore?.nullifiersToWatch ?? const [],
    orchard: orchardStore?.nullifiersToWatch ?? const [],
    ironwood: ironwoodStore?.nullifiersToWatch ?? const [],
  );

  Future<ZcashSyncOutcome> step() async {
    if (_stepping) {
      throw ZcashModelException(
        'this sync is already advancing a range. Two steps in flight over one '
        'cursor would scan the same range twice, or apply a scan the cursor '
        'has already moved past — the order broken in the one way an object '
        'cannot see afterwards.',
      );
    }
    _stepping = true;
    try {
      return await _step();
    } finally {
      _stepping = false;
    }
  }

  Future<ZcashSyncOutcome> _step() async {
    final tip = await chainTip();
    final start = _cursor.nextHeight;
    if (tip < start) {
      return ZcashSyncCaughtUp(chainHeight: tip);
    }
    final end = tip < start + rangeSize - 1 ? tip : start + rangeSize - 1;

    final source = await fetchRange(start, end);

    final ScanInputEnvelope envelope;
    final ZcashLightwalletdSyncCursor next;
    try {
      envelope = _cursor.scanInputFor(
        source,
        network: network,
        includeSaplingWitnesses: includeSaplingWitnesses,
        includeOrchardWitnesses: includeOrchardWitnesses,
        watchedNullifiers: watchSet,
      );
      next = _cursor.advance(
        scanned: source,
        treeState: await fetchTreeState(end),
      );
    } on ZcashChainReorgException catch (detection) {
      return ZcashSyncReorged(
        detection: detection,
        recovery: await ZcashReorgRecovery.find(
          trail: _cursor.trail,
          servedBlockHashAt: servedBlockHashAt,
        ),
      );
    }

    final result = await scan(envelope);
    final scanned = result.scannedHeightRange;
    if (scanned == null || scanned.start != start || scanned.end != end) {
      throw ZcashModelException(
        'this sync checked and requested heights $start-$end and the scan '
        'reports '
        '${scanned == null ? 'no range at all' : '${scanned.start}-${scanned.end}'}. '
        'Applying it would leave the stores claiming coverage of blocks that '
        'were never read and move the cursor past them.',
      );
    }

    final canonicalResult = _withCanonicalBlockHashes(result, source);

    saplingStore?.apply(
      canonicalResult,
      accountFingerprint: accountFingerprint,
    );
    orchardStore?.apply(
      canonicalResult,
      accountFingerprint: accountFingerprint,
    );
    ironwoodStore?.apply(
      canonicalResult,
      accountFingerprint: accountFingerprint,
    );

    _cursor = next;
    return ZcashSyncAdvanced(
      range: CompactBlockScanRange(start: start, end: end),
      scan: canonicalResult,
      cursor: next,
    );
  }

  ZcashScanResult _withCanonicalBlockHashes(
    ZcashScanResult result,
    ZcashLightwalletdScanSource source,
  ) {
    String hashAt(int height, String scannerHash) {
      final servedHash = source.blockHashAt(height);
      if (servedHash == null || servedHash.length != 64) {
        throw ZcashModelException(
          'the compact-block source did not provide a 32-byte canonical hash '
          'for a wallet event at height $height',
        );
      }
      if (scannerHash.isNotEmpty && scannerHash != servedHash) {
        throw ZcashModelException(
          'the scanner and compact-block source disagree on the canonical '
          'block at height $height',
        );
      }
      return servedHash;
    }

    return ZcashScanResult(
      scannedBlocks: result.scannedBlocks,
      discoveredNotes: result.discoveredNotes,
      totalValue: result.totalValue,
      notes: [
        for (final note in result.notes)
          ZcashScannedNote(
            height: note.height,
            tx: note.tx,
            output: note.output,
            value: note.value,
            pool: note.pool,
            nullifier: note.nullifier,
            commitmentPosition: note.commitmentPosition,
            isChange: note.isChange,
            witness: note.witness,
            recipient: note.recipient,
            rseed: note.rseed,
            rho: note.rho,
            noteVersion: note.noteVersion,
            blockHash: hashAt(note.height, note.blockHash ?? ''),
          ),
      ],
      spends: [
        for (final spend in result.spends)
          ZcashObservedSpend(
            height: spend.height,
            tx: spend.tx,
            pool: spend.pool,
            nullifier: spend.nullifier,
            index: spend.index,
            noteIndex: spend.noteIndex,
            blockHash: hashAt(spend.height, spend.blockHash ?? ''),
          ),
      ],
      scannedHeightRange: result.scannedHeightRange,
      orderedBlocks: result.orderedBlocks,
      diagnostics: result.diagnostics,
      orchardActions: result.orchardActions,
      saplingAnchor: result.saplingAnchor,
      orchardAnchor: result.orchardAnchor,
      ironwoodAnchor: result.ironwoodAnchor,
    );
  }

  Future<ZcashSyncOutcome> syncToTip({
    void Function(ZcashSyncAdvanced advanced)? onAdvanced,
  }) async {
    while (true) {
      final outcome = await step();
      if (outcome is! ZcashSyncAdvanced) return outcome;
      onAdvanced?.call(outcome);
    }
  }

  void resumeFrom({
    required ZcashReorgRecovery recovery,
    required TreeState treeState,
  }) {
    for (final entry in {
      'Sapling': saplingStore?.coveredThrough,
      'Orchard': orchardStore?.coveredThrough,
      'Ironwood': ironwoodStore?.coveredThrough,
    }.entries) {
      final through = entry.value;
      if (through == null || through <= recovery.forkHeight) continue;
      throw ZcashModelException(
        'the ${entry.key} store still covers through height $through and the '
        'chains parted after ${recovery.forkHeight}. Call '
        'rollbackTo(${recovery.forkHeight}) on it first: a reorg is not a '
        'spend, so nothing in a later scan removes the notes the abandoned '
        'chain paid, and resuming over them counts money that no longer exists '
        'beside the money that replaced it. This sync will not do it for you — '
        'a store is rolled back on instruction.',
      );
    }

    _cursor = ZcashLightwalletdSyncCursor.resumingAfterReorg(
      recovery: recovery,
      treeState: treeState,
      trail: _cursor.trail,
    );
  }
}
