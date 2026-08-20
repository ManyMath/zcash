import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

AddressUtxo _utxo({
  required int satoshis,
  required int height,
  String txid = 'aa',
  int vout = 0,
}) => AddressUtxo(
  address: 'tmExample',
  txid: txid * 32,
  outputIndex: vout,
  script: '76a914',
  satoshis: satoshis,
  height: height,
);

int _stubFee(List<TrackedTransparentCoin> coins) =>
    5000 * (coins.length < 2 ? 2 : coins.length);

TransparentCoinSet _coins({
  required List<AddressUtxo> utxos,
  required int chainHeight,
  Set<String> coinbase = const {},
}) => TransparentCoinSet.fromUtxos(
  utxos: utxos,
  chainHeight: chainHeight,
  coinbaseOutpoints: coinbase,
);

void main() {
  group('TransparentInputSelection.select', () {
    test('one coin covers the amount and leaves change', () {
      final selection = TransparentInputSelection.select(
        coins: _coins(
          utxos: [_utxo(satoshis: 100000, height: 10)],
          chainHeight: 500,
        ),
        amountZatoshis: 50000,
        feeForCoins: _stubFee,
      );

      expect(selection.coins, hasLength(1));
      expect(selection.feeZatoshis, 10000);
      expect(selection.changeZatoshis, 40000);
      expect(selection.spendsCoinbase, isFalse);
      expect(
        selection.inputZatoshis,
        selection.amountZatoshis +
            selection.feeZatoshis +
            selection.changeZatoshis,
        reason: 'the selection must balance or the build cannot',
      );
    });

    test('spending a coinbase coin with change left is refused', () {
      final coin = _utxo(satoshis: 100000, height: 10);
      expect(
        () => TransparentInputSelection.select(
          coins: _coins(
            utxos: [coin],
            chainHeight: 500,
            coinbase: {'${coin.txid}:0'},
          ),
          amountZatoshis: 50000,
          feeForCoins: _stubFee,
        ),
        throwsA(
          isA<TransparentSelectionException>()
              .having(
                (e) => e.refusal,
                'refusal',
                TransparentSelectionRefusal.coinbaseChange,
              )
              .having((e) => e.message, 'message', contains('Sweep')),
        ),
      );
    });

    test('a coinbase coin with no change left is allowed', () {
      final coin = _utxo(satoshis: 60000, height: 10);
      final selection = TransparentInputSelection.select(
        coins: _coins(
          utxos: [coin],
          chainHeight: 500,
          coinbase: {'${coin.txid}:0'},
        ),
        amountZatoshis: 50000,
        feeForCoins: _stubFee,
      );

      expect(selection.changeZatoshis, 0);
      expect(selection.spendsCoinbase, isTrue);
    });

    test('immature coins are a wait, not a shortfall', () {
      final coin = _utxo(satoshis: 900000, height: 400);
      expect(
        () => TransparentInputSelection.select(
          coins: _coins(
            utxos: [coin],
            chainHeight: 450,
            coinbase: {'${coin.txid}:0'},
          ),
          amountZatoshis: 50000,
          feeForCoins: _stubFee,
        ),
        throwsA(
          isA<TransparentSelectionException>()
              .having(
                (e) => e.refusal,
                'refusal',
                TransparentSelectionRefusal.immatureCoins,
              )
              .having((e) => e.spendableAtHeight, 'spendableAtHeight', 499),
        ),
      );
    });

    test('a genuine shortfall says so', () {
      expect(
        () => TransparentInputSelection.select(
          coins: _coins(
            utxos: [_utxo(satoshis: 1000, height: 10)],
            chainHeight: 500,
          ),
          amountZatoshis: 500000,
          feeForCoins: _stubFee,
        ),
        throwsA(
          isA<TransparentSelectionException>().having(
            (e) => e.refusal,
            'refusal',
            TransparentSelectionRefusal.insufficientFunds,
          ),
        ),
      );
    });

    test('the fee is re-quoted as coins are added', () {
      final quoted = <int>[];
      final selection = TransparentInputSelection.select(
        coins: _coins(
          utxos: [
            _utxo(satoshis: 30000, height: 10, txid: 'aa'),
            _utxo(satoshis: 30000, height: 10, txid: 'bb'),
            _utxo(satoshis: 30000, height: 10, txid: 'cc'),
          ],
          chainHeight: 500,
        ),
        amountZatoshis: 60000,
        feeForCoins: (coins) {
          quoted.add(coins.length);
          return _stubFee(coins);
        },
      );

      expect(quoted, [1, 2, 3]);
      expect(selection.coins, hasLength(3));
      expect(selection.feeZatoshis, 15000);
    });

    test('maxCoins bounds a selection that would not be relayable', () {
      expect(
        () => TransparentInputSelection.select(
          coins: _coins(
            utxos: [
              _utxo(satoshis: 30000, height: 10, txid: 'aa'),
              _utxo(satoshis: 30000, height: 10, txid: 'bb'),
              _utxo(satoshis: 30000, height: 10, txid: 'cc'),
            ],
            chainHeight: 500,
          ),
          amountZatoshis: 60000,
          feeForCoins: _stubFee,
          maxCoins: 2,
        ),
        throwsA(
          isA<TransparentSelectionException>().having(
            (e) => e.refusal,
            'refusal',
            TransparentSelectionRefusal.tooManyCoins,
          ),
        ),
      );
    });

    test('a non-positive amount is refused', () {
      for (final amount in [0, -1]) {
        expect(
          () => TransparentInputSelection.select(
            coins: _coins(
              utxos: [_utxo(satoshis: 100000, height: 10)],
              chainHeight: 500,
            ),
            amountZatoshis: amount,
            feeForCoins: _stubFee,
          ),
          throwsA(
            isA<TransparentSelectionException>().having(
              (e) => e.refusal,
              'refusal',
              TransparentSelectionRefusal.invalidAmount,
            ),
          ),
        );
      }
    });
  });

  group('TransparentInputSelection.sweep', () {
    test('takes every spendable coin and leaves no change', () {
      final coinbase = _utxo(satoshis: 625000000, height: 10, txid: 'aa');
      final ordinary = _utxo(satoshis: 100000, height: 10, txid: 'bb');
      final selection = TransparentInputSelection.sweep(
        coins: _coins(
          utxos: [coinbase, ordinary],
          chainHeight: 500,
          coinbase: {'${coinbase.txid}:0'},
        ),
        feeForCoins: _stubFee,
      );

      expect(selection.coins, hasLength(2));
      expect(selection.changeZatoshis, 0);
      expect(selection.spendsCoinbase, isTrue);
      expect(selection.feeZatoshis, 10000);
      expect(selection.amountZatoshis, 625000000 + 100000 - 10000);
      expect(
        selection.inputZatoshis,
        selection.amountZatoshis + selection.feeZatoshis,
      );
    });

    test('a sweep of coinbase coins is always permitted', () {
      final coinbase = _utxo(satoshis: 625000000, height: 10);
      final selection = TransparentInputSelection.sweep(
        coins: _coins(
          utxos: [coinbase],
          chainHeight: 500,
          coinbase: {'${coinbase.txid}:0'},
        ),
        feeForCoins: _stubFee,
      );

      expect(selection.spendsCoinbase, isTrue);
      expect(selection.changeZatoshis, 0);
    });

    test('immature coins are excluded, and reported as a wait', () {
      final coin = _utxo(satoshis: 900000, height: 400);
      expect(
        () => TransparentInputSelection.sweep(
          coins: _coins(
            utxos: [coin],
            chainHeight: 450,
            coinbase: {'${coin.txid}:0'},
          ),
          feeForCoins: _stubFee,
        ),
        throwsA(
          isA<TransparentSelectionException>()
              .having(
                (e) => e.refusal,
                'refusal',
                TransparentSelectionRefusal.immatureCoins,
              )
              .having((e) => e.spendableAtHeight, 'spendableAtHeight', 499),
        ),
      );
    });

    test('a balance that cannot cover its own fee is refused', () {
      expect(
        () => TransparentInputSelection.sweep(
          coins: _coins(
            utxos: [_utxo(satoshis: 5000, height: 10)],
            chainHeight: 500,
          ),
          feeForCoins: _stubFee,
        ),
        throwsA(
          isA<TransparentSelectionException>()
              .having(
                (e) => e.refusal,
                'refusal',
                TransparentSelectionRefusal.insufficientFunds,
              )
              .having((e) => e.message, 'message', contains('nothing left')),
        ),
      );
    });
  });
}
