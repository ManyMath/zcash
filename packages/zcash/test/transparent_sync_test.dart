import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

List<int> _bytes(int value) => List<int>.filled(32, value);

void main() {
  test('joins a lightwalletd UTXO to its canonical coinbase transaction', () {
    final transaction = CompactTx()
      ..index = Int64.ZERO
      ..txid = _bytes(0x11)
      ..vout.add(
        TxOut()
          ..value = Int64(125000)
          ..scriptPubKey = [0x51],
      );
    final block = CompactBlock()
      ..height = Int64(90)
      ..hash = _bytes(0x33)
      ..time = 1700000000
      ..vtx.add(transaction);
    final reply = GetAddressUtxosReply()
      ..address = 'tmDefaultAccountAddress'
      ..txid = _bytes(0x11)
      ..index = 0
      ..script = [0x51]
      ..valueZat = Int64(125000)
      ..height = Int64(90);

    final refresh = buildTransparentRefreshFromLightwalletd(
      network: ZcashAddressNetwork.regtest,
      accountFingerprint: 'account-fingerprint',
      queriedAddresses: const ['tmDefaultAccountAddress'],
      chainHeight: 90,
      blocks: [block],
      replies: [reply],
    );

    expect(refresh.chainTipHash, '33' * 32);
    expect(refresh.canonicalBlockHashes, {90: '33' * 32});
    expect(refresh.unspentOutputs, hasLength(1));
    final output = refresh.unspentOutputs.single;
    expect(output.protocolTxid, '11' * 32);
    expect(output.outputIndex, 0);
    expect(output.scriptHex, '51');
    expect(output.valueZatoshis, 125000);
    expect(output.blockTime, 1700000000);
    expect(output.isCoinbase, isTrue);
  });

  test(
    'fetches a complete account snapshot through bounded adapter seams',
    () async {
      final account = ZcashAccountMetadata(
        network: ZcashAddressNetwork.regtest,
        accountIndex: 0,
        ufvk: 'uview-regtest',
        transparentAccountXpub: 'xpub',
        receivers: const ZcashAccountReceiverSet(
          orchard: true,
          sapling: true,
          transparent: true,
          p2pkh: true,
          p2sh: false,
          unknown: 0,
          total: 3,
        ),
        receiverKinds: const [],
      );
      final state = ZcashTransparentState.fromAccount(
        account: account,
        viewingKeys: const ZcashViewingKeys(
          network: ZcashAddressNetwork.regtest,
          accountIndex: 0,
          transparent: ZcashTransparentViewingKeys(
            available: true,
            defaultExternalAddress: 'tmDefaultAccountAddress',
            defaultExternalIndex: 0,
          ),
          sapling: ZcashSaplingViewingKey(available: true),
          orchard: ZcashOrchardViewingKey(available: true),
        ),
      );
      final transaction = CompactTx()
        ..index = Int64.ONE
        ..txid = _bytes(0x11);
      final block = CompactBlock()
        ..height = Int64(90)
        ..hash = _bytes(0x33)
        ..vtx.add(transaction);
      final reply = GetAddressUtxosReply()
        ..address = 'tmDefaultAccountAddress'
        ..txid = _bytes(0x11)
        ..index = 0
        ..script = [0x51]
        ..valueZat = Int64(125000)
        ..height = Int64(90);
      final requestedHeights = <int>[];

      final refresh = await fetchTransparentRefresh(
        state: state,
        latestBlock: () async => BlockID()..height = Int64(90),
        fetchUtxos: (addresses) async {
          expect(addresses, ['tmDefaultAccountAddress']);
          return [reply];
        },
        fetchBlockAtHeight: (height) async {
          requestedHeights.add(height);
          return block;
        },
        fetchRange: (start, end) async => throw StateError(
          'an initial snapshot only needs blocks containing current outputs',
        ),
      );

      expect(requestedHeights, [90]);
      expect(refresh.unspentOutputs.single.isCoinbase, isFalse);
      state.applyRefresh(refresh);
      expect(state.coinSet.spendableZatoshis, 125000);
    },
  );

  test('extracts exact spend metadata and preserves unknown fields', () {
    final spending = CompactTx()
      ..index = Int64.ONE
      ..txid = _bytes(0x66)
      ..vin.add(
        CompactTxIn()
          ..prevoutTxid = _bytes(0x11)
          ..prevoutIndex = 2,
      );
    final block = CompactBlock()
      ..height = Int64(101)
      ..hash = _bytes(0x55)
      ..vtx.add(spending);

    final refresh = buildTransparentRefreshFromLightwalletd(
      network: ZcashAddressNetwork.regtest,
      accountFingerprint: 'account-fingerprint',
      queriedAddresses: const ['tmDefaultAccountAddress'],
      chainHeight: 101,
      blocks: [block],
      replies: const [],
      trackedOutpoints: {'${'11' * 32}:2'},
    );

    expect(refresh.observedSpends, hasLength(1));
    final spend = refresh.observedSpends.single;
    expect(spend.spentOutpoint, '${'11' * 32}:2');
    expect(spend.spendingProtocolTxid, '66' * 32);
    expect(spend.spentHeight, 101);
    expect(spend.blockHash, '55' * 32);
    expect(spend.blockTime, isNull);
    expect(spend.feeZatoshis, isNull);
  });
}
