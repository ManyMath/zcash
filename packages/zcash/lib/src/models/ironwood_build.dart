import 'address.dart';
import 'spend.dart';

class IronwoodBuildResult {
  final ZcashAddressNetwork network;

  final String transactionHex;

  final String txid;

  final String version;

  final String consensusBranchId;

  final int expiryHeight;

  final int feeZatoshis;

  final String feeRule;

  final String proofValidity;

  final String ironwoodAnchor;

  final String ironwoodAnchorSource;

  final int? ironwoodAnchorTreeSize;

  final int vin;

  final int vout;

  final int saplingSpends;

  final int saplingOutputs;

  /// `1` for a ZIP 318 canonical migration, whose shape is already public.
  final int ironwoodActions;

  final int orchardSpends;

  final int orchardActions;

  final int orchardChangeOutputs;

  final int ironwoodSpends;

  final int ironwoodChangeOutputs;

  final bool zip318Canonical;

  final int totalInputZatoshis;

  final int transparentInputZatoshis;

  final int saplingInputZatoshis;

  final int orchardInputZatoshis;

  /// At most [orchardInputZatoshis]: ZIP 258 requires
  /// `valueBalanceOrchard >= 0`.
  final int orchardChangeZatoshis;

  final int ironwoodInputZatoshis;

  final int ironwoodChangeZatoshis;

  final int nonIronwoodOutputZatoshis;

  /// ZIP 315 user consent applies before a wallet reveals it.
  final int ironwoodOutputZatoshis;

  final String rng;

  const IronwoodBuildResult({
    required this.network,
    required this.transactionHex,
    required this.txid,
    required this.version,
    this.consensusBranchId = '',
    required this.expiryHeight,
    required this.feeZatoshis,
    required this.feeRule,
    required this.proofValidity,
    required this.ironwoodAnchor,
    required this.ironwoodAnchorSource,
    this.ironwoodAnchorTreeSize,
    required this.vin,
    required this.vout,
    this.saplingSpends = 0,
    this.saplingOutputs = 0,
    required this.ironwoodActions,
    this.orchardSpends = 0,
    this.orchardActions = 0,
    this.orchardChangeOutputs = 0,
    this.ironwoodSpends = 0,
    this.ironwoodChangeOutputs = 0,
    this.zip318Canonical = false,
    required this.totalInputZatoshis,
    this.transparentInputZatoshis = 0,
    this.saplingInputZatoshis = 0,
    this.orchardInputZatoshis = 0,
    this.orchardChangeZatoshis = 0,
    this.ironwoodInputZatoshis = 0,
    this.ironwoodChangeZatoshis = 0,
    required this.nonIronwoodOutputZatoshis,
    required this.ironwoodOutputZatoshis,
    required this.rng,
  });

  bool get isConsensusValid => proofValidity == 'real';

  bool get usedEmptyTreeAnchor =>
      ironwoodAnchorSource == 'tree' && ironwoodAnchorTreeSize == 0;

  bool get isDeterministic => rng == 'deterministic';

  bool get spendsSapling => saplingSpends > 0;

  bool get spendsOrchard => orchardSpends > 0;

  bool get keptOrchardChange => orchardChangeZatoshis > 0;

  bool get spendsIronwood => ironwoodSpends > 0;

  bool get keptIronwoodChange => ironwoodChangeZatoshis > 0;

