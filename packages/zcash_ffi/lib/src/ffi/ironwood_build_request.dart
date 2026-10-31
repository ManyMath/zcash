import 'dart:convert';

import 'package:zcash/zcash.dart';

import 'transparent_build_request.dart';

const int ironwoodBuildRequestVersion = 1;

class IronwoodBuildOutput {
  final String address;

  /// `null` shields the remainder after the ZIP 317 fee.
  final int? valueZatoshis;

  final String? memoHex;

  final String? outgoingViewingKeyHex;

  const IronwoodBuildOutput({
    required this.address,
    this.valueZatoshis,
    this.memoHex,
    this.outgoingViewingKeyHex,
  });

  Map<String, Object?> toRequestJson() => {
    'address': address,
    if (valueZatoshis != null) 'value_zatoshis': valueZatoshis,
    if (memoHex != null) 'memo': memoHex,
    if (outgoingViewingKeyHex != null)
      'outgoing_viewing_key': outgoingViewingKeyHex,
  };
}

class IronwoodAnchorSource {
  final String? treeHex;

  final String? anchorHex;

  const IronwoodAnchorSource.tree(String this.treeHex) : anchorHex = null;

  const IronwoodAnchorSource.anchor(String this.anchorHex) : treeHex = null;

  Map<String, Object?> toRequestJson() => {
    if (treeHex != null) 'ironwood_tree': treeHex,
    if (anchorHex != null) 'ironwood_anchor': anchorHex,
  };
}

class IronwoodBuildSpendNote {
  final int valueZatoshis;

  final String recipientAddress;

  final String rseedHex;

  final String witnessHex;

  final String anchorHex;

  const IronwoodBuildSpendNote({
    required this.valueZatoshis,
    required this.recipientAddress,
    required this.rseedHex,
    required this.witnessHex,
    required this.anchorHex,
  });

  Map<String, Object?> toRequestJson() => {
    'value_zatoshis': valueZatoshis,
    'recipient': recipientAddress,
    'rseed': rseedHex,
    'witness': witnessHex,
    'anchor': anchorHex,
  };
}

class IronwoodBuildOrchardSpendNote {
  final int valueZatoshis;

  final String recipientAddress;

  final String rseedHex;

  final String rhoHex;

  final String noteVersion;

  final String witnessHex;

  final String anchorHex;

  const IronwoodBuildOrchardSpendNote({
    required this.valueZatoshis,
    required this.recipientAddress,
    required this.rseedHex,
    required this.rhoHex,
    required this.witnessHex,
    required this.anchorHex,
    this.noteVersion = 'v2',
  });

  factory IronwoodBuildOrchardSpendNote.fromScannedNote(
    ZcashScannedNote note, {
    required String anchorHex,
  }) {
    if (note.pool != 'orchard') {
      throw ArgumentError.value(
        note.pool,
        'note.pool',
        'a ZIP 318 migration spends an Orchard-pool note; an Ironwood note is '
            'already in the destination pool',
      );
    }
    final recipient = note.recipient;
    final rseed = note.rseed;
    final rho = note.rho;
    final witness = note.witness;
    if (recipient == null ||
        rseed == null ||
        rho == null ||
        witness == null ||
        note.noteVersion == null) {
      throw ArgumentError(
        'the scanned note is missing spend components (recipient, rseed, rho, '
        'note version, witness); rescan with includeOrchardWitnesses enabled. '
        'rho in particular is not recoverable from anything else the scanner '
        'exports',
      );
    }
    return IronwoodBuildOrchardSpendNote(
      valueZatoshis: note.value,
      recipientAddress: recipient,
      rseedHex: rseed,
      rhoHex: rho,
      noteVersion: note.noteVersion!,
      witnessHex: witness,
      anchorHex: anchorHex,
    );
  }

  Map<String, Object?> toRequestJson() => {
    'value_zatoshis': valueZatoshis,
    'recipient': recipientAddress,
    'rseed': rseedHex,
    'rho': rhoHex,
    'note_version': noteVersion,
    'witness': witnessHex,
    'anchor': anchorHex,
  };
}

/// [noteVersion] is `'v3'`, the ZIP 2005 note plaintext.
class IronwoodBuildIronwoodSpendNote {
  final int valueZatoshis;

  final String recipientAddress;

  final String rseedHex;

  final String rhoHex;

  final String noteVersion;

  final String witnessHex;

  final String anchorHex;

  const IronwoodBuildIronwoodSpendNote({
    required this.valueZatoshis,
    required this.recipientAddress,
    required this.rseedHex,
    required this.rhoHex,
    required this.witnessHex,
    required this.anchorHex,
    this.noteVersion = 'v3',
  });

