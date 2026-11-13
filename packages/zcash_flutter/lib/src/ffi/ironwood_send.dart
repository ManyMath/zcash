import 'dart:typed_data';

import 'package:zcash/zcash.dart';

import '../sapling_proving_parameters.dart';
import 'address_utils.dart';
import 'ironwood_build_request.dart';
import 'transparent_build_request.dart';
import 'zcash_ffi_bindings.dart';

class IronwoodPaymentNativeRequest {
  const IronwoodPaymentNativeRequest({
    required this.targetHeight,
    required this.expiryHeight,
    required this.anchorHex,
    required this.ironwoodSpends,
    required this.outputs,
    required this.ironwoodOutput,
    this.ironwoodChangeZatoshis,
    this.provingParameters,
  });

  final int targetHeight;
  final int? expiryHeight;
  final String anchorHex;
  final List<IronwoodBuildIronwoodSpendNote> ironwoodSpends;
  final List<TransparentBuildOutput> outputs;
  final IronwoodBuildOutput ironwoodOutput;
  final int? ironwoodChangeZatoshis;
  final SaplingProvingParameters? provingParameters;
}

abstract interface class IronwoodPaymentBackend {
  IronwoodFeeQuote quote(IronwoodPaymentNativeRequest request);

  IronwoodBuildResult build(IronwoodPaymentNativeRequest request);
}

class _NativeIronwoodPaymentBackend implements IronwoodPaymentBackend {
  const _NativeIronwoodPaymentBackend({
    required this.network,
    required this.seedHex,
    required this.account,
    required this.regtestNu63ActivationHeight,
    required this.spendParamsPath,
    required this.outputParamsPath,
    required this.now,
    required this.bindings,
  });

  final ZcashNetwork network;
  final String seedHex;
  final int account;
  final int? regtestNu63ActivationHeight;
  final String? spendParamsPath;
  final String? outputParamsPath;
  final DateTime? now;
  final ZcashFfiBindings? bindings;

  @override
  IronwoodFeeQuote quote(IronwoodPaymentNativeRequest request) =>
      quoteNativeIronwoodFee(
        network: network,
        targetHeight: request.targetHeight,
        expiryHeight: request.expiryHeight,
        regtestNu63ActivationHeight: regtestNu63ActivationHeight,
        anchor: IronwoodAnchorSource.anchor(request.anchorHex),
        inputs: const [],
        outputs: request.outputs,
        ironwoodSpends: request.ironwoodSpends,
        ironwoodOutput: request.ironwoodOutput,
        ironwoodChangeZatoshis: request.ironwoodChangeZatoshis,
        seedHex: seedHex,
        account: account,
        spendParamsPath:
            request.provingParameters?.spendParamsPath ?? spendParamsPath,
        outputParamsPath:
            request.provingParameters?.outputParamsPath ?? outputParamsPath,
        now: now,
        allowExperimentalIronwoodBuild: true,
        bindings: bindings,
      );

  @override
  IronwoodBuildResult build(IronwoodPaymentNativeRequest request) =>
      buildNativeIronwoodTransaction(
        network: network,
        targetHeight: request.targetHeight,
        expiryHeight: request.expiryHeight,
        regtestNu63ActivationHeight: regtestNu63ActivationHeight,
        anchor: IronwoodAnchorSource.anchor(request.anchorHex),
        inputs: const [],
        outputs: request.outputs,
        ironwoodSpends: request.ironwoodSpends,
        ironwoodOutput: request.ironwoodOutput,
        ironwoodChangeZatoshis: request.ironwoodChangeZatoshis,
        seedHex: seedHex,
        account: account,
        spendParamsPath:
            request.provingParameters?.spendParamsPath ?? spendParamsPath,
        outputParamsPath:
            request.provingParameters?.outputParamsPath ?? outputParamsPath,
        now: now,
        allowExperimentalIronwoodBuild: true,
        bindings: bindings,
      );
}

