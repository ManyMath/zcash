import 'package:test/test.dart';
import 'package:zcash_flutter/zcash_flutter.dart';

const _anchor =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

class _Backend implements IronwoodPaymentBackend {
  final List<IronwoodPaymentNativeRequest> quotes = [];
  final List<IronwoodPaymentNativeRequest> builds = [];

  @override
  IronwoodFeeQuote quote(IronwoodPaymentNativeRequest request) {
    quotes.add(request);
    final input = request.ironwoodSpends.fold(
      0,
      (sum, spend) => sum + spend.valueZatoshis,
    );
    final nonIronwood = request.outputs.fold(
      0,
      (sum, output) => sum + output.valueZatoshis,
    );
    return IronwoodFeeQuote(
      network: ZcashAddressNetwork.regtest,
      feeZatoshis: 10000,
      feeRule: 'zip317',
      consensusBranchId: 'nu6.3',
      totalInputZatoshis: input,
      nonIronwoodOutputZatoshis: nonIronwood,
      maxIronwoodOutputZatoshis: input - nonIronwood - 10000,
      ironwoodSpends: request.ironwoodSpends.length,
      orchardSpends: 0,
      saplingSpends: 0,
      transparentInputs: 0,
    );
  }

  @override
  IronwoodBuildResult build(IronwoodPaymentNativeRequest request) {
    builds.add(request);
    final input = request.ironwoodSpends.fold(
      0,
      (sum, spend) => sum + spend.valueZatoshis,
    );
    final nonIronwood = request.outputs.fold(
      0,
      (sum, output) => sum + output.valueZatoshis,
    );
    final transparent = request.outputs.where(
      (output) => output.address.startsWith('t'),
    );
    final sapling = request.outputs.where(
      (output) => output.address.startsWith('z'),
    );
    return IronwoodBuildResult(
      network: ZcashAddressNetwork.regtest,
      transactionHex: 'ff' * 20,
      txid: 'ee' * 32,
      version: 'v6',
      expiryHeight: request.expiryHeight!,
      feeZatoshis: 10000,
      feeRule: 'zip317',
      proofValidity: 'real',
      ironwoodAnchor: request.anchorHex,
      ironwoodAnchorSource: 'anchor',
      vin: 0,
      vout: transparent.length,
      saplingOutputs: sapling.length,
      ironwoodActions: 1,
      ironwoodSpends: request.ironwoodSpends.length,
      ironwoodChangeOutputs: request.ironwoodChangeZatoshis == null ? 0 : 1,
      totalInputZatoshis: input,
      ironwoodInputZatoshis: input,
      ironwoodChangeZatoshis: request.ironwoodChangeZatoshis ?? 0,
      nonIronwoodOutputZatoshis: nonIronwood,
      ironwoodOutputZatoshis: request.ironwoodOutput.valueZatoshis!,
      rng: 'system',
    );
  }
}

ZcashScanResult _scan() => ZcashScanResult(
  scannedBlocks: 1,
  discoveredNotes: 1,
  totalValue: 100000,
  notes: [
    ZcashScannedNote(
      height: 200,
      tx: 'aa' * 32,
      output: 0,
      value: 100000,
      pool: 'ironwood',
      nullifier: 'bb' * 32,
      commitmentPosition: 0,
      recipient: 'uregtest1change',
      rseed: '11' * 32,
      rho: '22' * 32,
      noteVersion: 'v3',
      witness: '33' * 40,
    ),
  ],
  ironwoodAnchor: _anchor,
);

ZcashAddressMetadata _metadata(ZcashAddressReceiverType type) =>
    ZcashAddressMetadata(
      network: ZcashAddressNetwork.regtest,
      receiverType: type,
      pool: type == ZcashAddressReceiverType.sapling
          ? ZcashAddressPool.sapling
          : ZcashAddressPool.transparent,
      receivers: ZcashAddressReceiverPresence(
        sprout: false,
        orchard: false,
        sapling: type == ZcashAddressReceiverType.sapling,
        transparent: type == ZcashAddressReceiverType.p2pkh,
        transparentKind: type == ZcashAddressReceiverType.p2pkh
            ? 'p2pkh'
            : null,
        unknown: 0,
        total: 1,
      ),
    );

