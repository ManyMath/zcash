import 'dart:typed_data';

import 'package:zcash/zcash.dart';

import 'address_utils.dart';
import 'sapling_build_request.dart';
import 'zcash_ffi_bindings.dart';

SaplingPreparedSend prepareNativeSaplingSend({
  required ZcashNetwork network,
  required ZcashScanResult scan,
  required String toAddress,
  required String changeAddress,
  required int amountZatoshis,
  required int targetHeight,
  required String seedHex,
  required String spendParamsPath,
  required String outputParamsPath,
  int account = 0,
  Iterable<SaplingSendPlan> inFlight = const [],
  int? maxNotes,
  Uint8List? memo,
  int? regtestNu63ActivationHeight,
  bool allowExperimentalSaplingBuild = false,
  ZcashFfiBindings? bindings,
}) {
  if (!allowExperimentalSaplingBuild) {
    throw StateError(
      'prepareNativeSaplingSend is experimental and native-backed; set '
      'allowExperimentalSaplingBuild: true to opt in. It requires a native '
      'library built with the off-by-default sapling-spend-build feature, and '
      'it does not broadcast: the caller submits the transaction and is '
      'responsible for not spending its notes again until it is mined.',
    );
  }
  if (spendParamsPath.isEmpty || outputParamsPath.isEmpty) {
    throw ArgumentError(
      'prepareNativeSaplingSend requires the Sapling MPC proving parameters. '
      'Without them the build produces placeholder proofs and the transaction '
      'can never be broadcast, which is a worse answer than this one.',
    );
  }

  final plan = SaplingSendPlan.fromScan(
    scan: scan,
    recipientAddress: toAddress,
    changeAddress: changeAddress,
    amountZatoshis: amountZatoshis,
    targetHeight: targetHeight,
    inFlight: inFlight,
    maxNotes: maxNotes,
    memo: memo,
    feeForSpends: (spends) => quoteNativeSaplingFee(
      network: network,
      targetHeight: targetHeight,
      regtestNu63ActivationHeight: regtestNu63ActivationHeight,
      seedHex: seedHex,
      account: account,
      spendNotes: [
        for (final note in spends)
          SaplingBuildSpendNote.fromScannedNote(
            note,
            anchorHex: scan.saplingAnchor!,
          ),
      ],
      outputs: [
        SaplingBuildOutput(
          address: toAddress,
          valueZatoshis: amountZatoshis,
          memoHex: _memoHex(memo),
        ),
        SaplingBuildOutput(address: changeAddress),
      ],
      allowExperimentalSaplingBuild: true,
      bindings: bindings,
    ).feeZatoshis,
  );

  final transaction = buildNativeSaplingTransaction(
    network: network,
    targetHeight: plan.targetHeight,
    regtestNu63ActivationHeight: regtestNu63ActivationHeight,
    seedHex: seedHex,
    account: account,
    spendNotes: [
      for (final note in plan.notes)
        SaplingBuildSpendNote.fromScannedNote(note, anchorHex: plan.anchorHex),
    ],
    outputs: [
      SaplingBuildOutput(
        address: plan.recipientAddress,
        valueZatoshis: plan.amountZatoshis,
        memoHex: plan.memoHex,
      ),
      if (plan.changeZatoshis > 0)
        SaplingBuildOutput(
          address: plan.changeAddress,
          valueZatoshis: plan.changeZatoshis,
        ),
    ],
    spendParamsPath: spendParamsPath,
    outputParamsPath: outputParamsPath,
    allowExperimentalSaplingBuild: true,
    bindings: bindings,
  );

  return SaplingPreparedSend(plan: plan, transaction: transaction);
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
