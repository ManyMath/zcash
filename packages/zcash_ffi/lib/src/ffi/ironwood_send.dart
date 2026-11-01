import 'dart:typed_data';

import 'package:zcash/zcash.dart';

import 'address_utils.dart';
import 'ironwood_build_request.dart';
import 'zcash_ffi_bindings.dart';

IronwoodPreparedSend prepareNativeIronwoodSend({
  required ZcashNetwork network,
  required ZcashScanResult scan,
  required String toAddress,
  required int amountZatoshis,
  required int targetHeight,
  required String seedHex,
  int account = 0,
  Iterable<IronwoodSendPlan> inFlight = const [],
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