/// Plans, quotes, and builds one post-NU6.3 payment funded by Ironwood notes.
/// Address decoding and receiver selection must already have produced [output].
IronwoodPreparedPayment prepareNativeIronwoodPayment({
  required ZcashScanResult scan,
  required ProposalOutput output,
  required String ironwoodChangeAddress,
  required int targetHeight,
  required int expiryHeight,
  ZcashNetwork network = ZcashNetwork.mainnet,
  String seedHex = '',
  int account = 0,
  IronwoodNoteReservations? reservations,
  int? maxNotes,
  int? regtestNu63ActivationHeight,
  SaplingProvingParameters? provingParameters,
  @Deprecated('Use provingParameters') String? spendParamsPath,
  @Deprecated('Use provingParameters') String? outputParamsPath,
  DateTime? now,
  bool allowExperimentalIronwoodBuild = false,
  ZcashFfiBindings? bindings,
  IronwoodPaymentBackend? backend,
}) {
  if (provingParameters != null &&
      (spendParamsPath != null || outputParamsPath != null)) {
    throw ArgumentError(
      'provingParameters cannot be combined with legacy parameter paths',
    );
  }
  if ((spendParamsPath == null) != (outputParamsPath == null)) {
    throw ArgumentError(
      'legacy Sapling proving-parameter paths must be supplied as a pair',
    );
  }
  if (backend == null && !allowExperimentalIronwoodBuild) {
    throw StateError(
      'prepareNativeIronwoodPayment is native-backed; set '
      'allowExperimentalIronwoodBuild: true to opt in',
    );
  }
  if (output.actualOutputPool != ProposalOutputPool.ironwood &&
      ironwoodChangeAddress.isEmpty) {
    throw ArgumentError.value(
      ironwoodChangeAddress,
      'ironwoodChangeAddress',
      'a non-Ironwood payment requires the wallet Ironwood change address',
    );
  }
  final addressNetwork = switch (network) {
    ZcashNetwork.mainnet => ZcashAddressNetwork.mainnet,
    ZcashNetwork.testnet => ZcashAddressNetwork.testnet,
    ZcashNetwork.regtest => ZcashAddressNetwork.regtest,
  };
  if (output.network != addressNetwork ||
      output.targetHeight != targetHeight ||
      output.transactionExpiryHeight != expiryHeight) {
    throw StateError(
      'the resolved output was validated for ${output.network.name} at target '
      '${output.targetHeight} with transaction expiry '
      '${output.transactionExpiryHeight}; re-resolve it for this build',
    );
  }
  final addressExpiryTime = output.addressExpiryTime;
  if (addressExpiryTime != null) {
    final buildTime = now;
    if (buildTime == null) {
      throw StateError(
        'the recipient has a time expiry; supply now when building so it can '
        'be checked again immediately before proving',
      );
    }
    if (buildTime.toUtc().millisecondsSinceEpoch ~/ 1000 > addressExpiryTime) {
      throw StateError(
        'the recipient address expired before the transaction was built; '
        'resolve the payment again',
      );
    }
  }
  final native =
      backend ??
      _NativeIronwoodPaymentBackend(
        network: network,
        seedHex: seedHex,
        account: account,
        regtestNu63ActivationHeight: regtestNu63ActivationHeight,
        spendParamsPath: spendParamsPath,
        outputParamsPath: outputParamsPath,
        now: now,
        bindings: bindings,
      );

  List<TransparentBuildOutput> paymentOutputs() =>
      output.actualOutputPool == ProposalOutputPool.ironwood
      ? const []
      : [
          TransparentBuildOutput(
            address: output.receiverAddress,
            valueZatoshis: output.amountZatoshis,
            memoHex: _memoHex(output.memo),
          ),
        ];

  List<IronwoodBuildIronwoodSpendNote> spendNotes(
    Iterable<ZcashScannedNote> notes,
    String anchor,
  ) => [
    for (final note in notes)
      IronwoodBuildIronwoodSpendNote.fromScannedNote(note, anchorHex: anchor),
  ];

  final anchor = scan.ironwoodAnchor;
  if (anchor == null) {
    throw IronwoodSendException(
      IronwoodSendRefusal.noIronwoodAnchor,
      'the scan reports no Ironwood anchor',
    );
  }
  final plan = IronwoodPaymentPlan.fromScan(
    scan: scan,
    output: output,
    targetHeight: targetHeight,
    expiryHeight: expiryHeight,
    reservations: reservations,
    maxNotes: maxNotes,
    feeForSpends: (notes) => native
        .quote(
          IronwoodPaymentNativeRequest(
            targetHeight: targetHeight,
            expiryHeight: expiryHeight,
            anchorHex: anchor,
            ironwoodSpends: spendNotes(notes, anchor),
            outputs: paymentOutputs(),
            ironwoodOutput: IronwoodBuildOutput(
              address: output.actualOutputPool == ProposalOutputPool.ironwood
                  ? output.receiverAddress
                  : ironwoodChangeAddress,
            ),
            provingParameters: provingParameters,
          ),
        )
        .feeZatoshis,
  );
  if (output.actualOutputPool != ProposalOutputPool.ironwood &&
      plan.changeZatoshis <= 0) {
    throw StateError(
      'the native builder requires a positive Ironwood change output for a '
      'non-Ironwood destination; select a larger note or rebuild after funding',
    );
  }
  final paysIronwood = output.actualOutputPool == ProposalOutputPool.ironwood;
  final transaction = native.build(
    IronwoodPaymentNativeRequest(
      targetHeight: plan.targetHeight,
      expiryHeight: plan.expiryHeight,
      anchorHex: plan.anchorHex,
      ironwoodSpends: spendNotes(plan.notes, plan.anchorHex),
      outputs: paymentOutputs(),
      ironwoodOutput: IronwoodBuildOutput(
        address: paysIronwood ? output.receiverAddress : ironwoodChangeAddress,
        valueZatoshis: paysIronwood ? plan.amountZatoshis : plan.changeZatoshis,
        memoHex: paysIronwood ? _memoHex(output.memo) : null,
      ),
      ironwoodChangeZatoshis: paysIronwood && plan.changeZatoshis > 0
          ? plan.changeZatoshis
          : null,
      provingParameters: provingParameters,
    ),
  );
  return IronwoodPreparedPayment(plan: plan, transaction: transaction);
}

