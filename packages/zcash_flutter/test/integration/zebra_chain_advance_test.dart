@TestOn('vm')
library;

import 'dart:io';
import 'package:test/test.dart';
import 'harness.dart';

void main() {
  ZebraHarness? harness;

  setUpAll(() async {
    if (!Platform.environment.containsKey('ZEBRA_INTEGRATION')) return;
    harness = await ZebraHarness.start();
  });

  tearDownAll(() async {
    if (harness == null) return;
    await harness!.shutdown();
    harness = null;
  });

  group('Chain advancement', () {
    test(
      'confirmations of an earlier block grow as the tip advances',
      () async {
        if (harness == null) return;
        final hashes = await harness!.mineBlocks(1);
        final firstHash = hashes.single;
        final initial = await harness!.client.getBlock(firstHash);
        expect(initial.confirmations, equals(1));

        await harness!.mineBlocks(3);
        final later = await harness!.client.getBlock(firstHash);
        expect(later.confirmations, equals(4));
      },
    );

    test('mempool stays empty while only mining empty blocks', () async {
      if (harness == null) return;
      expect(await harness!.client.getRawMempool(), isEmpty);
      await harness!.mineBlocks(2);
      expect(await harness!.client.getRawMempool(), isEmpty);
    });

    test(
      'mined block contains exactly one transaction (its coinbase)',
      () async {
        if (harness == null) return;
        final hashes = await harness!.mineBlocks(1);
        final block = await harness!.client.getBlock(hashes.single);
        expect(block.transactions, hasLength(1));
        expect(block.transactions.single, hasLength(64));
        expect(block.transactions.single, matches(RegExp(r'^[0-9a-f]+$')));
      },
    );

    test('getBlockFull at a mined height exposes the coinbase txid', () async {
      if (harness == null) return;
      final hashes = await harness!.mineBlocks(1);
      final tipHeight = await harness!.client.getBlockCount();
      final full = await harness!.client.getBlockFull(tipHeight.toString());
      expect(full.hash, equals(hashes.single));
      expect(full.transactions, hasLength(1));
      final coinbase = full.transactions.single;
      expect(coinbase['txid'], isA<String>());
      expect(coinbase['txid'] as String, hasLength(64));
      final vin = coinbase['vin'] as List;
      expect(vin, hasLength(1));
    });

    test('getBlockHeader at the mined tip matches getblockhash', () async {
      if (harness == null) return;
      await harness!.mineBlocks(1);
      final tipHeight = await harness!.client.getBlockCount();
      final hashByHeight = await harness!.client.getBlockHash(tipHeight);
      final header = await harness!.client.getBlockHeader(tipHeight.toString());
      expect(header.hash, equals(hashByHeight));
      expect(header.height, equals(tipHeight));
      expect(header.confirmations, equals(1));
    });

    test(
      'getBlockSubsidy at a mined height returns a positive miner reward',
      () async {
        if (harness == null) return;
        await harness!.mineBlocks(1);
        final tipHeight = await harness!.client.getBlockCount();
        final subsidy = await harness!.client.getBlockSubsidy(
          height: tipHeight,
        );
        expect(subsidy.miner, greaterThan(0));
      },
    );
  });

  group('Reorg via invalidateblock/reconsiderblock', () {
    test('invalidateblock at a mined height rolls the tip back', () async {
      if (harness == null) return;
      final hashes = await harness!.mineBlocks(3);
      final tipBefore = await harness!.client.getBlockCount();
      final tipHashBefore = await harness!.client.getBestBlockHash();
      expect(tipHashBefore, equals(hashes.last));

      await harness!.client.invalidateBlock(hashes[1]);
      final rolledBack = await harness!.client.getBlockCount();
      expect(rolledBack, equals(tipBefore - 2));
      expect(await harness!.client.getBestBlockHash(), equals(hashes.first));

      await harness!.client.reconsiderBlock(hashes[1]);
      expect(await harness!.client.getBlockCount(), equals(tipBefore));
      expect(await harness!.client.getBestBlockHash(), equals(tipHashBefore));
    });
  });

  group('Coinbase address indexing', () {
    test(
      'miner balance grows by exactly the per-block subsidy each block',
      () async {
        if (harness == null) return;
        final balBefore = await harness!.client.getAddressBalance([
          kRegtestMinerAddress,
        ]);
        final tipBefore = await harness!.client.getBlockCount();
        await harness!.mineBlocks(2);

        final subsidy = await harness!.client.getBlockSubsidy(
          height: tipBefore + 1,
        );
        final balAfter = await harness!.client.getAddressBalance([
          kRegtestMinerAddress,
        ]);
        expect(
          balAfter.zatoshis - balBefore.zatoshis,
          equals(subsidy.miner * 2),
        );
      },
    );

    test(
      'each mined block adds one coinbase utxo and one txid for the miner',
      () async {
        if (harness == null) return;
        final utxosBefore = await harness!.client.getAddressUtxos([
          kRegtestMinerAddress,
        ]);
        final txidsBefore = await harness!.client.getAddressTxIds([
          kRegtestMinerAddress,
        ]);
        await harness!.mineBlocks(2);
        final utxosAfter = await harness!.client.getAddressUtxos([
          kRegtestMinerAddress,
        ]);
        final txidsAfter = await harness!.client.getAddressTxIds([
          kRegtestMinerAddress,
        ]);
        expect(utxosAfter.length - utxosBefore.length, equals(2));
        expect(txidsAfter.length - txidsBefore.length, equals(2));
      },
    );
  });
}
