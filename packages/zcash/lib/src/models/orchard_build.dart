import 'address.dart';
import 'spend.dart';

/// ZIP 258 closes Orchard at NU6.3, so this only makes notes for ZIP 318
/// migrations before then.
class OrchardBuildResult {
  final ZcashAddressNetwork network;

  final String transactionHex;

  final String txid;

  final String version;

  final String consensusBranchId;

  final int expiryHeight;

  final int feeZatoshis;

  final String feeRule;

  final String proofValidity;

  final String orchardAnchor;

  final String orchardAnchorSource;

  final int? orchardAnchorTreeSize;

  final int vin;

  final int vout;

  /// The unpadded single-action shape is for ZIP 318 canonical migrations.
  final int orchardActions;

  final int totalInputZatoshis;

  final int nonOrchardOutputZatoshis;

  /// ZIP 315 user consent applies before a wallet reveals it.
  final int orchardOutputZatoshis;

  final String rng;

  const OrchardBuildResult({
    required this.network,
    required this.transactionHex,
    required this.txid,
    required this.version,
    this.consensusBranchId = '',
    required this.expiryHeight,
    required this.feeZatoshis,
    required this.feeRule,
    required this.proofValidity,
    required this.orchardAnchor,
    required this.orchardAnchorSource,
    this.orchardAnchorTreeSize,
    required this.vin,
    required this.vout,
    required this.orchardActions,
    required this.totalInputZatoshis,
    required this.nonOrchardOutputZatoshis,
    required this.orchardOutputZatoshis,
    required this.rng,
  });

  bool get isConsensusValid => proofValidity == 'real';

  bool get usedEmptyTreeAnchor =>
      orchardAnchorSource == 'tree' && orchardAnchorTreeSize == 0;

  bool get isDeterministic => rng == 'deterministic';

  factory OrchardBuildResult.fromJson(Map<String, Object?> json) {
    return OrchardBuildResult(
      network: ZcashAddressNetwork.fromJson(
        json['network'] as String? ?? 'mainnet',
      ),
      transactionHex: _requireHex(json['transaction'], 'transaction'),
      txid: _require32ByteHex(json['txid'], 'txid'),
      version: json['version'] as String? ?? '',
      consensusBranchId: json['consensus_branch_id'] as String? ?? '',
      expiryHeight: _requireInt(json['expiry_height'], 'expiry_height'),
      feeZatoshis: _requireInt(json['fee_zatoshis'], 'fee_zatoshis'),
      feeRule: json['fee_rule'] as String? ?? '',
      proofValidity: json['proof_validity'] as String? ?? '',
      orchardAnchor: _require32ByteHex(
        json['orchard_anchor'],
        'orchard_anchor',
      ),
      orchardAnchorSource: json['orchard_anchor_source'] as String? ?? '',
      orchardAnchorTreeSize: _optionalInt(json['orchard_anchor_tree_size']),
      vin: _requireInt(_nested(json, 'transparent', 'vin'), 'transparent.vin'),
      vout: _requireInt(
        _nested(json, 'transparent', 'vout'),
        'transparent.vout',
      ),
      orchardActions: _requireInt(
        _nested(json, 'orchard', 'actions'),
        'orchard.actions',
      ),
      totalInputZatoshis: _requireInt(
        json['total_input_zatoshis'],
        'total_input_zatoshis',
      ),
      nonOrchardOutputZatoshis: _requireInt(
        json['non_orchard_output_zatoshis'],
        'non_orchard_output_zatoshis',
      ),
      orchardOutputZatoshis: _requireInt(
        json['orchard_output_zatoshis'],
        'orchard_output_zatoshis',
      ),
      rng: json['rng'] as String? ?? '',
    );
  }
}

Object? _nested(Map<String, Object?> json, String outer, String inner) {
  final value = json[outer];
  if (value is Map) {
    return value[inner];
  }
  return null;
}

int _requireInt(Object? value, String field) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  throw ZcashModelException('orchard build result $field must be an integer');
}

int? _optionalInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  throw ZcashModelException(
    'orchard build result contains a non-integer numeric field',
  );
}

String _requireHex(Object? value, String field) {
  if (value is! String || value.isEmpty) {
    throw ZcashModelException('orchard build result $field must be hex');
  }
  if (value.length.isOdd || !_isHex(value)) {
    throw ZcashModelException('orchard build result $field is malformed');
  }
  return value;
}

String _require32ByteHex(Object? value, String field) {
  final hex = _requireHex(value, field);
  if (hex.length != 64) {
    throw ZcashModelException('orchard build result $field must be 32 bytes');
  }
  return hex;
}

bool _isHex(String value) {
  for (final unit in value.codeUnits) {
    final isDigit = unit >= 0x30 && unit <= 0x39;
    final isLower = unit >= 0x61 && unit <= 0x66;
    final isUpper = unit >= 0x41 && unit <= 0x46;
    if (!isDigit && !isLower && !isUpper) return false;
  }
  return true;
}
