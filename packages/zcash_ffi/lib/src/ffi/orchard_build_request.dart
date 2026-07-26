import 'dart:convert';

import 'transparent_build_request.dart';

const int orchardBuildRequestVersion = 1;

/// ZIP 229: Ironwood reuses this Orchard receiver after NU6.3.
class OrchardBuildOutput {
  final String address;

  /// `null` shields the remainder after the ZIP 317 fee.
  final int? valueZatoshis;

  final String? memoHex;

  final String? outgoingViewingKeyHex;

  const OrchardBuildOutput({
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

class OrchardAnchorSource {
  final String? treeHex;

  final String? anchorHex;

  const OrchardAnchorSource.tree(String this.treeHex) : anchorHex = null;

  const OrchardAnchorSource.anchor(String this.anchorHex) : treeHex = null;

  Map<String, Object?> toRequestJson() => {
    if (treeHex != null) 'orchard_tree': treeHex,
    if (anchorHex != null) 'orchard_anchor': anchorHex,
  };
}

String encodeOrchardBuildRequest({
  required String network,
  required int targetHeight,
  required OrchardAnchorSource anchor,
  required Iterable<TransparentBuildInput> inputs,
  required OrchardBuildOutput orchardOutput,
  Iterable<TransparentBuildOutput> outputs = const [],
  int? expiryHeight,
  int? regtestNu63ActivationHeight,
  int? feeZatoshis,
  String? rngSeedHex,
}) {
  return jsonEncode({
    'orchard_build_version': orchardBuildRequestVersion,
    'network': network,
    'target_height': targetHeight,
    'expiry_height': ?expiryHeight,
    'regtest_nu63_activation_height': ?regtestNu63ActivationHeight,
    ...anchor.toRequestJson(),
    'fee_zatoshis': ?feeZatoshis,
    'rng_seed': ?rngSeedHex,
    'inputs': [for (final input in inputs) input.toRequestJson()],
    'outputs': [for (final output in outputs) output.toRequestJson()],
    'orchard_output': orchardOutput.toRequestJson(),
  });
}
