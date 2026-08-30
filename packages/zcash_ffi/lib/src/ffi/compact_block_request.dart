import 'dart:convert';

const int compactBlockRequestVersion = 1;

String encodeCompactBlockRequest({
  required String network,
  required Iterable<String> rawBlockHex,
  int priorSaplingSize = 0,
  int priorOrchardSize = 0,
  int priorIronwoodSize = 0,
  int? regtestNu63ActivationHeight,
}) {
  return jsonEncode({
    'compact_block_version': compactBlockRequestVersion,
    'network': network,
    'regtest_nu63_activation_height': ?regtestNu63ActivationHeight,
    'prior_sapling_size': priorSaplingSize,
    'prior_orchard_size': priorOrchardSize,
    'prior_ironwood_size': priorIronwoodSize,
    'blocks': [for (final block in rawBlockHex) block],
  });
}