  factory IronwoodBuildIronwoodSpendNote.fromScannedNote(
    ZcashScannedNote note, {
    required String anchorHex,
  }) {
    if (note.pool != 'ironwood') {
      throw ArgumentError.value(
        note.pool,
        'note.pool',
        'this spends an Ironwood-pool note; an Orchard note leaves its pool '
            'only through a ZIP 318 migration (orchardSpends)',
      );
    }
    final recipient = note.recipient;
    final rseed = note.rseed;
    final rho = note.rho;
    final witness = note.witness;
    if (recipient == null ||
        rseed == null ||
        rho == null ||
        witness == null ||
        note.noteVersion == null) {
      throw ArgumentError(
        'the scanned note is missing spend components (recipient, rseed, rho, '
        'note version, witness); rescan with includeOrchardWitnesses enabled. '
        'rho in particular is not recoverable from anything else the scanner '
        'exports',
      );
    }
    return IronwoodBuildIronwoodSpendNote(
      valueZatoshis: note.value,
      recipientAddress: recipient,
      rseedHex: rseed,
      rhoHex: rho,
      noteVersion: note.noteVersion!,
      witnessHex: witness,
      anchorHex: anchorHex,
    );
  }

  Map<String, Object?> toRequestJson() => {
    'value_zatoshis': valueZatoshis,
    'recipient': recipientAddress,
    'rseed': rseedHex,
    'rho': rhoHex,
    'note_version': noteVersion,
    'witness': witnessHex,
    'anchor': anchorHex,
  };
}

/// A non-empty [orchardSpends] selects the ZIP 318 canonical migration shape.
String encodeIronwoodBuildRequest({
  required String network,
  required int targetHeight,
  required IronwoodAnchorSource anchor,
  required Iterable<TransparentBuildInput> inputs,
  required IronwoodBuildOutput ironwoodOutput,
  Iterable<TransparentBuildOutput> outputs = const [],
  Iterable<IronwoodBuildSpendNote> saplingSpends = const [],
  Iterable<IronwoodBuildOrchardSpendNote> orchardSpends = const [],
  Iterable<IronwoodBuildIronwoodSpendNote> ironwoodSpends = const [],
  int? orchardChangeZatoshis,
  int? ironwoodChangeZatoshis,
  int? expiryHeight,
  int? regtestNu63ActivationHeight,
  int? currentUnixTime,
  String? seedHex,
  int account = 0,
  String? spendParamsPath,
  String? outputParamsPath,
  int? feeZatoshis,
  String? rngSeedHex,
  bool quoteOnly = false,
}) {
  final spends = [for (final note in saplingSpends) note.toRequestJson()];
  final orchard = [for (final note in orchardSpends) note.toRequestJson()];
  final ironwood = [for (final note in ironwoodSpends) note.toRequestJson()];
  return jsonEncode({
    'ironwood_build_version': ironwoodBuildRequestVersion,
    'network': network,
    'target_height': targetHeight,
    'expiry_height': ?expiryHeight,
    'regtest_nu63_activation_height': ?regtestNu63ActivationHeight,
    'current_unix_time': ?currentUnixTime,
    ...anchor.toRequestJson(),
    'fee_zatoshis': ?feeZatoshis,
    'rng_seed': ?rngSeedHex,
    'inputs': [for (final input in inputs) input.toRequestJson()],
    'outputs': [for (final output in outputs) output.toRequestJson()],
    if (spends.isNotEmpty) 'sapling_spends': spends,
    if (orchard.isNotEmpty) 'orchard_spends': orchard,
    if (ironwood.isNotEmpty) 'ironwood_spends': ironwood,
    'orchard_change_zatoshis': ?orchardChangeZatoshis,
    'ironwood_change_zatoshis': ?ironwoodChangeZatoshis,
    'seed': ?seedHex,
    if (seedHex != null) 'account': account,
    'spend_params_path': ?spendParamsPath,
    'output_params_path': ?outputParamsPath,
    if (quoteOnly) 'quote_only': true,
    'ironwood_output': ironwoodOutput.toRequestJson(),
  });
}

String encodeZip318MigrationRequest({
  required String network,
  required Zip318TransferPlan plan,
  required String seedHex,
  int account = 0,
  String? rngSeedHex,
  int? currentUnixTime,
}) {
  final consensus = ZcashConsensusNetwork.fromJson(network);
  if (consensus != ZcashConsensusNetwork.regtest &&
      plan.parameters.nu7ActivationHeight !=
          Zip318Parameters.forNetwork(consensus).nu7ActivationHeight) {
    throw ArgumentError.value(
      network,
      'network',
      'the ZIP 318 plan was scheduled with NU7 at height '
          '${plan.parameters.nu7ActivationHeight}, which is not this '
          "network's NU7 height",
    );
  }
  return encodeIronwoodBuildRequest(
    network: network,
    targetHeight: plan.targetHeight,
    expiryHeight: plan.expiryHeight,
    anchor: IronwoodAnchorSource.anchor(plan.ironwoodAnchorHex),
    inputs: const [],
    orchardSpends: [
      IronwoodBuildOrchardSpendNote.fromScannedNote(
        plan.funding.note,
        anchorHex: plan.orchardAnchorHex,
      ),
    ],
    orchardChangeZatoshis: plan.orchardChangeZatoshis,
    seedHex: seedHex,
    account: account,
    rngSeedHex: rngSeedHex,
    currentUnixTime: currentUnixTime,
    ironwoodOutput: IronwoodBuildOutput(
      address: plan.recipientAddress,
      valueZatoshis: plan.ironwoodOutputZatoshis,
    ),
  );
}
