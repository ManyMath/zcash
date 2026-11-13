import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

const _anchor =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

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

ProposalOutput _output({
  required String address,
  required ZcashAddressReceiverType receiver,
  required ProposalOutputPool pool,
}) => resolveProposalOutput(
  recipient: ProposalRecipient(
    address: address,
    amountZatoshis: 50000,
    pool: pool,
  ),
  address: _metadata(receiver),
  network: ZcashAddressNetwork.regtest,
  targetHeight: 301,
  transactionExpiryHeight: 340,
  currentUnixTime: 1000,
);

IronwoodBuildResult _built(
  IronwoodPaymentPlan plan, {
  required int vout,
  required int saplingOutputs,
}) => IronwoodBuildResult(
  network: ZcashAddressNetwork.regtest,
  transactionHex: 'ff' * 20,
  txid: 'ee' * 32,
  version: 'v6',
  expiryHeight: 340,
  feeZatoshis: plan.feeZatoshis,
  feeRule: 'zip317',
  proofValidity: 'real',
  ironwoodAnchor: plan.anchorHex,
  ironwoodAnchorSource: 'anchor',
  vin: 0,
  vout: vout,
  saplingOutputs: saplingOutputs,
  ironwoodActions: 1,
  ironwoodSpends: plan.notes.length,
  totalInputZatoshis: plan.inputZatoshis,
  ironwoodInputZatoshis: plan.inputZatoshis,
  nonIronwoodOutputZatoshis: plan.amountZatoshis,
  ironwoodOutputZatoshis: plan.changeZatoshis,
  rng: 'system',
);

void main() {
  test('Ironwood source plans and verifies a transparent destination', () {
    final output = _output(
      address: 'tmExactTransparentReceiver',
      receiver: ZcashAddressReceiverType.p2pkh,
      pool: ProposalOutputPool.transparent,
    );
    final plan = IronwoodPaymentPlan.fromScan(
      scan: _scan(),
      output: output,
      targetHeight: 301,
      expiryHeight: 340,
      feeForSpends: (notes) => 10000,
    );
    final prepared = IronwoodPreparedPayment(
      plan: plan,
      transaction: _built(plan, vout: 1, saplingOutputs: 0),
    );

    expect(plan.output.encodedAddress, 'tmExactTransparentReceiver');
    expect(plan.output.receiverAddress, 'tmExactTransparentReceiver');
    expect(plan.output.selectedReceiver, ZcashAddressReceiverType.p2pkh);
    expect(plan.output.actualOutputPool, ProposalOutputPool.transparent);
    expect(plan.feeZatoshis, 10000);
    expect(plan.changeZatoshis, 40000);
    expect(prepared.transaction.vout, 1);
  });

  test('Ironwood source plans and verifies a Sapling destination', () {
    final output = _output(
      address: 'zregtestExactSaplingReceiver',
      receiver: ZcashAddressReceiverType.sapling,
      pool: ProposalOutputPool.sapling,
    );
    final plan = IronwoodPaymentPlan.fromScan(
      scan: _scan(),
      output: output,
      targetHeight: 301,
      expiryHeight: 340,
      feeForSpends: (notes) => 10000,
    );
    final prepared = IronwoodPreparedPayment(
      plan: plan,
      transaction: _built(plan, vout: 0, saplingOutputs: 1),
    );

    expect(plan.output.encodedAddress, 'zregtestExactSaplingReceiver');
    expect(plan.output.receiverAddress, 'zregtestExactSaplingReceiver');
    expect(plan.output.selectedReceiver, ZcashAddressReceiverType.sapling);
    expect(plan.output.actualOutputPool, ProposalOutputPool.sapling);
    expect(plan.feeZatoshis, 10000);
    expect(plan.changeZatoshis, 40000);
    expect(prepared.transaction.saplingOutputs, 1);
  });
}
