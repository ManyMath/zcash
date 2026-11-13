import 'note_store.dart';
import 'scan.dart';
import 'spend.dart';
import 'transaction.dart';
import 'transparent_state.dart';

class ZcashHistoryEntry {
  const ZcashHistoryEntry({
    required this.protocolTxid,
    required this.height,
    required this.receivedZatoshis,
    required this.spentZatoshis,
    required this.pools,
    required this.unvaluedSpends,
    this.blockHash,
    this.timestamp,
    this.feeZatoshis,
  });

  final String protocolTxid;

  String get txid => reverseTxidByteOrder(protocolTxid);

  final int height;
  final int receivedZatoshis;
  final int spentZatoshis;

  final Set<String> pools;

  final int unvaluedSpends;

  final String? blockHash;

  final int? timestamp;

  final int? feeZatoshis;

  int get netZatoshis => receivedZatoshis - spentZatoshis;

  bool get isOutgoing => spentZatoshis > 0 || unvaluedSpends > 0;
}

/// The wallet's shielded transaction history, newest first.
class ZcashTransactionHistory {
  ZcashTransactionHistory._(this.entries);

  factory ZcashTransactionHistory.fromStores({
    SaplingNoteStore? sapling,
    OrchardNoteStore? orchard,
    IronwoodNoteStore? ironwood,
    ZcashTransparentState? transparent,
  }) {
    final notes = <ZcashScannedNote>[
      ...?sapling?.notes,
      ...?orchard?.notes,
      ...?ironwood?.notes,
    ];
    final spends = <ZcashObservedSpend>[
      ...?sapling?.spends,
      ...?orchard?.spends,
      ...?ironwood?.spends,
    ];

    // Pools' nullifiers are indistinguishable bytes, so join on the pool too.
    final byNullifier = <(String, String), ZcashScannedNote>{
      for (final note in notes)
        if (note.nullifier != null) (note.pool, note.nullifier!): note,
    };

    final builders = <String, _EntryBuilder>{};
    _EntryBuilder entry(String tx, int height) =>
        builders.putIfAbsent(tx, () => _EntryBuilder(tx, height));

    for (final note in notes) {
      entry(note.tx, note.height)
        ..received += note.value
        ..pools.add(note.pool)
        ..recordCanonicalBlock(height: note.height, blockHash: note.blockHash);
    }
    for (final spend in spends) {
      final consumed = byNullifier[(spend.pool, spend.nullifier)];
      final builder = entry(spend.tx, spend.height)..pools.add(spend.pool);
      builder.recordCanonicalBlock(
        height: spend.height,
        blockHash: spend.blockHash,
      );
      if (consumed == null) {
        builder.unvalued += 1;
      } else {
        builder.spent += consumed.value;
      }
    }
    final transparentOutputs =
        transparent?.outputs ?? const <ZcashTransparentOutput>[];
    for (final output in transparentOutputs) {
      entry(output.protocolTxid, output.minedHeight)
        ..received += output.valueZatoshis
        ..pools.add('transparent')
        ..recordCanonicalBlock(
          height: output.minedHeight,
          blockHash: output.blockHash,
        )
        ..recordMetadata(
          timestamp: output.blockTime,
          feeZatoshis: output.creationFeeZatoshis,
        );

      final spendingTxid = output.spendingProtocolTxid;
      final spentHeight = output.spentHeight;
      if (spendingTxid == null || spentHeight == null) continue;
      entry(spendingTxid, spentHeight)
        ..spent += output.valueZatoshis
        ..pools.add('transparent')
        ..recordCanonicalBlock(
          height: spentHeight,
          blockHash: output.spentBlockHash,
        )
        ..recordMetadata(
          timestamp: output.spentBlockTime,
          feeZatoshis: output.feeZatoshis,
        );
    }

    final entries = [for (final b in builders.values) b.build()]
      ..sort((a, b) {
        final byHeight = b.height.compareTo(a.height);
        return byHeight != 0
            ? byHeight
            : a.protocolTxid.compareTo(b.protocolTxid);
      });
    return ZcashTransactionHistory._(List.unmodifiable(entries));
  }

  final List<ZcashHistoryEntry> entries;
}

class _EntryBuilder {
  _EntryBuilder(this.tx, this.height);

  final String tx;
  final int height;
  var received = 0;
  var spent = 0;
  var unvalued = 0;
  final pools = <String>{};
  String? blockHash;
  int? timestamp;
  int? feeZatoshis;

  void recordCanonicalBlock({required int height, required String? blockHash}) {
    if (height != this.height) {
      throw ZcashModelException(
        'one transaction was recorded at two different block heights',
      );
    }
    final existing = this.blockHash;
    if (blockHash != null && existing != null && blockHash != existing) {
      throw ZcashModelException(
        'one transaction was recorded under two different canonical blocks',
      );
    }
    this.blockHash ??= blockHash;
  }

  void recordMetadata({required int? timestamp, required int? feeZatoshis}) {
    final existingTimestamp = this.timestamp;
    if (timestamp != null &&
        existingTimestamp != null &&
        timestamp != existingTimestamp) {
      throw ZcashModelException(
        'one transaction was recorded with two different block timestamps',
      );
    }
    final existingFee = this.feeZatoshis;
    if (feeZatoshis != null &&
        existingFee != null &&
        feeZatoshis != existingFee) {
      throw ZcashModelException(
        'one transaction was recorded with two different fees',
      );
    }
    this.timestamp ??= timestamp;
    this.feeZatoshis ??= feeZatoshis;
  }

  ZcashHistoryEntry build() => ZcashHistoryEntry(
    protocolTxid: tx,
    height: height,
    receivedZatoshis: received,
    spentZatoshis: spent,
    pools: Set.unmodifiable(pools),
    unvaluedSpends: unvalued,
    blockHash: blockHash,
    timestamp: timestamp,
    feeZatoshis: feeZatoshis,
  );
}