  factory IronwoodBuildResult.fromJson(Map<String, Object?> json) {
    return IronwoodBuildResult(
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
      ironwoodAnchor: _require32ByteHex(
        json['ironwood_anchor'],
        'ironwood_anchor',
      ),
      ironwoodAnchorSource: json['ironwood_anchor_source'] as String? ?? '',
      ironwoodAnchorTreeSize: _optionalInt(json['ironwood_anchor_tree_size']),
      vin: _requireInt(_nested(json, 'transparent', 'vin'), 'transparent.vin'),
      vout: _requireInt(
        _nested(json, 'transparent', 'vout'),
        'transparent.vout',
      ),
      saplingSpends: _optionalInt(_nested(json, 'sapling', 'spends')) ?? 0,
      saplingOutputs: _optionalInt(_nested(json, 'sapling', 'outputs')) ?? 0,
      ironwoodActions: _requireInt(
        _nested(json, 'ironwood', 'actions'),
        'ironwood.actions',
      ),
      orchardSpends: _optionalInt(_nested(json, 'orchard', 'spends')) ?? 0,
      orchardActions: _optionalInt(_nested(json, 'orchard', 'actions')) ?? 0,
      orchardChangeOutputs:
          _optionalInt(_nested(json, 'orchard', 'change_outputs')) ?? 0,
      ironwoodSpends: _optionalInt(_nested(json, 'ironwood', 'spends')) ?? 0,
      ironwoodChangeOutputs:
          _optionalInt(_nested(json, 'ironwood', 'change_outputs')) ?? 0,
      zip318Canonical: json['zip318_canonical'] == true,
      totalInputZatoshis: _requireInt(
        json['total_input_zatoshis'],
        'total_input_zatoshis',
      ),
      transparentInputZatoshis:
          _optionalInt(json['transparent_input_zatoshis']) ?? 0,
      saplingInputZatoshis: _optionalInt(json['sapling_input_zatoshis']) ?? 0,
      orchardInputZatoshis: _optionalInt(json['orchard_input_zatoshis']) ?? 0,
      orchardChangeZatoshis: _optionalInt(json['orchard_change_zatoshis']) ?? 0,
      ironwoodInputZatoshis: _optionalInt(json['ironwood_input_zatoshis']) ?? 0,
      ironwoodChangeZatoshis:
          _optionalInt(json['ironwood_change_zatoshis']) ?? 0,
      nonIronwoodOutputZatoshis: _requireInt(
        json['non_ironwood_output_zatoshis'],
        'non_ironwood_output_zatoshis',
      ),
      ironwoodOutputZatoshis: _requireInt(
        json['ironwood_output_zatoshis'],
        'ironwood_output_zatoshis',
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

/// The builder's own ZIP 317 fee, which counts the padding.
class IronwoodFeeQuote {
  const IronwoodFeeQuote({
    required this.network,
    required this.feeZatoshis,
    required this.feeRule,
    required this.consensusBranchId,
    required this.totalInputZatoshis,
    required this.nonIronwoodOutputZatoshis,
    required this.maxIronwoodOutputZatoshis,
    required this.ironwoodSpends,
    required this.orchardSpends,
    required this.saplingSpends,
    required this.transparentInputs,
  });

  final ZcashAddressNetwork network;

  final int feeZatoshis;

  final String feeRule;

  final String consensusBranchId;

  final int totalInputZatoshis;

  final int nonIronwoodOutputZatoshis;

  final int? maxIronwoodOutputZatoshis;

  final int ironwoodSpends;
  final int orchardSpends;
  final int saplingSpends;
  final int transparentInputs;

  bool get isFunded => maxIronwoodOutputZatoshis != null;

  factory IronwoodFeeQuote.fromJson(Map<String, Object?> json) {
    if (json['quote_only'] != true) {
      throw ZcashModelException(
        'not an Ironwood fee quote; a build result carries a transaction and '
        'must be parsed as one',
      );
    }
    return IronwoodFeeQuote(
      network: ZcashAddressNetwork.fromJson(
        json['network'] as String? ?? 'mainnet',
      ),
      feeZatoshis: _requireInt(json['fee_zatoshis'], 'fee_zatoshis'),
      feeRule: json['fee_rule'] as String? ?? '',
      consensusBranchId: json['consensus_branch_id'] as String? ?? '',
      totalInputZatoshis: _requireInt(
        json['total_input_zatoshis'],
        'total_input_zatoshis',
      ),
      nonIronwoodOutputZatoshis: _requireInt(
        json['non_ironwood_output_zatoshis'],
        'non_ironwood_output_zatoshis',
      ),
      maxIronwoodOutputZatoshis: _optionalInt(
        json['max_ironwood_output_zatoshis'],
      ),
      ironwoodSpends: _requireInt(json['ironwood_spends'], 'ironwood_spends'),
      orchardSpends: _requireInt(json['orchard_spends'], 'orchard_spends'),
      saplingSpends: _requireInt(json['sapling_spends'], 'sapling_spends'),
      transparentInputs: _requireInt(
        json['transparent_inputs'],
        'transparent_inputs',
      ),
    );
  }
}

int _requireInt(Object? value, String field) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  throw ZcashModelException('ironwood build result $field must be an integer');
}

int? _optionalInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  throw ZcashModelException(
    'ironwood build result contains a non-integer numeric field',
  );
}

String _requireHex(Object? value, String field) {
  if (value is! String || value.isEmpty) {
    throw ZcashModelException('ironwood build result $field must be hex');
  }
  if (value.length.isOdd || !_isHex(value)) {
    throw ZcashModelException('ironwood build result $field is malformed');
  }
  return value;
}

String _require32ByteHex(Object? value, String field) {
  final hex = _requireHex(value, field);
  if (hex.length != 64) {
    throw ZcashModelException('ironwood build result $field must be 32 bytes');
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
