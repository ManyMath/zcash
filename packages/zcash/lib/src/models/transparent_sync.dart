import 'package:fixnum/fixnum.dart';

import '../lightwalletd_client.dart';
import 'address.dart';
import 'spend.dart';
import 'transparent_state.dart';

Future<ZcashTransparentRefresh> fetchTransparentRefresh({
  required ZcashTransparentState state,
  required Future<BlockID> Function() latestBlock,
  required Future<List<GetAddressUtxosReply>> Function(List<String> addresses)
  fetchUtxos,
  required Future<CompactBlock> Function(int height) fetchBlockAtHeight,
  required Future<List<CompactBlock>> Function(int start, int end) fetchRange,
  int maxRangeSize = 1000,
  int maxUtxos = 10000,
}) async {
  if (state.addresses.isEmpty) {
    throw const ZcashModelException(
      'transparent refresh requires at least one discovered receiver',
    );
  }
  if (maxRangeSize < 1) {
    throw ArgumentError.value(maxRangeSize, 'maxRangeSize', 'must be positive');
  }
  if (maxUtxos < 1) {
    throw ArgumentError.value(maxUtxos, 'maxUtxos', 'must be positive');
  }
  final tip = await latestBlock();
  if (!tip.hasHeight()) {
    throw const ZcashModelException(
      'lightwalletd latest block did not include a height',
    );
  }
  final chainHeight = tip.height.toInt();
  final replies = await fetchUtxos(state.addresses);
  if (replies.length > maxUtxos) {
    throw ZcashModelException(
      'transparent UTXO snapshot exceeds the configured limit of $maxUtxos',
    );
  }
  final blocks = <int, CompactBlock>{};

  void addBlock(CompactBlock block, {required int expectedHeight}) {
    final height = block.height.toInt();
    if (height != expectedHeight) {
      throw ZcashModelException(
        'lightwalletd returned compact block $height when height '
        '$expectedHeight was requested',
      );
    }
    final previous = blocks[height];
    if (previous != null && !_bytesEqual(previous.hash, block.hash)) {
      throw ZcashModelException(
        'lightwalletd returned two canonical hashes for height $height',
      );
    }
    blocks[height] = block;
  }

  final previousHeight = state.refreshedThroughHeight;
  if (previousHeight != null && chainHeight > previousHeight) {
    for (
      var start = previousHeight + 1;
      start <= chainHeight;
      start += maxRangeSize
    ) {
      final end = start + maxRangeSize - 1 < chainHeight
          ? start + maxRangeSize - 1
          : chainHeight;
      final range = await fetchRange(start, end);
      final byHeight = {for (final block in range) block.height.toInt(): block};
      for (var height = start; height <= end; height++) {
        final block = byHeight[height];
        if (block == null || byHeight.length != range.length) {
          throw ZcashModelException(
            'lightwalletd omitted or duplicated a compact block in '
            'transparent refresh range $start-$end',
          );
        }
        addBlock(block, expectedHeight: height);
      }
    }
  }

  final requiredHeights = <int>{
    chainHeight,
    ?previousHeight,
    for (final reply in replies) reply.height.toInt(),
  }.toList()..sort();
  for (final height in requiredHeights) {
    if (blocks.containsKey(height)) continue;
    addBlock(await fetchBlockAtHeight(height), expectedHeight: height);
  }

  return buildTransparentRefreshFromLightwalletd(
    network: state.network,
    accountFingerprint: state.accountFingerprint,
    queriedAddresses: state.addresses,
    chainHeight: chainHeight,
    blocks: [
      for (final height in (blocks.keys.toList()..sort())) blocks[height]!,
    ],
    replies: replies,
    trackedOutpoints: {for (final output in state.outputs) output.outpoint},
  );
}

Future<ZcashTransparentRefresh> fetchTransparentRefreshFromLightwalletd({
  required ZcashTransparentState state,
  required LightwalletdClient client,
  int maxRangeSize = 1000,
  int maxUtxos = 10000,
}) => fetchTransparentRefresh(
  state: state,
  latestBlock: client.getLatestBlock,
  fetchUtxos: (addresses) =>
      client.getAddressUtxos(addresses, maxEntries: maxUtxos + 1),
  fetchBlockAtHeight: (height) =>
      client.getBlock(BlockID()..height = Int64(height)),
  fetchRange: (start, end) => client
      .getBlockRangeByHeight(
        start,
        end,
        poolTypes: const [PoolType.TRANSPARENT],
      )
      .toList(),
  maxRangeSize: maxRangeSize,
  maxUtxos: maxUtxos,
);

Future<void> refreshTransparentStateFromLightwalletd({
  required ZcashTransparentState state,
  required LightwalletdClient client,
  int maxRangeSize = 1000,
  int maxUtxos = 10000,
}) async {
  final refresh = await fetchTransparentRefreshFromLightwalletd(
    state: state,
    client: client,
    maxRangeSize: maxRangeSize,
    maxUtxos: maxUtxos,
  );
  state.applyRefresh(refresh);
}

