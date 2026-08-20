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

void main() {
  group('TransparentCoinSet', () {
    test('an ordinary coin is spendable as soon as it is mined', () {
      final set = TransparentCoinSet.fromUtxos(
        utxos: [_utxo(satoshis: 100000, height: 200)],
        chainHeight: 200,
        coinbaseOutpoints: const {},
      );

      expect(set.spendable, hasLength(1));
      expect(set.spendableZatoshis, 100000);
      expect(set.maturingZatoshis, 0);
      expect(set.nextMaturityHeight, isNull);
      expect(set.tracked.single.isCoinbase, isFalse);
    });

    test('a coinbase coin waits a hundred blocks, and says how long', () {
      final coinbase = _utxo(satoshis: 625000000, height: 200);
      final outpoint = '${coinbase.txid}:0';

      final early = TransparentCoinSet.fromUtxos(
        utxos: [coinbase],
        chainHeight: 298,
        coinbaseOutpoints: {outpoint},
      );
      expect(early.spendable, isEmpty);
      expect(early.spendableZatoshis, 0);
      expect(
        early.maturingZatoshis,
        625000000,
        reason: '"wait until block 299" is an answer; "no funds" is not',
      );
      expect(early.nextMaturityHeight, 299);
      expect(early.totalZatoshis, 625000000);

      final ready = TransparentCoinSet.fromUtxos(
        utxos: [coinbase],
        chainHeight: 299,
        coinbaseOutpoints: {outpoint},
      );
      expect(ready.spendable, hasLength(1));
      expect(ready.tracked.single.spendableAtHeight, 299);
      expect(ready.nextMaturityHeight, isNull);
    });

    test('the coinbase flag is per outpoint, not per transaction', () {
      final coins = [
        _utxo(satoshis: 100, height: 10, vout: 0),
        _utxo(satoshis: 200, height: 10, vout: 1),
      ];
      final set = TransparentCoinSet.fromUtxos(
        utxos: coins,
        chainHeight: 20,
        coinbaseOutpoints: {'${coins.first.txid}:0'},
      );

      expect(set.tracked.first.isCoinbase, isTrue);
      expect(set.tracked.first.status, TransparentCoinStatus.immature);
      expect(set.tracked.last.isCoinbase, isFalse);
      expect(set.tracked.last.status, TransparentCoinStatus.spendable);
      expect(set.spendableZatoshis, 200);
    });

    test(
      'spending any coinbase coin forces the whole transaction to shield',
      () {
        final coins = [
          _utxo(satoshis: 100, height: 10, txid: 'aa'),
          _utxo(satoshis: 200, height: 10, txid: 'bb'),
        ];
        final set = TransparentCoinSet.fromUtxos(
          utxos: coins,
          chainHeight: 500,
          coinbaseOutpoints: {'${coins.first.txid}:0'},
        );

        expect(TransparentCoinSet.requiresFullShielding(set.tracked), isTrue);
        expect(
          TransparentCoinSet.requiresFullShielding([set.tracked.last]),
          isFalse,
          reason: 'the ordinary coin on its own may leave change',
        );
        expect(TransparentCoinSet.requiresFullShielding(const []), isFalse);
      },
    );

    test('a scan-order txid does not silently mean "not a coinbase"', () {
      final coin = AddressUtxo(
        address: 'tmExample',
        txid:
            '00112233445566778899aabbccddeeff'
            '00112233445566778899aabbccddeeff',
        outputIndex: 0,
        script: '76a914',
        satoshis: 625000000,
        height: 10,
      );
      final reversed = reverseTxidByteOrder(coin.txid);
      expect(reversed, isNot(coin.txid));

      final set = TransparentCoinSet.fromUtxos(
        utxos: [coin],
        chainHeight: 500,
        coinbaseOutpoints: {'$reversed:0'},
      );

      expect(
        set.tracked.single.isCoinbase,
        isFalse,
        reason: 'the join genuinely did not match — that is the hazard',
      );
      expect(set.unrecognisedCoinbaseOutpoints, {'$reversed:0'});
      expect(
        set.requireRecognisedCoinbaseOutpoints,
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            contains('byte-reversed'),
          ),
        ),
      );
    });

    test('a matching outpoint leaves nothing unrecognised', () {
      final coin = _utxo(satoshis: 100, height: 10);
      final set = TransparentCoinSet.fromUtxos(
        utxos: [coin],
        chainHeight: 500,
        coinbaseOutpoints: {'${coin.txid}:0'},
      );

      expect(set.tracked.single.isCoinbase, isTrue);
      expect(set.unrecognisedCoinbaseOutpoints, isEmpty);
      expect(set.requireRecognisedCoinbaseOutpoints, returnsNormally);
    });

    test('outpoint case does not decide a consensus rule', () {
      final coin = _utxo(satoshis: 100, height: 10);
      final set = TransparentCoinSet.fromUtxos(
        utxos: [coin],
        chainHeight: 500,
        coinbaseOutpoints: {'${coin.txid.toUpperCase()}:0'},
      );

      expect(set.tracked.single.isCoinbase, isTrue);
      expect(set.unrecognisedCoinbaseOutpoints, isEmpty);
    });

    test('an empty wallet is zero everywhere', () {
      final set = TransparentCoinSet.fromUtxos(
        utxos: const [],
        chainHeight: 500,
        coinbaseOutpoints: const {},
      );

      expect(set.totalZatoshis, 0);
      expect(set.spendableZatoshis, 0);
      expect(set.maturingZatoshis, 0);
      expect(set.nextMaturityHeight, isNull);
    });

    test('the next maturity is the soonest, not the first reported', () {
      final far = _utxo(satoshis: 1, height: 400, txid: 'aa');
      final near = _utxo(satoshis: 2, height: 300, txid: 'bb');
      final set = TransparentCoinSet.fromUtxos(
        utxos: [far, near],
        chainHeight: 350,
        coinbaseOutpoints: {'${far.txid}:0', '${near.txid}:0'},
      );

      expect(set.immature, hasLength(2));
      expect(set.nextMaturityHeight, 399);
    });
  });
}
