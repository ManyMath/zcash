import 'dart:convert';

const int transparentBuildRequestVersion = 1;

class TransparentBuildInput {
  final String txid;

  final int vout;

  final int valueZatoshis;

  final String secretKeyHex;

  const TransparentBuildInput({
    required this.txid,
    required this.vout,
    required this.valueZatoshis,
    required this.secretKeyHex,
  });

  Map<String, Object?> toRequestJson() => {
    'txid': txid,
    'vout': vout,
    'value_zatoshis': valueZatoshis,
    'secret_key': secretKeyHex,
  };
}

class TransparentBuildOutput {
  final String address;

  final int valueZatoshis;

  const TransparentBuildOutput({
    required this.address,
    required this.valueZatoshis,
  });

  Map<String, Object?> toRequestJson() => {
    'address': address,
    'value_zatoshis': valueZatoshis,
  };
}

String encodeTransparentBuildRequest({
  required String network,
  required int targetHeight,
  required int feeZatoshis,
  required Iterable<TransparentBuildInput> inputs,
  required Iterable<TransparentBuildOutput> outputs,
}) {
  return jsonEncode({
    'transparent_build_version': transparentBuildRequestVersion,
    'network': network,
    'target_height': targetHeight,
    'fee_zatoshis': feeZatoshis,
    'inputs': [for (final input in inputs) input.toRequestJson()],
    'outputs': [for (final output in outputs) output.toRequestJson()],
  });
}
