@TestOn('vm')
library;

import 'dart:io';
import 'package:test/test.dart';
import 'harness.dart';

// Needs an Ironwood-aware ZEBRA_BIN.
// ZIP 258: a migrated Orchard note must be created below NU6.3 activation.
void main() {
  const activationHeight = 4;

  ZebraHarness? harness;

  setUpAll(() async {
    if (!Platform.environment.containsKey('ZEBRA_INTEGRATION')) return;
    harness = await ZebraHarness.start(nu63ActivationHeight: activationHeight);
  });

  tearDownAll(() async {
    if (harness == null) return;
    await harness!.shutdown();
    harness = null;
  });

  group('Staged NU6.3 activation', () {
    test('the node reports NU6.3 pending at the configured height', () async {
      if (harness == null) return;
      expect(harness!.isStagedNu63Chain, isTrue);
      expect(harness!.nu63ActivationHeight, activationHeight);

      final info = await harness!.client.getBlockchainInfo();
      // NU6.3's branch id; NU6.2's is 5437f330.
      final nu63 = info.upgrades['37a5165b'];
      expect(
        nu63,
        isNotNull,
        reason:
            'the chain must carry NU6.3 (branch id 0x37a5165b) as an upgrade; '
            'its absence means this zebrad predates Ironwood and the chain '
            'cannot represent the pool at all. Upgrades seen: '
            '${info.upgrades.keys.toList()}',
      );
      expect(nu63!.activationHeight, activationHeight);
      expect(
        nu63.status,
        'pending',
        reason: 'nothing has been mined yet, so the tip is below activation',
      );
    });

    test('below the activation height the branch in effect is NU6.2', () async {
      if (harness == null) return;
      await _mineTo(harness!, activationHeight - 1);

      final info = await harness!.client.getBlockchainInfo();
      final nu62 = info.upgrades['5437f330'];
      expect(nu62, isNotNull, reason: 'NU6.2 must be in the upgrade table');
      expect(nu62!.activationHeight, 1);
      expect(nu62.status, 'active');
      expect(
        info.upgrades['37a5165b']!.status,
        'pending',
        reason:
            'this is the half of the chain on which an Orchard note can be '
            'created at all',
      );
    });

    test('mining to the activation height activates NU6.3', () async {
      if (harness == null) return;
      await _mineTo(harness!, activationHeight);

      final info = await harness!.client.getBlockchainInfo();
      expect(
        info.upgrades['37a5165b']!.status,
        'active',
        reason:
            'the tip has reached the activation height, so the Ironwood pool '
            'is live from here on and no further value may enter Orchard',
      );
      expect(info.upgrades['5437f330']!.status, 'active');
    });
  });
}

Future<void> _mineTo(ZebraHarness harness, int height) async {
  final current = await harness.client.getBlockCount();
  if (current >= height) return;
  await harness.mineBlocks(height - current);
  expect(await harness.client.getBlockCount(), height);
}
