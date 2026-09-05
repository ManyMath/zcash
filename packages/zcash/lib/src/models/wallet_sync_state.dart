import 'account_balance.dart';
import 'chain_sync.dart';
import 'lightwalletd_scan_source.dart';
import 'note_store.dart';
import 'scan.dart';
import 'spend.dart';
import 'transaction_history.dart';
import 'transparent_coins.dart';
import 'tree_state.dart';

class ZcashWalletSyncState {
  ZcashWalletSyncState({
    required ZcashLightwalletdSyncCursor cursor,
    required this.accountFingerprint,
    required this.sapling,
    required this.orchard,
    required this.ironwood,
  }) : _cursor = cursor {
    _checkPositions();
  }

  factory ZcashWalletSyncState.atBirthday({
    required ZcashLightwalletdSyncCursor cursor,
    required String accountFingerprint,
  }) => ZcashWalletSyncState(
    cursor: cursor,
    accountFingerprint: accountFingerprint,
    sapling: SaplingNoteStore(),
    orchard: OrchardNoteStore(),
    ironwood: IronwoodNoteStore(),
  );

  static const int version = 1;

  final String accountFingerprint;

  final SaplingNoteStore sapling;
  final OrchardNoteStore orchard;
  final IronwoodNoteStore ironwood;

  ZcashLightwalletdSyncCursor _cursor;
  ZcashChainSync? _sync;

  ZcashLightwalletdSyncCursor get cursor => _sync?.cursor ?? _cursor;

  ZcashAccountBalance balance({TransparentCoinSet? transparent}) =>
      ZcashAccountBalance.fromStores(
        sapling: sapling,
        orchard: orchard,
        ironwood: ironwood,
        transparent: transparent,
      );

  ZcashTransactionHistory history() => ZcashTransactionHistory.fromStores(
    sapling: sapling,
    orchard: orchard,
    ironwood: ironwood,
  );

  ZcashChainSync syncThrough({
    required Future<int> Function() chainTip,
    required Future<ZcashLightwalletdScanSource> Function(int start, int end)
    fetchRange,
    required Future<TreeState> Function(int height) fetchTreeState,
    required Future<ZcashScanResult> Function(ScanInputEnvelope envelope) scan,
    required Future<String?> Function(int height) servedBlockHashAt,
    String? network,
    bool includeSaplingWitnesses = false,
    bool includeOrchardWitnesses = false,
    int rangeSize = 100,
  }) {
    if (_sync != null) {
      throw ZcashModelException(
        'this wallet already has a sync. Two syncs over one set of stores '
        'would scan a range twice or apply one the other has moved past, and '
        'neither is visible afterwards — a note merged twice looks exactly '
        'like a note merged once. Keep the sync this returned; a reorg is '
        'resumed on it with resumeFrom rather than by making another.',
      );
    }
    return _sync = ZcashChainSync(
      cursor: _cursor,
      accountFingerprint: accountFingerprint,
      saplingStore: sapling,
      orchardStore: orchard,
      ironwoodStore: ironwood,
      chainTip: chainTip,
      fetchRange: fetchRange,
      fetchTreeState: fetchTreeState,
      scan: scan,
      servedBlockHashAt: servedBlockHashAt,
      network: network,
      includeSaplingWitnesses: includeSaplingWitnesses,
      includeOrchardWitnesses: includeOrchardWitnesses,
      rangeSize: rangeSize,
    );
  }

  Map<String, Object?> toJson() {
    _checkPositions();
    return {
      'wallet_sync_version': version,
      'account_fingerprint': accountFingerprint,
      'cursor': cursor.toJson(),
      'sapling': sapling.toJson(),
      'orchard': orchard.toJson(),
      'ironwood': ironwood.toJson(),
    };
  }

