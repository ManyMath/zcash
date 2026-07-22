import 'address.dart';
import 'spend.dart';

class TransparentBuildResult {
  final ZcashAddressNetwork network;

  final String transactionHex;

  final String txid;

  final String version;

  final int expiryHeight;

  final int feeZatoshis;

  final int vin;

  final int vout;

  final int totalInputZatoshis;

  final int totalOutputZatoshis;

  const TransparentBuildResult({
    required this.network,
    required this.transactionHex,
    required this.txid,
    required this.version,
    required this.expiryHeight,
    required this.feeZatoshis,
    required this.vin,
    required this.vout,
    required this.totalInputZatoshis,
    required this.totalOutputZatoshis,
  });

  factory TransparentBuildResult.fromJson(Map<String, Object?> json) {
    final transactionHex = _requireHex(json['transaction'], 'transaction');
    final txid = _require32ByteHex(json['txid'], 'txid');
    return TransparentBuildResult(
      network: ZcashAddressNetwork.fromJson(
        json['network'] as String? ?? 'mainnet',
      ),
      transactionHex: transactionHex,
      txid: txid,
      version: json['version'] as String? ?? '',
      expiryHeight: _requireInt(json['expiry_height'], 'expiry_height'),
      feeZatoshis: _requireInt(json['fee_zatoshis'], 'fee_zatoshis'),
      vin: _requireInt(_nested(json, 'transparent', 'vin'), 'transparent.vin'),
      vout: _requireInt(
        _nested(json, 'transparent', 'vout'),
        'transparent.vout',
      ),
      totalInputZatoshis: _requireInt(
        json['total_input_zatoshis'],
        'total_input_zatoshis',
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

int _requireInt(Object? value, String field) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  throw ZcashModelException(
    'transparent build result $field must be an integer',
  );
}

String _requireHex(Object? value, String field) {
  if (value is! String || value.isEmpty) {
    throw ZcashModelException('transparent build result $field must be hex');
  }
  if (value.length.isOdd || !_isHex(value)) {
    throw ZcashModelException('transparent build result $field is malformed');
  }
  return value;
}

String _require32ByteHex(Object? value, String field) {
  final hex = _requireHex(value, field);
  if (hex.length != 64) {
    throw ZcashModelException(
      'transparent build result $field must be 32 bytes',
    );
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
