import 'transparent_coins.dart';

enum TransparentSelectionRefusal {
  insufficientFunds,

  immatureCoins,

  invalidAmount,

  invalidFee,

  coinbaseChange,

  tooManyCoins,
}

class TransparentSelectionException implements Exception {
  TransparentSelectionException(
    this.refusal,
    this.message, {
    this.spendableAtHeight,
  });

  final TransparentSelectionRefusal refusal;
  final String message;

  final int? spendableAtHeight;

  @override
  String toString() => 'TransparentSelectionException: $message';
}

class TransparentInputSelection {
  const TransparentInputSelection({
    required this.coins,
    required this.amountZatoshis,
    required this.feeZatoshis,
    required this.changeZatoshis,
    required this.spendsCoinbase,
  });

  final List<TrackedTransparentCoin> coins;

  final int amountZatoshis;

  final int feeZatoshis;

  final int changeZatoshis;

  final bool spendsCoinbase;

  int get inputZatoshis => coins.fold(0, (sum, coin) => sum + coin.satoshis);

  /// [feeForCoins] must come from the builder's ZIP 317 fee quote.
  static TransparentInputSelection select({
    required TransparentCoinSet coins,
    required int amountZatoshis,
    required int Function(List<TrackedTransparentCoin> spends) feeForCoins,
    int? maxCoins,
  }) {
    if (amountZatoshis <= 0) {
      throw TransparentSelectionException(
        TransparentSelectionRefusal.invalidAmount,
        'the amount must be positive',
      );
    }

    final candidates = [...coins.spendable]
      ..sort((a, b) => a.satoshis.compareTo(b.satoshis));

    final chosen = <TrackedTransparentCoin>[];
    var total = 0;
    for (final coin in candidates) {
      if (maxCoins != null && chosen.length >= maxCoins) {
        throw TransparentSelectionException(
          TransparentSelectionRefusal.tooManyCoins,
          'covering $amountZatoshis zatoshis would take more than $maxCoins '
          'coins; $total is the most $maxCoins of them hold',
        );
      }
      chosen.add(coin);
      total += coin.satoshis;
      final fee = feeForCoins(
        List<TrackedTransparentCoin>.unmodifiable(chosen),
      );
      if (fee < 0) {
        throw TransparentSelectionException(
          TransparentSelectionRefusal.invalidFee,
          'the fee quote returned a negative fee for ${chosen.length} coins',
        );
      }
      final required = amountZatoshis + fee;
      if (total >= required) {
        final change = total - required;
        final spendsCoinbase = TransparentCoinSet.requiresFullShielding(chosen);
        if (spendsCoinbase && change > 0) {
          throw TransparentSelectionException(
            TransparentSelectionRefusal.coinbaseChange,
            'this selection spends a coinbase output and would leave $change '
            'zatoshis of transparent change. A transaction spending a coinbase '
            'output may carry no transparent output at all, so the network '
            'would reject it. Sweep the whole balance into a shielded pool '
            'instead, or choose coins that are not coinbase outputs',
          );
        }
        return TransparentInputSelection(
          coins: List<TrackedTransparentCoin>.unmodifiable(chosen),
          amountZatoshis: amountZatoshis,
          feeZatoshis: fee,
          changeZatoshis: change,
          spendsCoinbase: spendsCoinbase,
        );
      }
    }

    _refuseShortfall(coins, total, amountZatoshis);
  }

  static TransparentInputSelection sweep({
    required TransparentCoinSet coins,
    required int Function(List<TrackedTransparentCoin> spends) feeForCoins,
  }) {
    final chosen = [...coins.spendable]
      ..sort((a, b) => a.satoshis.compareTo(b.satoshis));
    if (chosen.isEmpty) {
      _refuseShortfall(coins, 0, 1);
    }
    final total = chosen.fold(0, (sum, coin) => sum + coin.satoshis);
    final fee = feeForCoins(List<TrackedTransparentCoin>.unmodifiable(chosen));
    if (fee < 0) {
      throw TransparentSelectionException(
        TransparentSelectionRefusal.invalidFee,
        'the fee quote returned a negative fee for ${chosen.length} coins',
      );
    }
    if (total <= fee) {
      throw TransparentSelectionException(
        TransparentSelectionRefusal.insufficientFunds,
        'the spendable coins total $total zatoshis, which does not cover the '
        'fee of $fee; there would be nothing left to shield',
      );
    }
    return TransparentInputSelection(
      coins: List<TrackedTransparentCoin>.unmodifiable(chosen),
      amountZatoshis: total - fee,
      feeZatoshis: fee,
      changeZatoshis: 0,
      spendsCoinbase: TransparentCoinSet.requiresFullShielding(chosen),
    );
  }

  static Never _refuseShortfall(
    TransparentCoinSet coins,
    int total,
    int amountZatoshis,
  ) {
    final maturing = coins.maturingZatoshis;
    if (maturing > 0) {
      throw TransparentSelectionException(
        TransparentSelectionRefusal.immatureCoins,
        'the spendable coins total $total zatoshis and another $maturing is in '
        'coinbase outputs that have not matured. The soonest becomes spendable '
        'at height ${coins.nextMaturityHeight}, so this is a wait rather than '
        'an insufficient balance',
        spendableAtHeight: coins.nextMaturityHeight,
      );
    }
    throw TransparentSelectionException(
      TransparentSelectionRefusal.insufficientFunds,
      'the spendable transparent coins total $total zatoshis, which does not '
      'cover $amountZatoshis plus its fee',
    );
  }
}
