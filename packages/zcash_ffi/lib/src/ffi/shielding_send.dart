import 'dart:typed_data';

import 'package:zcash/zcash.dart';

import 'address_utils.dart';
import 'ironwood_build_request.dart';
import 'sapling_build_request.dart';
import 'transparent_build_request.dart';
import 'zcash_ffi_bindings.dart';

enum ShieldingDestination { sapling, ironwood }

enum ShieldingRefusal {
  noIronwoodAnchor,

  noSaplingParameters,

  invalidRecipient,

  invalidMemo,

  missingSigningKey,

  planBuildMismatch,
}

class ShieldingException implements Exception {
  ShieldingException(this.refusal, this.message);

  final ShieldingRefusal refusal;
  final String message;

  @override
  String toString() => 'ShieldingException: $message';
}

class ShieldingPreparedSend {
  const ShieldingPreparedSend({
    required this.destination,
    required this.selection,
    required this.transactionHex,
    required this.txid,
    required this.feeZatoshis,
    required this.shieldedZatoshis,
  });

  final ShieldingDestination destination;

  final TransparentInputSelection selection;

  final String transactionHex;

  final String txid;

  final int feeZatoshis;

  final int shieldedZatoshis;

  bool get spendsCoinbase => selection.spendsCoinbase;
}

