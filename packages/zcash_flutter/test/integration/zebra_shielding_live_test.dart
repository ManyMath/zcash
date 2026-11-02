@TestOn('vm')
library;

import 'dart:io';
import 'package:test/test.dart';
import 'package:zcash_flutter/zcash_flutter.dart';
import 'harness.dart';

// Needs an Ironwood-aware ZEBRA_BIN and a ZCASH_FFI_LIB with ironwood-tx-build.
void main() {
  // The height-1 coinbase matures at 101; NU6.3 is staged at 130.
  const nu63Activation = 130;
  const maturityHeight = 101;

  final ffiLib = Platform.environment['ZCASH_FFI_LIB'] ?? '';
  final enabled =
      Platform.environment.containsKey('ZEBRA_INTEGRATION') &&
      ffiLib.isNotEmpty;

  ZebraHarness? harness;
  ZcashFfiBindings? ffi;

  setUpAll(() async {
    if (!enabled) return;
    ffi = ZcashFfiBindings.open(ffiLib);
    harness = await ZebraHarness.start(
      nu63ActivationHeight: nu63Activation,
      minerAddress: kIronwoodProofMinerAddress,
    );
    await harness!.mineBlocks(maturityHeight);
    await _mineTo(harness!, nu63Activation + 2);
  });

  tearDownAll(() async {
    if (harness == null) return;
    await harness!.shutdown();
    harness = null;
  });

  Future<TransparentCoinSet> coinsAtTip() async {
    final tip = await harness!.client.getBlockCount();
    final utxos = await harness!.client.getAddressUtxos([
      kIronwoodProofMinerAddress,
    ]);
    return TransparentCoinSet.fromUtxos(
      utxos: utxos,
      chainHeight: tip,
      coinbaseOutpoints: {
        for (final utxo in utxos) '${utxo.txid}:${utxo.outputIndex}',
      },
    );
  }

  group('Live transparent shielding', () {
    test('the maturity boundary is where the node says it is', () async {
      if (harness == null) return;

      final coins = await coinsAtTip();
      expect(coins.tracked, isNotEmpty);
      final youngest = coins.tracked.reduce(
        (a, b) => a.utxo.height >= b.utxo.height ? a : b,
      );
      expect(
        youngest.spendableAtHeight,
        youngest.utxo.height + 99,
        reason:
            'a coin from height H is first spendable in a block at H + 100, '
            'and a transaction built while the chain is at h is mined at h + 1',
      );
      expect(
        TransparentCoinSet.fromUtxos(
          utxos: [youngest.utxo],
          chainHeight: youngest.spendableAtHeight,
          coinbaseOutpoints: {youngest.outpoint},
        ).spendable,
        hasLength(1),
        reason: 'at exactly that height the node would accept the spend',
      );
      expect(
        TransparentCoinSet.fromUtxos(
          utxos: [youngest.utxo],
          chainHeight: youngest.spendableAtHeight - 1,
          coinbaseOutpoints: {youngest.outpoint},
        ).spendable,
        isEmpty,
        reason: 'one block earlier the node would reject the spend',
      );
    });

    test('a sweep shields every mature coin, and is mined', () async {
      if (harness == null) return;

      final tip = await harness!.client.getBlockCount();
      final coins = await coinsAtTip();
      expect(coins.spendableZatoshis, greaterThan(0));
      expect(
        coins.maturingZatoshis,
        greaterThan(0),
        reason:
            'the last hundred blocks paid coinbases that have not matured; a '
            'sweep must leave them alone rather than fail',
      );

      final treeState = await harness!.client.getTreeState('$tip');
      final prepared = prepareNativeShieldingSend(
        network: ZcashNetwork.regtest,
        destination: ShieldingDestination.ironwood,
        coins: coins,
        toAddress: kIronwoodProofUnifiedAddress,
        targetHeight: tip + 1,
        signingKeyForCoin: (coin) => kIronwoodProofMinerSecretKeyHex,
        ironwoodAnchor: IronwoodAnchorSource.tree(
          treeState.ironwood?.finalState ?? '',
        ),
        regtestNu63ActivationHeight: nu63Activation,
        allowExperimentalBuild: true,
        bindings: ffi,
      );

      expect(prepared.spendsCoinbase, isTrue);
      expect(
        prepared.selection.changeZatoshis,
        0,
        reason:
            'a transaction spending a coinbase output may carry no transparent '
            'output at all, and a sweep is the shape that needs none',
      );
      expect(
        prepared.shieldedZatoshis,
        prepared.selection.inputZatoshis - prepared.feeZatoshis,
      );
      expect(
        prepared.selection.coins.length,
        coins.spendable.length,
        reason: 'a sweep takes every mature coin and no immature one',
      );

      final txid = await harness!.client.sendRawTransaction(
        prepared.transactionHex,
      );
      expect(txid, prepared.txid);

      final hash = (await harness!.mineBlocks(1)).single;
      expect(
        (await harness!.client.getBlock(hash)).transactions,
        contains(txid),
        reason:
            'a mined balance swept into Ironwood in one call, accepted by a '
            'real node',
      );
    });

    test(
      'a partial shield of coinbase funds is refused before it is built',
      () async {
        if (harness == null) return;

        final coins = await coinsAtTip();
        expect(coins.spendable, isNotEmpty);
        final tip = await harness!.client.getBlockCount();
        final treeState = await harness!.client.getTreeState('$tip');

        expect(
          () => prepareNativeShieldingSend(
            network: ZcashNetwork.regtest,
            destination: ShieldingDestination.ironwood,
            coins: coins,
            toAddress: kIronwoodProofUnifiedAddress,
            amountZatoshis: 100000,
            targetHeight: tip + 1,
            signingKeyForCoin: (coin) => kIronwoodProofMinerSecretKeyHex,
            ironwoodAnchor: IronwoodAnchorSource.tree(
              treeState.ironwood?.finalState ?? '',
            ),
            regtestNu63ActivationHeight: nu63Activation,
            allowExperimentalBuild: true,
            bindings: ffi,
          ),
          throwsA(
            isA<TransparentSelectionException>().having(
              (e) => e.refusal,
              'refusal',
              TransparentSelectionRefusal.coinbaseChange,
            ),
          ),
        );
      },
    );

    test(
      'the network does not catch this one, so the refusal has to be local',
      () async {
        if (harness == null) return;

        // § 7.1.2 forbids a transparent output here, yet zebrad 6.2.2 on
        // regtest accepts and mines this transaction.
        final coins = await coinsAtTip();
        final coin = coins.spendable.first;
        final tip = await harness!.client.getBlockCount();
        final treeState = await harness!.client.getTreeState('$tip');

        final built = buildNativeIronwoodTransaction(
          network: ZcashNetwork.regtest,
          targetHeight: tip + 1,
          regtestNu63ActivationHeight: nu63Activation,
          anchor: IronwoodAnchorSource.tree(
            treeState.ironwood?.finalState ?? '',
          ),
          inputs: [
            TransparentBuildInput(
              txid: coin.utxo.txid,
              vout: coin.utxo.outputIndex,
              valueZatoshis: coin.satoshis,
              secretKeyHex: kIronwoodProofMinerSecretKeyHex,
            ),
          ],
          outputs: [
            TransparentBuildOutput(
              address: kIronwoodProofMinerAddress,
              valueZatoshis: 100000,
            ),
          ],
          ironwoodOutput: const IronwoodBuildOutput(
            address: kIronwoodProofUnifiedAddress,
          ),
          allowExperimentalIronwoodBuild: true,
          bindings: ffi,
        );

        expect(
          built.vout,
          1,
          reason:
              'the transparent output that is supposed to make this illegal',
        );
        expect(built.isConsensusValid, isTrue);
        final sourceBlock = await harness!.client.getBlock(
          '${coin.utxo.height}',
        );
        expect(sourceBlock.transactions.first, coin.utxo.txid);
        expect(sourceBlock.transactions, hasLength(1));

        final txid = await harness!.client.sendRawTransaction(
          built.transactionHex,
        );
        final hash = (await harness!.mineBlocks(1)).single;
        expect(
          (await harness!.client.getBlock(hash)).transactions,
          contains(txid),
          reason:
              'observed, not endorsed: zebrad 6.2.2 mined a transaction that '
              '§ 7.1.2 forbids. A wallet that leaves this rule to the node is '
              'trusting a check that was not performed',
        );
      },
    );
  }, skip: enabled ? false : 'needs ZEBRA_INTEGRATION and ZCASH_FFI_LIB');
}

Future<void> _mineTo(ZebraHarness harness, int height) async {
  final current = await harness.client.getBlockCount();
  if (current >= height) return;
  await harness.mineBlocks(height - current);
}