IronwoodPreparedSend prepareNativeIronwoodSend({
  required ZcashNetwork network,
  required ZcashScanResult scan,
  required String toAddress,
  required int amountZatoshis,
  required int targetHeight,
  required String seedHex,
  int account = 0,
  Iterable<IronwoodSendPlan> inFlight = const [],
  IronwoodNoteReservations? reservations,
  int? maxNotes,
  int? expiryHeight,
  Uint8List? memo,
  int? regtestNu63ActivationHeight,
  DateTime? now,
  bool allowExperimentalIronwoodBuild = false,
  ZcashFfiBindings? bindings,
}) {
  if (!allowExperimentalIronwoodBuild) {
    throw StateError(
      'prepareNativeIronwoodSend is experimental and native-backed; set '
      'allowExperimentalIronwoodBuild: true to opt in. It requires a native '
      'library built with the off-by-default ironwood-tx-build feature, and it '
      'does not broadcast: the caller submits the transaction and is '
      'responsible for not spending its notes again until it is mined.',
    );
  }

  final plan = IronwoodSendPlan.fromScan(
    scan: scan,
    recipientAddress: toAddress,
    amountZatoshis: amountZatoshis,
    targetHeight: targetHeight,
    expiryHeight: expiryHeight,
    inFlight: inFlight,
    reservations: reservations,
    maxNotes: maxNotes,
    memo: memo,
    feeForSpends: (spends) => quoteNativeIronwoodFee(
      network: network,
      targetHeight: targetHeight,
      expiryHeight: expiryHeight,
      regtestNu63ActivationHeight: regtestNu63ActivationHeight,
      anchor: IronwoodAnchorSource.anchor(scan.ironwoodAnchor!),
      inputs: const [],
      ironwoodSpends: [
        for (final note in spends)
          IronwoodBuildIronwoodSpendNote.fromScannedNote(
            note,
            anchorHex: scan.ironwoodAnchor!,
          ),
      ],
      ironwoodOutput: IronwoodBuildOutput(
        address: toAddress,
        memoHex: _memoHex(memo),
      ),
      seedHex: seedHex,
      account: account,
      now: now,
      allowExperimentalIronwoodBuild: true,
      bindings: bindings,
    ).feeZatoshis,
  );

  final transaction = buildNativeIronwoodTransaction(
    network: network,
    targetHeight: plan.targetHeight,
    expiryHeight: plan.expiryHeight,
    regtestNu63ActivationHeight: regtestNu63ActivationHeight,
    anchor: IronwoodAnchorSource.anchor(plan.anchorHex),
    inputs: const [],
    ironwoodSpends: [
      for (final note in plan.notes)
        IronwoodBuildIronwoodSpendNote.fromScannedNote(
          note,
          anchorHex: plan.anchorHex,
        ),
    ],
    ironwoodOutput: IronwoodBuildOutput(
      address: plan.recipientAddress,
      valueZatoshis: plan.amountZatoshis,
      memoHex: plan.memoHex,
    ),
    ironwoodChangeZatoshis: plan.changeZatoshis,
    seedHex: seedHex,
    account: account,
    now: now,
    allowExperimentalIronwoodBuild: true,
    bindings: bindings,
  );

  return IronwoodPreparedSend(plan: plan, transaction: transaction);
}