  factory ZcashWalletSyncState.fromJson(Map<String, Object?> json) {
    final documentVersion = json['wallet_sync_version'];
    if (documentVersion != version) {
      throw ZcashModelException(
        'wallet_sync_version ${documentVersion ?? '(absent)'} is not $version. '
        'A wallet restored from a schema this build only half understands '
        'answers a balance, and a balance is exactly the thing nobody '
        're-checks.',
      );
    }
    final fingerprint = json['account_fingerprint'];
    if (fingerprint is! String) {
      throw ZcashModelException(
        'a wallet document names the account it belongs to: without it the '
        'three stores have nothing to be checked against each other, and the '
        'next scan would set it from whichever account happened to be scanned.',
      );
    }
    return ZcashWalletSyncState(
      cursor: ZcashLightwalletdSyncCursor.fromJson(_object(json, 'cursor')),
      accountFingerprint: fingerprint,
      sapling: SaplingNoteStore.fromJson(_object(json, 'sapling')),
      orchard: OrchardNoteStore.fromJson(_object(json, 'orchard')),
      ironwood: IronwoodNoteStore.fromJson(_object(json, 'ironwood')),
    );
  }

  void _checkPositions() {
    final frontierHeight = cursor.nextHeight - 1;
    final covered = <String, int?>{
      'Sapling': sapling.coveredThrough,
      'Orchard': orchard.coveredThrough,
      'Ironwood': ironwood.coveredThrough,
    };
    final begun = <String, int?>{
      'Sapling': sapling.coveredFrom,
      'Orchard': orchard.coveredFrom,
      'Ironwood': ironwood.coveredFrom,
    };

    final positions = covered.values.toSet();
    if (positions.length > 1) {
      throw ZcashModelException(
        'these three stores have read the chain to different heights '
        '(${covered.entries.map((e) => '${e.key} ${e.value ?? 'nothing'}').join(', ')}). '
        'A sync applies every range to all three, whether or not the range held '
        'a note of that pool, so one wallet\'s stores share a position. A set '
        'that does not answers a balance which is a whole pool short of the '
        'chain, and says nothing about it until the pool that is behind refuses '
        'a scan. An empty store beside a covered one is the same problem and '
        'not a lesser one — that pool has never been read at all, which a '
        'rescan fixes and a restore does not.',
      );
    }

    if (begun.values.toSet().length > 1) {
      throw ZcashModelException(
        'these three stores begin at different heights '
        '(${begun.entries.map((e) => '${e.key} ${e.value ?? 'nothing'}').join(', ')}). '
        'They end together, so the one that begins latest has a range of chain '
        'below it that nobody read for that pool, and its balance is short by '
        'whatever was in it. Nothing later closes that: a store\'s coverage '
        'only refuses a gap it can see between its own two ends.',
      );
    }

    final through = positions.single;
    if (through != null && through != frontierHeight) {
      throw ZcashModelException(
        'these stores cover through height $through and this wallet\'s '
        'position was taken at height $frontierHeight. '
        '${through < frontierHeight ? 'The stores are behind the cursor: the next scan begins at ${cursor.nextHeight}, so blocks ${through + 1}-$frontierHeight would sit inside their coverage having been read by nobody, and every step from here refuses with a gap the loop cannot fetch — a cursor does not go backwards.' : 'The stores are ahead of the cursor: they hold notes from blocks this position never accepted, and nothing in a later scan removes them.'} '
        'The cursor and the stores were written down at different moments; '
        'restore the set that was written together, or rescan from the earlier '
        'position.',
      );
    }

    for (final entry in <String, String?>{
      'Sapling': sapling.accountFingerprint,
      'Orchard': orchard.accountFingerprint,
      'Ironwood': ironwood.accountFingerprint,
    }.entries) {
      final held = entry.value;
      if (held == null || held == accountFingerprint) continue;
      throw ZcashModelException(
        'the ${entry.key} store has been accumulating a different account than '
        'this wallet names',
      );
    }
  }
}

Map<String, Object?> _object(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is Map<String, Object?>) return value;
  if (value is Map) return value.cast<String, Object?>();
  throw ZcashModelException('"$field" must be an object');
}
