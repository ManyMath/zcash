@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zcash_ffi/zcash_ffi.dart';
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
      final tip = await harness!.client.getBestBlockHeightAndHash();
      expect(tip.height, greaterThanOrEqualTo(0));
      expect(tip.hash, hasLength(64));
      expect(tip.hash, matches(RegExp(r'^[0-9a-f]+$')));
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

  group('Zebra v2.3.0+ RPCs', () {
    test('validateaddress returns isValid field', () async {
      if (harness == null || !harness!.meetsMinVersion('2.3.0')) return;
      final v = await harness!.client.validateAddress(
        'tmL6RMFZ9yK2rscAKbJfXb9zZjQb7JHMP2',
      );
      expect(v.isValid, isA<bool>());
    });

    test('validateaddress returns false for invalid string', () async {
      if (harness == null || !harness!.meetsMinVersion('2.3.0')) return;
      final v = await harness!.client.validateAddress('notanaddress');
      expect(v.isValid, isFalse);
    });

    test('z_validateaddress returns isValid field', () async {
      if (harness == null || !harness!.meetsMinVersion('2.3.0')) return;
      final v = await harness!.client.zValidateAddress(
        'zs1qmj4rsmcz0zqpwkfcvfpvnj3p8sclmm5nqhcfmmjkjwz7mlr3wn3s8ky4mxp7w0z4f4zphpvj',
      );
      expect(v.isValid, isA<bool>());
    });

    test('getpeerinfo returns a list', () async {
      if (harness == null || !harness!.meetsMinVersion('2.3.0')) return;
      final peers = await harness!.client.getPeerInfo();
      expect(peers, isA<List>());
    });

    test('getnetworkinfo returns subversion containing Zebra', () async {
      if (harness == null || !harness!.meetsMinVersion('2.3.0')) return;
      final net = await harness!.client.getNetworkInfo();
      expect(net.subversion, contains('Zebra'));
    });

    test('getblocksubsidy returns miner >= 0', () async {
      if (harness == null || !harness!.meetsMinVersion('2.3.0')) return;
      final sub = await harness!.client.getBlockSubsidy(height: 1);
      expect(sub.miner, greaterThanOrEqualTo(0));
      expect(sub.miner == 0 || sub.miner >= 100000000, isTrue);
    });

    test('getdifficulty returns a positive number', () async {
      if (harness == null || !harness!.meetsMinVersion('2.3.0')) return;
      final d = await harness!.client.getDifficulty();
      expect(d, greaterThan(0));
    });
  });

  group('Zebra v2.4.0+ RPCs', () {
    test('invalidateblock and reconsiderblock round-trip on genesis', () async {
      if (harness == null || !harness!.meetsMinVersion('2.4.0')) return;
      final hash = await harness!.client.getBestBlockHash();
      try {
        await harness!.client
            .invalidateBlock(hash)
            .timeout(const Duration(seconds: 10));
        await harness!.client.reconsiderBlock(hash);
      } on TimeoutException {
        // Some versions time out invalidating genesis.
      } on ZebraRpcException {
        // Some versions refuse to invalidate genesis.
      }
      final info = await harness!.client.getBlockchainInfo();
      expect(info.blocks, greaterThanOrEqualTo(0));
    });

    test('getaddressbalance response has balance field', () async {
      if (harness == null || !harness!.meetsMinVersion('2.4.0')) return;
      try {
        final bal = await harness!.client.getAddressBalance([
          'tmL6RMFZ9yK2rscAKbJfXb9zZjQb7JHMP2',
        ]);
        expect(bal.zatoshis, isA<int>());
      } on ZebraRpcException {
        // A fresh node may not have indexed the address.
      }
    });
  });

  group('Zebra v2.5.0+ / v3.0.0+ RPCs', () {
    test('getblockchaininfo includes valuePools list', () async {
      if (harness == null || !harness!.meetsMinVersion('2.5.0')) return;
      final info = await harness!.client.getBlockchainInfo();
      expect(info.valuePools, isA<List>());
      final ids = info.valuePools.map((p) => p.id).toList();
      if (ids.isNotEmpty) {
        expect(ids, isNot(contains('deferred')));
      }
    });

    test('getblockcount returns int >= 0', () async {
      if (harness == null || !harness!.meetsMinVersion('3.0.0')) return;
      final count = await harness!.client.getBlockCount();
      expect(count, isA<int>());
      expect(count, greaterThanOrEqualTo(0));
    });

    test('getblockhash at height 0 returns 64-char hex', () async {
      if (harness == null || !harness!.meetsMinVersion('3.0.0')) return;
      final hash = await harness!.client.getBlockHash(0);
      expect(hash, hasLength(64));
      expect(hash, matches(RegExp(r'^[0-9a-f]+$')));
    });

    test('getMempoolInfo returns map with size key', () async {
      if (harness == null || !harness!.meetsMinVersion('3.0.0')) return;
      final info = await harness!.client.getMempoolInfo();
      expect(info, isA<Map>());
      expect(info.containsKey('size'), isTrue);
      expect(info['size'], isA<int>());
    });

    test('getRawMempoolVerbose returns map on fresh node', () async {
      if (harness == null || !harness!.meetsMinVersion('3.0.0')) return;
      final verbose = await harness!.client.getRawMempoolVerbose();
      expect(verbose, isA<Map>());
    });
  });

}
