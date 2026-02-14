@TestOn('vm')
library;

import 'dart:io';
import 'package:test/test.dart';
import 'harness.dart';

// Kept apart from zebra_regtest_test.dart, whose invalidateblock test on
// genesis can leave zebrad unusable.
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

  test('mineBlocks(1) advances chain height by one', () async {
    if (harness == null) return;
    final before = await harness!.client.getBlockCount();
    final hashes = await harness!.mineBlocks(1);
    expect(hashes, hasLength(1));
    expect(hashes.first, hasLength(64));
    expect(hashes.first, matches(RegExp(r'^[0-9a-f]+$')));
    final after = await harness!.client.getBlockCount();
    expect(after, equals(before + 1));
  });

  test('mineBlocks(5) produces five sequential blocks', () async {
    if (harness == null) return;
    final before = await harness!.client.getBlockCount();
    final hashes = await harness!.mineBlocks(5);
    expect(hashes, hasLength(5));
    expect(hashes.toSet().length, equals(5),
        reason: 'every mined block hash should be unique');
    for (final h in hashes) {
      expect(h, hasLength(64));
      expect(h, matches(RegExp(r'^[0-9a-f]+$')));
    }
    final after = await harness!.client.getBlockCount();
    expect(after, equals(before + 5));
  });

  test('mined block hash matches getblockhash at the new tip', () async {
    if (harness == null) return;
    final hashes = await harness!.mineBlocks(1);
    final tipHeight = await harness!.client.getBlockCount();
    final tipHash = await harness!.client.getBlockHash(tipHeight);
    expect(tipHash, equals(hashes.single));
  });
}
