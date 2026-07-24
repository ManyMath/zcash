import 'address.dart';
import 'spend.dart';

class SaplingBuildResult {
  final ZcashAddressNetwork network;

  final String transactionHex;

  final String txid;

  final String version;

  final String consensusBranchId;

  final int expiryHeight;

  final int feeZatoshis;

  final String proofValidity;

  final int transparentVin;

  final int transparentInputZatoshis;

  final int transparentVout;

  final int saplingSpends;

  final int saplingOutputs;

  final int totalSpentZatoshis;

  final int totalOutputZatoshis;

  bool get hasRealProofs => proofValidity == 'real';

  bool get isConsensusValid => hasRealProofs;

  const SaplingBuildResult({
    required this.network,
    required this.transactionHex,
    required this.txid,
    required this.version,
    this.consensusBranchId = '',
    required this.expiryHeight,
    required this.feeZatoshis,
    required this.proofValidity,
    required this.transparentVin,
    this.transparentInputZatoshis = 0,
    required this.transparentVout,
    required this.saplingSpends,
    required this.saplingOutputs,
    required this.totalSpentZatoshis,
    required this.totalOutputZatoshis,
  });

  factory SaplingBuildResult.fromJson(Map<String, Object?> json) {
    final transactionHex = _requireHex(json['transaction'], 'transaction');
    final txid = _require32ByteHex(json['txid'], 'txid');
    return SaplingBuildResult(
      network: ZcashAddressNetwork.fromJson(
        json['network'] as String? ?? 'mainnet',
      ),
      transactionHex: transactionHex,
      txid: txid,
      version: json['version'] as String? ?? '',
      consensusBranchId: json['consensus_branch_id'] as String? ?? '',
      expiryHeight: _requireInt(json['expiry_height'], 'expiry_height'),
      feeZatoshis: _requireInt(json['fee_zatoshis'], 'fee_zatoshis'),
      proofValidity: json['proof_validity'] as String? ?? 'placeholder',
      transparentVin: _requireInt(
        _nested(json, 'transparent', 'vin'),
        'transparent.vin',
      ),
      transparentInputZatoshis: _optionalInt(
        _nested(json, 'transparent', 'input_zatoshis'),
      ),
      transparentVout: _requireInt(
        _nested(json, 'transparent', 'vout'),
        'transparent.vout',
      ),
      saplingSpends: _requireInt(
        _nested(json, 'sapling', 'spends'),
        'sapling.spends',
      ),
      saplingOutputs: _requireInt(
        _nested(json, 'sapling', 'outputs'),
        'sapling.outputs',
      ),
      totalSpentZatoshis: _requireInt(
        json['total_spent_zatoshis'],
        'total_spent_zatoshis',
      ),
      totalOutputZatoshis: _requireInt(
        json['total_output_zatoshis'],
        'total_output_zatoshis',
      ),
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

int _optionalInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return 0;
}

int _requireInt(Object? value, String field) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  throw ZcashModelException('sapling build result $field must be an integer');
}

String _requireHex(Object? value, String field) {
  if (value is! String || value.isEmpty) {
    throw ZcashModelException('sapling build result $field must be hex');
  }
  if (value.length.isOdd || !_isHex(value)) {
    throw ZcashModelException('sapling build result $field is malformed');
  }
  return value;
}

String _require32ByteHex(Object? value, String field) {
  final hex = _requireHex(value, field);
  if (hex.length != 64) {
    throw ZcashModelException('sapling build result $field must be 32 bytes');
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

/// ZIP 317 prices the padded bundle: one Sapling output pays for two.
class SaplingFeeQuote {
  const SaplingFeeQuote({
    required this.network,
    required this.feeZatoshis,
    required this.feeRule,
    required this.consensusBranchId,
    required this.totalInputZatoshis,
    required this.statedOutputZatoshis,
    required this.maxOutputZatoshis,
    required this.saplingSpends,
    required this.transparentInputs,
    required this.outputs,
  });

  final ZcashAddressNetwork network;

  final int feeZatoshis;

  final String feeRule;

  final String consensusBranchId;

  final int totalInputZatoshis;

  final int statedOutputZatoshis;

  final int? maxOutputZatoshis;

  final int saplingSpends;
  final int transparentInputs;
  final int outputs;

  bool get isFunded => maxOutputZatoshis != null;

  factory SaplingFeeQuote.fromJson(Map<String, Object?> json) {
    if (json['quote_only'] != true) {
      throw ZcashModelException(
        'not a Sapling fee quote; a build result carries a transaction and '
        'must be parsed as one',
      );
    }
    return SaplingFeeQuote(
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
      statedOutputZatoshis: _requireInt(
        json['stated_output_zatoshis'],
        'stated_output_zatoshis',
      ),
      maxOutputZatoshis: json['max_output_zatoshis'] == null
          ? null
          : _requireInt(json['max_output_zatoshis'], 'max_output_zatoshis'),
      saplingSpends: _requireInt(json['sapling_spends'], 'sapling_spends'),
      transparentInputs: _requireInt(
        json['transparent_inputs'],
        'transparent_inputs',
      ),
      outputs: _requireInt(json['outputs'], 'outputs'),
    );
  }
}
