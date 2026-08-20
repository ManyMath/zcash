import 'address.dart';

/// § 7.1.2: a coinbase output cannot be spent until 100 blocks later.
const int kCoinbaseMaturity = 100;

enum TransparentCoinStatus { spendable, immature }

class TrackedTransparentCoin {
  const TrackedTransparentCoin({
    required this.utxo,
    required this.isCoinbase,
    required this.status,
    required this.spendableAtHeight,
  });

  final AddressUtxo utxo;

  final bool isCoinbase;

  final TransparentCoinStatus status;

  final int spendableAtHeight;

  int get satoshis => utxo.satoshis;

  String get outpoint => '${utxo.txid}:${utxo.outputIndex}';
}

class TransparentCoinSet {
  const TransparentCoinSet._(
    this.tracked,
    this.chainHeight,
    this.unrecognisedCoinbaseOutpoints,
  );

  factory TransparentCoinSet.fromUtxos({
    required Iterable<AddressUtxo> utxos,
    required int chainHeight,
    required Set<String> coinbaseOutpoints,
  }) {
    final declared = {
      for (final outpoint in coinbaseOutpoints) outpoint.toLowerCase(),
    };
    final matched = <String>{};
    final tracked = <TrackedTransparentCoin>[];
    for (final utxo in utxos) {
      final outpoint = '${utxo.txid}:${utxo.outputIndex}'.toLowerCase();
      final isCoinbase = declared.contains(outpoint);
      if (isCoinbase) {
        matched.add(outpoint);
      }
      final spendableAt = isCoinbase
          ? utxo.height + kCoinbaseMaturity - 1
          : utxo.height;
      tracked.add(
        TrackedTransparentCoin(
          utxo: utxo,
          isCoinbase: isCoinbase,
          status: chainHeight >= spendableAt
              ? TransparentCoinStatus.spendable
              : TransparentCoinStatus.immature,
          spendableAtHeight: spendableAt,
        ),
      );
    }
    return TransparentCoinSet._(
      List<TrackedTransparentCoin>.unmodifiable(tracked),
      chainHeight,
      Set<String>.unmodifiable(declared.difference(matched)),
    );
  }

  final List<TrackedTransparentCoin> tracked;

  final int chainHeight;

  final Set<String> unrecognisedCoinbaseOutpoints;

  void requireRecognisedCoinbaseOutpoints() {
    if (unrecognisedCoinbaseOutpoints.isEmpty) {
      return;
    }
    throw ArgumentError(
      '${unrecognisedCoinbaseOutpoints.length} declared coinbase outpoint(s) '
      'name no coin in this set. If they were taken from a scan rather than '
      'from the node that reported these coins, the txids are byte-reversed: '
      'both encodings are 64 hex characters, so the join silently fails and '
      'every coinbase coin is treated as an ordinary one',
    );
  }

  List<TrackedTransparentCoin> get spendable => [
    for (final coin in tracked)
      if (coin.status == TransparentCoinStatus.spendable) coin,
  ];

  int get spendableZatoshis =>
      spendable.fold(0, (sum, coin) => sum + coin.satoshis);

  List<TrackedTransparentCoin> get immature => [
    for (final coin in tracked)
      if (coin.status == TransparentCoinStatus.immature) coin,
  ];

  int get maturingZatoshis =>
      immature.fold(0, (sum, coin) => sum + coin.satoshis);

  int get totalZatoshis => tracked.fold(0, (sum, coin) => sum + coin.satoshis);

  int? get nextMaturityHeight {
    final heights = [for (final coin in immature) coin.spendableAtHeight]
      ..sort();
    return heights.isEmpty ? null : heights.first;
  }

  /// Spending a coinbase output forbids any transparent output, change
  /// included (zcashd/zebrad consensus; see § 7.1.2): shield it all.
  static bool requiresFullShielding(Iterable<TrackedTransparentCoin> coins) =>
      coins.any((coin) => coin.isCoinbase);
}
