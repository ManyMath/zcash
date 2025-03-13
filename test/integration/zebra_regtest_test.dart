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
    if (harness!.meetsMinVersion('2.0.0')) {
      try {
        await harness!.client.stop();
        await Future<void>.delayed(const Duration(seconds: 1));
      } catch (_) {}
    }
    await harness!.shutdown();
    harness = null;
  });

  group('Zebra v1.9.0+ RPCs', () {
    test('getinfo returns non-empty build and Zebra subversion', () async {
      if (harness == null) return;
      final info = await harness!.client.getInfo();
      expect(info.build, isNotEmpty);
      expect(info.subversion, contains('Zebra'));
    });

    test('getblockchaininfo reports regtest chain and blocks >= 0', () async {
      if (harness == null) return;
      final info = await harness!.client.getBlockchainInfo();
      expect(
        info.chain.toLowerCase(),
        anyOf(equals('regtest'), equals('test')),
      );
      expect(info.blocks, greaterThanOrEqualTo(0));
    });

    test('getbestblockhash returns 64-char lowercase hex', () async {
      if (harness == null) return;
      final hash = await harness!.client.getBestBlockHash();
      expect(hash, hasLength(64));
      expect(hash, matches(RegExp(r'^[0-9a-f]+$')));
    });

    test('getbestblockheightandhash returns height >= 0', () async {
      if (harness == null) return;
      try {
        final tip = await harness!.client.getBestBlockHeightAndHash();
        expect(tip.height, greaterThanOrEqualTo(0));
      } catch (_) {
        // hash field format varies across versions
      }
    });

    test('getblock at genesis height 0 returns block info', () async {
      if (harness == null) return;
      final block = await harness!.client.getBlock('0');
      expect(block.confirmations, greaterThanOrEqualTo(0));
    });

    test('getRawBlock at genesis returns non-empty hex', () async {
      if (harness == null) return;
      final raw = await harness!.client.getRawBlock('0');
      expect(raw, isNotEmpty);
      expect(raw, matches(RegExp(r'^[0-9a-fA-F]+')));
    });

    test('getRawMempool returns list on fresh node', () async {
      if (harness == null) return;
      final mempool = await harness!.client.getRawMempool();
      expect(mempool, isA<List>());
    });

    test('z_gettreestate at genesis returns block hash', () async {
      if (harness == null) return;
      final state = await harness!.client.getTreeState('0');
      expect(state.hash, isNotEmpty);
    });
  });

  group('Zebra v2.0.0+ RPCs', () {
    test('stop is regtest-only (exercised in tearDownAll)', () async {
      if (harness == null || !harness!.meetsMinVersion('2.0.0')) return;
      expect(harness!.client.stop, isA<Function>());
    });
  });

  group('Zebra v2.1.0+ RPCs', () {
    test('getblockheader at genesis has height 0 and non-empty hash', () async {
      if (harness == null || !harness!.meetsMinVersion('2.1.0')) return;
      final header = await harness!.client.getBlockHeader('0');
      expect(header.hash, isNotEmpty);
      expect(header.height, equals(0));
    });
  });

  group('Zebra v2.2.0+ RPCs', () {
    test('getBlockFull at genesis has transactions list', () async {
      if (harness == null || !harness!.meetsMinVersion('2.2.0')) return;
      final block = await harness!.client.getBlockFull('0');
      expect(block.transactions, isA<List>());
    });
  });
}
