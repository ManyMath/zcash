import 'package:zcash/zcash.dart';

import 'address_utils.dart';
import 'native_result.dart';
import 'zcash_ffi_bindings.dart';

class ZcashSyncTimings {
  Duration tip = Duration.zero;
  Duration blocks = Duration.zero;
  Duration treeStates = Duration.zero;
  Duration scan = Duration.zero;
  int blockCount = 0;

  Future<T> _time<T>(
    Future<T> Function() body,
    void Function(Duration) add,
  ) async {
    final watch = Stopwatch()..start();
    try {
      return await body();
    } finally {
      add(watch.elapsed);
    }
  }

  @override
  String toString() {
    String s(Duration d) => (d.inMilliseconds / 1000).toStringAsFixed(1);
    return 'tip ${s(tip)} s, blocks ${s(blocks)} s, tree states '
        '${s(treeStates)} s, scan ${s(scan)} s over $blockCount blocks';
  }
}

ZcashChainSync openNativeLightwalletdSync({
  required LightwalletdClient client,
  required ZcashWalletSyncState wallet,
  required String ufvk,
  required ZcashNetwork network,
  Future<ZcashCommitmentTreeSizes> Function(int height)?
  nodeCommitmentTreeSizes,
  bool allowExperimentalOrchardNotes = false,
  int rangeSize = 100,
  ZcashFfiBindings? bindings,
  ZcashSyncTimings? timings,
}) {
  final clock = timings ?? ZcashSyncTimings();
  Future<ZcashLightwalletdScanSource> served(int start, int end) async =>
      ZcashLightwalletdScanSource(
        await client.getBlockRangeByHeight(start, end).toList(),
      );

  var knownTip = -1;
  int? lastEnd;
  List<int>? lastHash;
  _Lookahead? ahead;
  Future<TreeState>? aheadTreeState;
  int? aheadTreeStateHeight;

  return wallet.syncThrough(
    network: network.ffiLabel,
    rangeSize: rangeSize,
    chainTip: () => clock._time(() async {
      final tip = await client.getTipHeight();
      knownTip = tip;
      return tip;
    }, (d) => clock.tip += d),
    fetchRange: (start, end) async {
      final candidate = ahead;
      ahead = null;
      aheadTreeState = null;
      List<CompactBlock>? fromAhead;
      if (candidate != null &&
          candidate.start == start &&
          candidate.end == end &&
          lastEnd == start - 1) {
        final prefetched = await clock._time(
          () => candidate.blocks,
          (d) => clock.blocks += d,
        );
        if (prefetched.isNotEmpty &&
            lastHash != null &&
            _sameBytes(prefetched.first.prevHash, lastHash!)) {
          fromAhead = prefetched;
          aheadTreeState = candidate.treeState;
          aheadTreeStateHeight = end;
        }
      }
      final List<CompactBlock> blocks =
          fromAhead ??
          await clock._time<List<CompactBlock>>(
            () => client.getBlockRangeByHeight(start, end).toList(),
            (d) => clock.blocks += d,
          );
      clock.blockCount += end - start + 1;
      final source = ZcashLightwalletdScanSource(blocks);
      final second = nodeCommitmentTreeSizes;
      if (second != null) {
        source.requireParityWith(await second(end));
      }

      lastEnd = end;
      lastHash = blocks.isEmpty ? null : blocks.last.hash;
      final nextStart = end + 1;
      if (nextStart <= knownTip) {
        final nextEnd = end + rangeSize <= knownTip
            ? end + rangeSize
            : knownTip;
        final nextBlocks = client
            .getBlockRangeByHeight(nextStart, nextEnd)
            .toList();
        final nextTreeState = client
            .getTreeStateAtHeight(nextEnd)
            .then(treeStateFromLightwalletd);
        nextBlocks.ignore();
        nextTreeState.ignore();
        ahead = _Lookahead(nextStart, nextEnd, nextBlocks, nextTreeState);
      }
      return source;
    },
    fetchTreeState: (height) async {
      final prefetched = aheadTreeState;
      aheadTreeState = null;
      if (prefetched != null && aheadTreeStateHeight == height) {
        return clock._time(() => prefetched, (d) => clock.treeStates += d);
      }
      return treeStateFromLightwalletd(
        await clock._time(
          () => client.getTreeStateAtHeight(height),
          (d) => clock.treeStates += d,
        ),
      );
    },
    servedBlockHashAt: (height) async {
      try {
        return (await served(height, height)).lastBlockHash;
      } on Object {
        return null;
      }
    },
    scan: (envelope) => clock._time(() async {
      final ffi = bindings ?? ZcashFfiBindings.instance;
      const context = 'scan_compact_blocks/lightwalletd_sync';
      return ZcashScanResult.fromJson(
        parseNativeJsonObject(
          ffi.scanCompactBlocksRaw(ufvk, network.ffiLabel, envelope.encode()),
          context: context,
          redactSensitive: [ufvk],
        ),
        context: context,
        redactSensitive: [ufvk],
        allowExperimentalOrchardNotes: allowExperimentalOrchardNotes,
      );
    }, (d) => clock.scan += d),
  );
}

class _Lookahead {
  _Lookahead(this.start, this.end, this.blocks, this.treeState);

  final int start;
  final int end;
  final Future<List<CompactBlock>> blocks;
  final Future<TreeState> treeState;
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