ShieldingPreparedSend prepareNativeShieldingSend({
  required ZcashNetwork network,
  required ShieldingDestination destination,
  required TransparentCoinSet coins,
  required String toAddress,
  required int targetHeight,
  required String Function(TrackedTransparentCoin coin) signingKeyForCoin,
  int? amountZatoshis,
  IronwoodAnchorSource? ironwoodAnchor,
  String? spendParamsPath,
  String? outputParamsPath,
  String? seedHex,
  int account = 0,
  int? maxCoins,
  Uint8List? memo,
  int? regtestNu63ActivationHeight,
  DateTime? now,
  bool allowExperimentalBuild = false,
  ZcashFfiBindings? bindings,
}) {
  if (!allowExperimentalBuild) {
    throw StateError(
      'prepareNativeShieldingSend is experimental and native-backed; set '
      'allowExperimentalBuild: true to opt in. It requires a native library '
      'built with the off-by-default feature for the destination pool '
      '(ironwood-tx-build or sapling-spend-build), and it does not broadcast.',
    );
  }
  if (toAddress.isEmpty) {
    throw ShieldingException(
      ShieldingRefusal.invalidRecipient,
      'a shielding transaction needs a destination address',
    );
  }

  final memoHex = _memoHex(memo);
  if (memo != null) {
    final refusal = zcashMemoRefusalReason(
      memo,
      recipientCanCarryMemo: !zcashAddressIsTransparent(toAddress),
      recipientDescription: 'transparent address',
    );
    if (refusal != null) {
      throw ShieldingException(ShieldingRefusal.invalidMemo, refusal);
    }
  }
  if (destination == ShieldingDestination.ironwood && ironwoodAnchor == null) {
    throw ShieldingException(
      ShieldingRefusal.noIronwoodAnchor,
      'shielding into Ironwood needs an anchor, and there is no default worth '
      'inventing: consensus requires it to be a root the network knows, so a '
      'made-up one builds, proves, and is rejected by every node. Take it from '
      'the chain\'s tree state at the height this will be mined against',
    );
  }
  if (destination == ShieldingDestination.sapling &&
      ((spendParamsPath ?? '').isEmpty || (outputParamsPath ?? '').isEmpty)) {
    throw ShieldingException(
      ShieldingRefusal.noSaplingParameters,
      'shielding into Sapling needs the Sapling MPC proving parameters. '
      'Without them the build produces placeholder proofs and the transaction '
      'can never be broadcast, which is a worse answer than this one',
    );
  }

  final keys = <String, String>{};
  String keyFor(TrackedTransparentCoin coin) {
    final key = keys[coin.outpoint] ??= signingKeyForCoin(coin);
    if (key.isEmpty) {
      throw ShieldingException(
        ShieldingRefusal.missingSigningKey,
        'no signing key was supplied for one of the selected coins, so the '
        'transaction could be built and never signed',
      );
    }
    return key;
  }

  List<TransparentBuildInput> inputsFor(
    Iterable<TrackedTransparentCoin> chosen,
  ) => [
    for (final coin in chosen)
      TransparentBuildInput(
        txid: coin.utxo.txid,
        vout: coin.utxo.outputIndex,
        valueZatoshis: coin.satoshis,
        secretKeyHex: keyFor(coin),
      ),
  ];

  int feeForCoins(List<TrackedTransparentCoin> chosen) {
    final inputs = inputsFor(chosen);
    switch (destination) {
      case ShieldingDestination.ironwood:
        return quoteNativeIronwoodFee(
          network: network,
          targetHeight: targetHeight,
          regtestNu63ActivationHeight: regtestNu63ActivationHeight,
          anchor: ironwoodAnchor!,
          inputs: inputs,
          ironwoodOutput: IronwoodBuildOutput(
            address: toAddress,
            memoHex: memoHex,
          ),
          seedHex: seedHex,
          account: account,
          now: now,
          allowExperimentalIronwoodBuild: true,
          bindings: bindings,
        ).feeZatoshis;
      case ShieldingDestination.sapling:
        return quoteNativeSaplingFee(
          network: network,
          targetHeight: targetHeight,
          regtestNu63ActivationHeight: regtestNu63ActivationHeight,
          seedHex: seedHex ?? '',
          account: account,
          inputs: inputs,
          outputs: [SaplingBuildOutput(address: toAddress, memoHex: memoHex)],
          allowExperimentalSaplingBuild: true,
          bindings: bindings,
        ).feeZatoshis;
    }
  }

  final selection = amountZatoshis == null
      ? TransparentInputSelection.sweep(coins: coins, feeForCoins: feeForCoins)
      : TransparentInputSelection.select(
          coins: coins,
          amountZatoshis: amountZatoshis,
          feeForCoins: feeForCoins,
          maxCoins: maxCoins,
        );

  final inputs = inputsFor(selection.coins);
  final secrets = [for (final input in inputs) input.secretKeyHex];

  final String transactionHex;
  final String txid;
  final int fee;
  final int shielded;
  switch (destination) {
    case ShieldingDestination.ironwood:
      final built = buildNativeIronwoodTransaction(
        network: network,
        targetHeight: targetHeight,
        regtestNu63ActivationHeight: regtestNu63ActivationHeight,
        anchor: ironwoodAnchor!,
        inputs: inputs,
        ironwoodOutput: IronwoodBuildOutput(
          address: toAddress,
          valueZatoshis: selection.amountZatoshis,
          memoHex: memoHex,
        ),
        outputs: [
          if (selection.changeZatoshis > 0)
            TransparentBuildOutput(
              address: selection.coins.first.utxo.address,
              valueZatoshis: selection.changeZatoshis,
            ),
        ],
        feeZatoshis: selection.feeZatoshis,
        seedHex: seedHex,
        account: account,
        now: now,
        allowExperimentalIronwoodBuild: true,
        bindings: bindings,
      );
      transactionHex = built.transactionHex;
      txid = built.txid;
      fee = built.feeZatoshis;
      shielded = built.ironwoodOutputZatoshis;
    case ShieldingDestination.sapling:
      final built = buildNativeSaplingTransaction(
        network: network,
        targetHeight: targetHeight,
        regtestNu63ActivationHeight: regtestNu63ActivationHeight,
        feeZatoshis: selection.feeZatoshis,
        seedHex: seedHex ?? '',
        account: account,
        inputs: inputs,
        outputs: [
          SaplingBuildOutput(
            address: toAddress,
            valueZatoshis: selection.amountZatoshis,
            memoHex: memoHex,
          ),
          if (selection.changeZatoshis > 0)
            SaplingBuildOutput(
              address: selection.coins.first.utxo.address,
              valueZatoshis: selection.changeZatoshis,
            ),
        ],
        spendParamsPath: spendParamsPath,
        outputParamsPath: outputParamsPath,
        allowExperimentalSaplingBuild: true,
        bindings: bindings,
      );
      transactionHex = built.transactionHex;
      txid = built.txid;
      fee = built.feeZatoshis;
      shielded = built.totalOutputZatoshis - selection.changeZatoshis;
  }

  if (fee != selection.feeZatoshis) {
    throw ShieldingException(
      ShieldingRefusal.planBuildMismatch,
      'the built transaction charges $fee zatoshis where the selection was '
      'priced at ${selection.feeZatoshis}; the quote and the build have '
      'diverged and neither number may be preferred over the other',
    );
  }
  if (shielded != selection.amountZatoshis) {
    throw ShieldingException(
      ShieldingRefusal.planBuildMismatch,
      'the built transaction shields $shielded zatoshis where the selection '
      'chose ${selection.amountZatoshis}',
    );
  }
  assert(
    !secrets.any((key) => key.isNotEmpty && transactionHex.contains(key)),
    'a signing key must never appear in a transaction artifact',
  );

  return ShieldingPreparedSend(
    destination: destination,
    selection: selection,
    transactionHex: transactionHex,
    txid: txid,
    feeZatoshis: fee,
    shieldedZatoshis: shielded,
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
