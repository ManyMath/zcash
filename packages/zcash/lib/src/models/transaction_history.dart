import 'note_store.dart';
import 'scan.dart';
import 'transaction.dart';

class ZcashHistoryEntry {
  const ZcashHistoryEntry({
    required this.protocolTxid,
    required this.height,
    required this.receivedZatoshis,
    required this.spentZatoshis,
    required this.pools,
    required this.unvaluedSpends,
  });

  final String protocolTxid;

  String get txid => reverseTxidByteOrder(protocolTxid);

  final int height;
  final int receivedZatoshis;
  final int spentZatoshis;

  final Set<String> pools;

  final int unvaluedSpends;

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
        ..pools.add(note.pool);
    }
    for (final spend in spends) {
      final consumed = byNullifier[(spend.pool, spend.nullifier)];
      final builder = entry(spend.tx, spend.height)..pools.add(spend.pool);
      if (consumed == null) {
        builder.unvalued += 1;
      } else {
        builder.spent += consumed.value;
      }
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

  ZcashHistoryEntry build() => ZcashHistoryEntry(
    protocolTxid: tx,
    height: height,
    receivedZatoshis: received,
    spentZatoshis: spent,
    pools: Set.unmodifiable(pools),
    unvaluedSpends: unvalued,
  );
}
