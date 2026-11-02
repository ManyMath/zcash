@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'harness.dart';

void main() {
  ZebraHarness? a;
  ZebraHarness? b;

  setUpAll(() async {
    if (!Platform.environment.containsKey('ZEBRA_INTEGRATION')) return;
    a = await ZebraHarness.start();
    b = await ZebraHarness.start(peerAddress: '127.0.0.1:${a!.p2pPort}');
  });

  tearDownAll(() async {
    if (b != null) await b!.shutdown();
    if (a != null) await a!.shutdown();
    a = null;
    b = null;
  });

  test('two regtest nodes establish a P2P connection', () async {
    if (a == null) return;
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    var peersA = 0;
    var peersB = 0;
    while (DateTime.now().isBefore(deadline)) {
      peersA = (await a!.client.getPeerInfo()).length;
      peersB = (await b!.client.getPeerInfo()).length;
      if (peersA >= 1 && peersB >= 1) break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    expect(peersA, greaterThanOrEqualTo(1), reason: 'A should see B as a peer');
    expect(peersB, greaterThanOrEqualTo(1), reason: 'B should see A as a peer');
  });

  test('blocks mined on A propagate to B over P2P', () async {
    if (a == null) return;

    final aBefore = await a!.client.getBlockCount();
    final bBefore = await b!.client.getBlockCount();
    expect(
      aBefore,
      equals(bBefore),
      reason: 'both nodes should start at the same height',
    );

    final hashes = await a!.mineBlocks(3);
    final aAfter = await a!.client.getBlockCount();
    expect(aAfter, equals(aBefore + 3));

    final deadline = DateTime.now().add(const Duration(seconds: 30));
    var bAfter = bBefore;
    while (DateTime.now().isBefore(deadline)) {
      bAfter = await b!.client.getBlockCount();
      if (bAfter >= aAfter) break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    expect(bAfter, equals(aAfter), reason: 'B should sync to A\'s tip via P2P');
    final bTip = await b!.client.getBestBlockHash();
    expect(
      bTip,
      equals(hashes.last),
      reason: 'B\'s tip hash should match A\'s last mined block',
    );
  });
}