/// The root of an empty depth-32 Orchard-family tree, Orchard and Ironwood
/// alike (`Anchor::empty_tree`, from the orchard crate's test vectors).
const String orchardFamilyEmptyTreeRootHex =
    'ae2935f1dfd8a24aed7c70df7de3a668eb7a49b1319880dde2bbd9031ae5d82f';

/// The roots of the two trees in [anchors], computed natively: a scan of no
/// blocks from those frontiers reports exactly their roots.
({String orchardAnchorHex, String ironwoodAnchorHex}) nativeZip318BoundaryRoots(
  Zip318BoundaryAnchors anchors, {
  required String ufvk,
  required String network,
  ZcashFfiBindings? bindings,
}) {
  final orchardTree = anchors.orchardTreeHex.isEmpty
      ? null
      : anchors.orchardTreeHex;
  final ironwoodTree = anchors.ironwoodTreeIsEmpty
      ? null
      : anchors.ironwoodTreeHex;
  ZcashScanResult? scan;
  if (orchardTree != null || ironwoodTree != null) {
    scan = scanCompactBlocks(
      ufvk: ufvk,
      network: network,
      blocks: const [],
      includeOrchardWitnesses: true,
      priorOrchardFrontier: orchardTree,
      priorIronwoodFrontier: ironwoodTree,
      bindings: bindings,
    );
  }
  // A frontier of size zero reports no root; that is the empty tree's.
  return (
    orchardAnchorHex: scan?.orchardAnchor ?? orchardFamilyEmptyTreeRootHex,
    ironwoodAnchorHex: scan?.ironwoodAnchor ?? orchardFamilyEmptyTreeRootHex,
  );
}

/// [Zip318TransferPlan.forTransfer] with the anchor roots computed from the
/// boundary tree state in [anchors], so the roots cannot drift from the
/// height they are checked against.
Zip318TransferPlan planNativeZip318Transfer({
  required Zip318ScheduledTransfer transfer,
  required Zip318FundingSelection funding,
  required Zip318BoundaryAnchors anchors,
  required int observedTipHeight,
  required String recipientAddress,
  required String ufvk,
  required String network,
  int? activationHeight,
  Zip318Parameters? parameters,
  ZcashFfiBindings? bindings,
}) {
  final roots = nativeZip318BoundaryRoots(
    anchors,
    ufvk: ufvk,
    network: network,
    bindings: bindings,
  );
  return Zip318TransferPlan.forTransfer(
    transfer: transfer,
    funding: funding,
    anchorHeight: anchors.boundaryHeight,
    orchardAnchorHex: roots.orchardAnchorHex,
    ironwoodAnchorHex: roots.ironwoodAnchorHex,
    observedTipHeight: observedTipHeight,
    recipientAddress: recipientAddress,
    activationHeight: activationHeight,
    parameters:
        parameters ??
        Zip318Parameters.forNetwork(ZcashConsensusNetwork.fromJson(network)),
  );
}

String? _memoHex(Uint8List? memo) {
  if (memo == null) {
    return null;
  }
  final buffer = StringBuffer();
  for (final byte in memo) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}