ProposalOutput _directOutput(
  String address,
  ZcashAddressReceiverType receiver,
) => resolveProposalOutput(
  recipient: ProposalRecipient(address: address, amountZatoshis: 50000),
  address: _metadata(receiver),
  network: ZcashAddressNetwork.regtest,
  targetHeight: 301,
  transactionExpiryHeight: 340,
  currentUnixTime: 1000,
);

void main() {
  test('executes an Orchard UA receiver as an actual Ironwood output', () {
    const encoded = 'uregtest1-exact-user-address';
    final output = resolveProposalOutput(
      recipient: ProposalRecipient(address: encoded, amountZatoshis: 50000),
      address: const ZcashAddressMetadata(
        network: ZcashAddressNetwork.regtest,
        receiverType: ZcashAddressReceiverType.unified,
        pool: ZcashAddressPool.orchard,
        receivers: ZcashAddressReceiverPresence(
          sprout: false,
          orchard: true,
          sapling: false,
          transparent: false,
          unknown: 0,
          total: 1,
        ),
      ),
      unifiedReceivers: const ZcashUnifiedAddressReceiverInventory(
        network: ZcashAddressNetwork.regtest,
        receivers: [
          ZcashUnifiedAddressReceiver(
            index: 0,
            kind: ZcashAddressReceiverType.orchard,
            pool: ZcashAddressPool.orchard,
          ),
        ],
        counts: ZcashUnifiedAddressReceiverCounts(
          orchard: 1,
          sapling: 0,
          transparent: 0,
          p2pkh: 0,
          p2sh: 0,
          unknown: 0,
          total: 1,
        ),
      ),
      network: ZcashAddressNetwork.regtest,
      targetHeight: 301,
      transactionExpiryHeight: 340,
      currentUnixTime: 1000,
    );
    final backend = _Backend();
    final prepared = prepareNativeIronwoodPayment(
      scan: _scan(),
      output: output,
      ironwoodChangeAddress: 'unused-for-Ironwood-destination',
      targetHeight: 301,
      expiryHeight: 340,
      network: ZcashNetwork.regtest,
      backend: backend,
    );

    expect(output.encodedAddress, encoded);
    expect(output.receiverAddress, encoded);
    expect(output.selectedReceiver, ZcashAddressReceiverType.orchard);
    expect(output.actualOutputPool, ProposalOutputPool.ironwood);
    expect(backend.builds.single.outputs, isEmpty);
    expect(backend.builds.single.ironwoodOutput.address, encoded);
    expect(backend.builds.single.ironwoodOutput.valueZatoshis, 50000);
    expect(backend.builds.single.ironwoodChangeZatoshis, 40000);
    expect(
      prepared.plan.inputZatoshis,
      prepared.plan.amountZatoshis +
          prepared.plan.feeZatoshis +
          prepared.plan.changeZatoshis,
    );
  });

  for (final destination in [
    (
      name: 'transparent',
      address: 'tmExactTransparentReceiver',
      receiver: ZcashAddressReceiverType.p2pkh,
      pool: ProposalOutputPool.transparent,
    ),
    (
      name: 'Sapling',
      address: 'zregtestExactSaplingReceiver',
      receiver: ZcashAddressReceiverType.sapling,
      pool: ProposalOutputPool.sapling,
    ),
  ]) {
    test('executes Ironwood to ${destination.name} with Ironwood change', () {
      final backend = _Backend();
      final output = _directOutput(destination.address, destination.receiver);
      final prepared = prepareNativeIronwoodPayment(
        scan: _scan(),
        output: output,
        ironwoodChangeAddress: 'uregtest1-wallet-change',
        targetHeight: 301,
        expiryHeight: 340,
        network: ZcashNetwork.regtest,
        backend: backend,
      );

      expect(output.encodedAddress, destination.address);
      expect(output.receiverAddress, destination.address);
      expect(output.selectedReceiver, destination.receiver);
      expect(output.actualOutputPool, destination.pool);
      expect(backend.quotes, isNotEmpty);
      expect(backend.builds.single.outputs.single.address, destination.address);
      expect(backend.builds.single.outputs.single.valueZatoshis, 50000);
      expect(
        backend.builds.single.ironwoodOutput.address,
        'uregtest1-wallet-change',
      );
      expect(backend.builds.single.ironwoodOutput.valueZatoshis, 40000);
      expect(
        prepared.plan.inputZatoshis,
        prepared.plan.amountZatoshis +
            prepared.plan.feeZatoshis +
            prepared.plan.changeZatoshis,
      );
    });
  }
}
