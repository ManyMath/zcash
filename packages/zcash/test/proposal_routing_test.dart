import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

void main() {
  const ua = 'uregtest1-user-encoded-address';

  ZcashAddressMetadata unifiedMetadata({
    ZcashAddressNetwork network = ZcashAddressNetwork.regtest,
    int? expiryHeight,
    int? expiryTime,
  }) => ZcashAddressMetadata(
    network: network,
    receiverType: ZcashAddressReceiverType.unified,
    pool: ZcashAddressPool.mixed,
    receivers: const ZcashAddressReceiverPresence(
      sprout: false,
      orchard: true,
      sapling: true,
      transparent: true,
      transparentKind: 'p2pkh',
      unknown: 0,
      total: 3,
    ),
    unifiedRevision: expiryHeight == null && expiryTime == null ? 'r0' : 'r2',
    expiryHeight: expiryHeight,
    expiryTime: expiryTime,
  );

  ZcashUnifiedAddressReceiverInventory inventory({
    List<ZcashUnifiedAddressReceiver>? receivers,
  }) => ZcashUnifiedAddressReceiverInventory(
    network: ZcashAddressNetwork.regtest,
    receivers:
        receivers ??
        const [
          ZcashUnifiedAddressReceiver(
            index: 0,
            kind: ZcashAddressReceiverType.p2pkh,
            pool: ZcashAddressPool.transparent,
            address: 'tmReceiver',
          ),
          ZcashUnifiedAddressReceiver(
            index: 1,
            kind: ZcashAddressReceiverType.sapling,
            pool: ZcashAddressPool.sapling,
            address: 'zregtestsaplingReceiver',
          ),
          ZcashUnifiedAddressReceiver(
            index: 2,
            kind: ZcashAddressReceiverType.orchard,
            pool: ZcashAddressPool.orchard,
          ),
        ],
    counts: const ZcashUnifiedAddressReceiverCounts(
      orchard: 1,
      sapling: 1,
      transparent: 1,
      p2pkh: 1,
      p2sh: 0,
      unknown: 0,
      total: 3,
    ),
  );

  group('Ironwood proposal routing', () {
    test('selects the Orchard receiver but records an Ironwood output', () {
      final output = resolveProposalOutput(
        recipient: ProposalRecipient(
          address: ua,
          amountZatoshis: 123456,
          pool: ProposalOutputPool.ironwood,
          memo: Uint8List.fromList([0xf6]),
        ),
        address: unifiedMetadata(),
        unifiedReceivers: inventory(),
        network: ZcashAddressNetwork.regtest,
        targetHeight: 301,
        transactionExpiryHeight: 340,
        currentUnixTime: 1000,
      );

      expect(output.encodedAddress, ua);
      expect(output.receiverAddress, ua);
      expect(output.selectedReceiver, ZcashAddressReceiverType.orchard);
      expect(output.actualOutputPool, ProposalOutputPool.ironwood);
      expect(output.amountZatoshis, 123456);
      expect(output.zip317OutputActions, 1);
      expect(output.memo, [0xf6]);
    });

    test('rejects the legacy Orchard pool for ordinary post-NU6.3 sends', () {
      expect(
        () => resolveProposalOutput(
          recipient: ProposalRecipient(
            address: ua,
            amountZatoshis: 1,
            pool: ProposalOutputPool.orchard,
          ),
          address: unifiedMetadata(),
          unifiedReceivers: inventory(),
          network: ZcashAddressNetwork.regtest,
          targetHeight: 301,
          transactionExpiryHeight: 340,
          currentUnixTime: 1000,
        ),
        throwsA(
          isA<ProposalRoutingException>().having(
            (e) => e.refusal,
            'refusal',
            ProposalRoutingRefusal.orchardClosed,
          ),
        ),
      );
    });

    test('treats unknown receiver items as absent and selects Orchard', () {
      final withUnknown = inventory(
        receivers: const [
          ZcashUnifiedAddressReceiver(
            index: 0,
            kind: ZcashAddressReceiverType.unknown,
            pool: ZcashAddressPool.unknown,
          ),
          ZcashUnifiedAddressReceiver(
            index: 1,
            kind: ZcashAddressReceiverType.orchard,
            pool: ZcashAddressPool.orchard,
          ),
        ],
      );
      final output = resolveProposalOutput(
        recipient: ProposalRecipient(address: ua, amountZatoshis: 1),
        address: unifiedMetadata(),
        unifiedReceivers: withUnknown,
        network: ZcashAddressNetwork.regtest,
        targetHeight: 301,
        transactionExpiryHeight: 340,
        currentUnixTime: 1000,
      );

      expect(output.encodedAddress, ua);
      expect(output.selectedReceiver, ZcashAddressReceiverType.orchard);
      expect(output.actualOutputPool, ProposalOutputPool.ironwood);
    });

    test('checks network and both address expiry forms', () {
      ProposalOutput invoke(ZcashAddressMetadata metadata) =>
          resolveProposalOutput(
            recipient: ProposalRecipient(
              address: ua,
              amountZatoshis: 1,
              pool: ProposalOutputPool.ironwood,
            ),
            address: metadata,
            unifiedReceivers: inventory(),
            network: ZcashAddressNetwork.regtest,
            targetHeight: 301,
            transactionExpiryHeight: 340,
            currentUnixTime: 1000,
          );

      expect(
        () => invoke(unifiedMetadata(network: ZcashAddressNetwork.mainnet)),
        throwsA(
          isA<ProposalRoutingException>().having(
            (e) => e.refusal,
            'refusal',
            ProposalRoutingRefusal.wrongNetwork,
          ),
        ),
      );
      expect(
        () => invoke(unifiedMetadata(expiryHeight: 299)),
        throwsA(
          isA<ProposalRoutingException>().having(
            (e) => e.refusal,
            'refusal',
            ProposalRoutingRefusal.expired,
          ),
        ),
      );
      expect(
        () => invoke(unifiedMetadata(expiryTime: 999)),
        throwsA(
          isA<ProposalRoutingException>().having(
            (e) => e.refusal,
            'refusal',
            ProposalRoutingRefusal.expired,
          ),
        ),
      );
    });
  });

  group('transparent proposal routing', () {
    const transparent = 'tmExactTransparentReceiver';
    final metadata = ZcashAddressMetadata(
      network: ZcashAddressNetwork.regtest,
      receiverType: ZcashAddressReceiverType.p2pkh,
      pool: ZcashAddressPool.transparent,
      receivers: const ZcashAddressReceiverPresence(
        sprout: false,
        orchard: false,
        sapling: false,
        transparent: true,
        transparentKind: 'p2pkh',
        unknown: 0,
        total: 1,
      ),
    );

    test('records the exact direct receiver and transparent output pool', () {
      final output = resolveProposalOutput(
        recipient: ProposalRecipient(
          address: transparent,
          amountZatoshis: 50000,
          pool: ProposalOutputPool.transparent,
        ),
        address: metadata,
        network: ZcashAddressNetwork.regtest,
        targetHeight: 301,
        transactionExpiryHeight: 340,
        currentUnixTime: 1000,
      );

      expect(output.encodedAddress, transparent);
      expect(output.receiverAddress, transparent);
      expect(output.selectedReceiver, ZcashAddressReceiverType.p2pkh);
      expect(output.actualOutputPool, ProposalOutputPool.transparent);
      expect(output.zip317OutputActions, 1);
    });

    test('prohibits memos instead of silently dropping them', () {
      final transparentOnly = inventory(
        receivers: const [
          ZcashUnifiedAddressReceiver(
            index: 0,
            kind: ZcashAddressReceiverType.p2pkh,
            pool: ZcashAddressPool.transparent,
            address: transparent,
          ),
        ],
      );
      expect(
        () => resolveProposalOutput(
          recipient: ProposalRecipient(
            address: ua,
            amountZatoshis: 50000,
            memo: Uint8List.fromList([0xf6]),
          ),
          address: unifiedMetadata(),
          unifiedReceivers: transparentOnly,
          network: ZcashAddressNetwork.regtest,
          targetHeight: 301,
          transactionExpiryHeight: 340,
          currentUnixTime: 1000,
        ),
        throwsA(
          isA<ProposalRoutingException>().having(
            (e) => e.refusal,
            'refusal',
            ProposalRoutingRefusal.transparentMemo,
          ),
        ),
      );
    });

    test(
      'does not claim TEX support without the ZIP 320 two-transaction path',
      () {
        const texMetadata = ZcashAddressMetadata(
          network: ZcashAddressNetwork.regtest,
          receiverType: ZcashAddressReceiverType.tex,
          pool: ZcashAddressPool.transparent,
          receivers: ZcashAddressReceiverPresence(
            sprout: false,
            orchard: false,
            sapling: false,
            transparent: true,
            transparentKind: 'tex',
            unknown: 0,
            total: 1,
          ),
        );
        expect(
          () => resolveProposalOutput(
            recipient: ProposalRecipient(
              address: 'texregtest1exact',
              amountZatoshis: 50000,
            ),
            address: texMetadata,
            network: ZcashAddressNetwork.regtest,
            targetHeight: 301,
            transactionExpiryHeight: 340,
            currentUnixTime: 1000,
          ),
          throwsA(
            isA<ProposalRoutingException>().having(
              (e) => e.refusal,
              'refusal',
              ProposalRoutingRefusal.texRequiresTwoTransactions,
            ),
          ),
        );
      },
    );
  });
}
