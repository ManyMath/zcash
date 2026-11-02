import 'dart:convert';

import 'package:zcash/zcash.dart';

import 'transparent_build_request.dart';

const int saplingBuildRequestVersion = 1;

class SaplingBuildSpendNote {
  final int valueZatoshis;

  final String? recipientAddress;

  final String? rseedHex;

  final String? witnessHex;

  final String? anchorHex;

  const SaplingBuildSpendNote({
    required this.valueZatoshis,
    this.recipientAddress,
    this.rseedHex,
    this.witnessHex,
    this.anchorHex,
  });

  factory SaplingBuildSpendNote.fromScannedNote(
    ZcashScannedNote note, {
    required String anchorHex,
  }) {
    if (note.pool != 'sapling') {
      throw ArgumentError.value(
        note.pool,
        'note.pool',
        'a Sapling spend consumes a Sapling-pool note; the other pools have '
            'their own builders and their own nullifier spaces',
      );
    }
    final recipient = note.recipient;
    final rseed = note.rseed;
    final witness = note.witness;
    if (recipient == null || rseed == null || witness == null) {
      throw ArgumentError(
        'the scanned note is missing spend components (recipient, rseed, '
        'witness); rescan with includeSaplingWitnesses enabled, against a '
        'native library built with sapling-spend-build',
      );
    }
    return SaplingBuildSpendNote(
      valueZatoshis: note.value,
      recipientAddress: recipient,
      rseedHex: rseed,
      witnessHex: witness,
      anchorHex: anchorHex,
    );
  }

  bool get isRealNote =>
      recipientAddress != null ||
      rseedHex != null ||
      witnessHex != null ||
      anchorHex != null;

  Map<String, Object?> toRequestJson() {
    if (isRealNote &&
        (recipientAddress == null ||
            rseedHex == null ||
            witnessHex == null ||
            anchorHex == null)) {
      throw ArgumentError(
        'recipientAddress, rseedHex, witnessHex, and anchorHex must be '
        'supplied together for a real spend note',
      );
    }
    return {
      'value_zatoshis': valueZatoshis,
      if (recipientAddress != null) 'recipient': recipientAddress,
      if (rseedHex != null) 'rseed': rseedHex,
      if (witnessHex != null) 'witness': witnessHex,
      if (anchorHex != null) 'anchor': anchorHex,
    };
  }
}

class SaplingBuildOutput {
  final String address;

  final int? valueZatoshis;

  final String? memoHex;

  const SaplingBuildOutput({
    required this.address,
    this.valueZatoshis,
    this.memoHex,
  });

  Map<String, Object?> toRequestJson() => {
    'address': address,
    if (valueZatoshis != null) 'value_zatoshis': valueZatoshis,
    if (memoHex != null) 'memo': memoHex,
  };
}

/// Omitting [feeZatoshis] prices the transaction with ZIP 317.
String encodeSaplingBuildRequest({
  required String network,
  required int targetHeight,
  int? feeZatoshis,
  bool quoteOnly = false,
  required String seedHex,
  int account = 0,
  Iterable<SaplingBuildSpendNote> spendNotes = const [],
  Iterable<TransparentBuildInput> inputs = const [],
  required Iterable<SaplingBuildOutput> outputs,
  String? spendParamsPath,
  String? outputParamsPath,
  int? regtestNu63ActivationHeight,
  String? rngSeedHex,
}) {
  if ((spendParamsPath == null) != (outputParamsPath == null)) {
    throw ArgumentError(
      'spendParamsPath and outputParamsPath must be supplied together',
    );
  }
  return jsonEncode({
    'sapling_build_version': saplingBuildRequestVersion,
    'network': network,
    'target_height': targetHeight,
    'fee_zatoshis': ?feeZatoshis,
    if (quoteOnly) 'quote_only': true,
    'seed': seedHex,
    'account': account,
    'spend_notes': [for (final note in spendNotes) note.toRequestJson()],
    if (inputs.isNotEmpty)
      'inputs': [for (final input in inputs) input.toRequestJson()],
    'outputs': [for (final output in outputs) output.toRequestJson()],
    'regtest_nu63_activation_height': ?regtestNu63ActivationHeight,
    'rng_seed': ?rngSeedHex,
    'spend_params_path': ?spendParamsPath,
    'output_params_path': ?outputParamsPath,
  });
}