ZcashTransparentRefresh buildTransparentRefreshFromLightwalletd({
  required ZcashAddressNetwork network,
  required String accountFingerprint,
  required List<String> queriedAddresses,
  required int chainHeight,
  required List<CompactBlock> blocks,
  required List<GetAddressUtxosReply> replies,
  Set<String> trackedOutpoints = const {},
}) {
  final byHeight = <int, CompactBlock>{};
  final canonicalHashes = <int, String>{};
  for (final block in blocks) {
    final height = block.height.toInt();
    if (height < 0 || byHeight.containsKey(height)) {
      throw const ZcashModelException(
        'transparent refresh has duplicate or invalid compact-block heights',
      );
    }
    final hash = _hex32(block.hash, 'compact block hash');
    byHeight[height] = block;
    canonicalHashes[height] = hash;
  }
  final chainTipHash = canonicalHashes[chainHeight];
  if (chainTipHash == null) {
    throw const ZcashModelException(
      'transparent refresh compact blocks do not include the chain tip',
    );
  }

  final queried = queriedAddresses.toSet();
  final observations = <ZcashTransparentOutputObservation>[];
  final relevantOutpoints = <String>{...trackedOutpoints};
  for (final reply in replies) {
    if (!reply.hasAddress() ||
        !reply.hasTxid() ||
        !reply.hasScript() ||
        !queried.contains(reply.address)) {
      throw const ZcashModelException(
        'lightwalletd returned an incomplete or foreign transparent UTXO',
      );
    }
    final protocolTxid = _hex32(reply.txid, 'transparent UTXO txid');
    final height = reply.height.toInt();
    final block = byHeight[height];
    if (block == null) {
      throw ZcashModelException(
        'transparent UTXO at height $height has no canonical compact block',
      );
    }
    CompactTx? transaction;
    for (final candidate in block.vtx) {
      if (_bytesEqual(candidate.txid, reply.txid)) {
        transaction = candidate;
        break;
      }
    }
    if (transaction == null) {
      throw ZcashModelException(
        'transparent UTXO transaction $protocolTxid is absent from its '
        'canonical compact block; coinbase maturity cannot be determined',
      );
    }
    if (reply.index < 0 || reply.valueZat.isNegative) {
      throw const ZcashModelException(
        'lightwalletd returned a negative transparent UTXO field',
      );
    }
    if (transaction.vout.isNotEmpty) {
      if (reply.index >= transaction.vout.length) {
        throw const ZcashModelException(
          'lightwalletd UTXO index is outside its compact transaction outputs',
        );
      }
      final servedOutput = transaction.vout[reply.index];
      if (servedOutput.value != reply.valueZat ||
          !_bytesEqual(servedOutput.scriptPubKey, reply.script)) {
        throw const ZcashModelException(
          'lightwalletd UTXO disagrees with its compact transaction output',
        );
      }
    }
    final observation = ZcashTransparentOutputObservation(
      address: reply.address,
      protocolTxid: protocolTxid,
      outputIndex: reply.index,
      scriptHex: _hex(reply.script),
      valueZatoshis: reply.valueZat.toInt(),
      minedHeight: height,
      blockHash: canonicalHashes[height]!,
      blockTime: block.hasTime() && block.time > 0 ? block.time : null,
      creationFeeZatoshis: transaction.hasFee() ? transaction.fee : null,
      isCoinbase: transaction.index.toInt() == 0,
    );
    observations.add(observation);
    relevantOutpoints.add(observation.outpoint);
  }

  final spends = <ZcashTransparentSpendObservation>[];
  for (final block in blocks) {
    final height = block.height.toInt();
    final blockHash = canonicalHashes[height]!;
    for (final transaction in block.vtx) {
      if (transaction.vin.isEmpty) continue;
      final spendingTxid = _hex32(
        transaction.txid,
        'transparent spending txid',
      );
      for (final input in transaction.vin) {
        final outpoint =
            '${_hex32(input.prevoutTxid, 'transparent prevout txid')}:'
            '${input.prevoutIndex}';
        if (!relevantOutpoints.contains(outpoint)) continue;
        spends.add(
          ZcashTransparentSpendObservation(
            spentOutpoint: outpoint,
            spendingProtocolTxid: spendingTxid,
            spentHeight: height,
            blockHash: blockHash,
            blockTime: block.hasTime() && block.time > 0 ? block.time : null,
            feeZatoshis: transaction.hasFee() ? transaction.fee : null,
          ),
        );
      }
    }
  }

  return ZcashTransparentRefresh(
    network: network,
    accountFingerprint: accountFingerprint,
    queriedAddresses: queriedAddresses,
    chainHeight: chainHeight,
    chainTipHash: chainTipHash,
    canonicalBlockHashes: canonicalHashes,
    unspentOutputs: observations,
    observedSpends: spends,
  );
}

String _hex32(List<int> bytes, String field) {
  if (bytes.length != 32) {
    throw ZcashModelException('$field must contain 32 bytes');
  }
  return _hex(bytes);
}

String _hex(List<int> bytes) =>
    [for (final byte in bytes) byte.toRadixString(16).padLeft(2, '0')].join();

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
