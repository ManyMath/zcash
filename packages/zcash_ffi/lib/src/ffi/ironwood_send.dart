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
