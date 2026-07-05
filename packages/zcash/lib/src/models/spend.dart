class ZcashModelException implements Exception {
  final String message;

  const ZcashModelException(this.message);

  @override
  String toString() => 'ZcashModelException: $message';
}

enum PrivacyPolicy {
  fullPrivacy('FullPrivacy'),
  allowRevealedAmounts('AllowRevealedAmounts'),
  allowRevealedRecipients('AllowRevealedRecipients'),
  allowRevealedSenders('AllowRevealedSenders'),
  allowRevealedAmountsAndRecipients('AllowRevealedAmountsAndRecipients'),
  allowRevealedAmountsAndSenders('AllowRevealedAmountsAndSenders'),
  allowRevealedSendersAndRecipients('AllowRevealedSendersAndRecipients'),
  allowFullyTransparent('AllowFullyTransparent'),
  allowLinkingAccountAddresses('AllowLinkingAccountAddresses');

  final String rpcValue;

  const PrivacyPolicy(this.rpcValue);

  static PrivacyPolicy fromRpcValue(String value) {
    for (final policy in PrivacyPolicy.values) {
      if (policy.rpcValue == value) return policy;
    }
    throw ZcashModelException('Unknown privacy policy: $value');
  }
}

String zatoshisToZecString(int zatoshis) {
  if (zatoshis < 0) {
    throw ZcashModelException('ZEC amount cannot be negative: $zatoshis');
  }
  final whole = zatoshis ~/ zatoshisPerZec;
  final fractional = zatoshis
      .remainder(zatoshisPerZec)
      .toString()
      .padLeft(8, '0');
  return '$whole.$fractional';
}

String zatoshisToZecJsonValue(int zatoshis) => zatoshisToZecString(zatoshis);

int zecJsonValueToZatoshis(Object? value, {String field = 'amount'}) {
  if (value is int) return value * zatoshisPerZec;
  if (value is num) return _parseZecDecimal(value.toString(), field: field);
  if (value is String) return _parseZecDecimal(value, field: field);
  throw ZcashModelException(
    'Expected $field to be a ZEC number/string, got ${value.runtimeType}',
  );
}

const int zatoshisPerZec = 100000000;

int _parseZecDecimal(String value, {required String field}) {
  final match = RegExp(r'^(\d+)(?:\.(\d{1,8}))?$').firstMatch(value);
  if (match == null) {
    throw ZcashModelException('Invalid $field ZEC decimal: $value');
  }
  final whole = int.parse(match.group(1)!);
  final fractional = (match.group(2) ?? '').padRight(8, '0');
  return whole * zatoshisPerZec + int.parse(fractional);
}

class ZSendRecipient {
  final String address;
  final int amountZatoshis;
  final String? memoHex;
  final bool? subtractFeeFromAmount;

  ZSendRecipient({
    required this.address,
    required this.amountZatoshis,
    this.memoHex,
    this.subtractFeeFromAmount,
  }) {
    if (address.isEmpty) {
      throw const ZcashModelException('Recipient address cannot be empty');
    }
    if (amountZatoshis <= 0) {
      throw ZcashModelException(
        'Recipient amount must be positive zatoshis: $amountZatoshis',
      );
    }
    if (memoHex != null && !_isEvenLengthHex(memoHex!)) {
      throw ZcashModelException(
        'Recipient memo must be even-length hex: $memoHex',
      );
    }
  }

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'address': address,
      'amount': zatoshisToZecJsonValue(amountZatoshis),
    };
    if (memoHex != null) json['memo'] = memoHex;
    if (subtractFeeFromAmount != null) {
      json['subtractFeeFromAmount'] = subtractFeeFromAmount;
    }
    return json;
  }
}

bool _isEvenLengthHex(String value) {
  if (value.length.isOdd) return false;
  return RegExp(r'^[0-9a-fA-F]*$').hasMatch(value);
}

String _safePrefix(String value) {
  final end = value.length < 12 ? value.length : 12;
  return '${value.substring(0, end)}…(${value.length} chars)';
}

String? _optionalStringFromAny(
  Map<String, dynamic> json,
  List<String> keys,
  String context,
) {
  for (final key in keys) {
    if (!json.containsKey(key) || json[key] == null) continue;
    final value = json[key];
    if (value is String && value.isNotEmpty) return value;
    throw ZcashModelException('$context result field $key must be a string');
  }
  return null;
}

bool? _optionalBoolFromAny(
  Map<String, dynamic> json,
  List<String> keys,
  String context,
) {
  for (final key in keys) {
    if (!json.containsKey(key) || json[key] == null) continue;
    final value = json[key];
    if (value is bool) return value;
    throw ZcashModelException('$context result field $key must be a bool');
  }
  return null;
}

class ShieldCoinbaseResult {
  final String operationId;
  final int? remainingUtxos;
  final int? remainingValueZatoshis;
  final int? shieldingUtxos;
  final int? shieldingValueZatoshis;

  const ShieldCoinbaseResult({
    required this.operationId,
    this.remainingUtxos,
    this.remainingValueZatoshis,
    this.shieldingUtxos,
    this.shieldingValueZatoshis,
  });

  factory ShieldCoinbaseResult.fromJson(Map<String, dynamic> json) {
    final opid = json['opid'];
    if (opid is! String || opid.isEmpty) {
      throw const ZcashModelException('z_shieldcoinbase result missing opid');
    }
    return ShieldCoinbaseResult(
      operationId: opid,
      remainingUtxos: _optionalInt(json['remainingUTXOs'], 'remainingUTXOs'),
      remainingValueZatoshis: _optionalZecAmount(
        json['remainingValue'],
        'remainingValue',
      ),
      shieldingUtxos: _optionalInt(json['shieldingUTXOs'], 'shieldingUTXOs'),
      shieldingValueZatoshis: _optionalZecAmount(
        json['shieldingValue'],
        'shieldingValue',
      ),
    );
  }
}

class ZImportKeyResult {
  final String responseShape;
  final String? address;
  final String? keyType;
  final String? message;
  final bool? imported;

  const ZImportKeyResult({
    required this.responseShape,
    this.address,
    this.keyType,
    this.message,
    this.imported,
  });

  factory ZImportKeyResult.fromRpcResult(Object? value) {
    if (value == null) {
      return const ZImportKeyResult(responseShape: 'null');
    }
    if (value is String) {
      return ZImportKeyResult(
        responseShape: value.isEmpty ? 'empty-string' : 'string',
        message: value,
      );
    }
    if (value is bool) {
      return ZImportKeyResult(
        responseShape: 'bool',
        imported: value,
        message: value.toString(),
      );
    }
    if (value is num) {
      return ZImportKeyResult(
        responseShape: 'number',
        message: value.toString(),
      );
    }
    if (value is Map) {
      final json = Map<String, dynamic>.from(value);
      final address = _optionalStringFromAny(json, const [
        'address',
        'addr',
      ], 'z_importkey');
      final keyType = _optionalStringFromAny(json, const [
        'address_type',
        'type',
        'key_type',
        'keyType',
      ], 'z_importkey');
      final message = _optionalStringFromAny(json, const [
        'message',
        'result',
      ], 'z_importkey');
      final imported = _optionalBoolFromAny(json, const [
        'imported',
        'success',
      ], 'z_importkey');
      if (address == null && keyType == null) {
        final fields = json.keys.map((key) => key.toString()).toList()..sort();
        throw ZcashModelException(
          'z_importkey result object missing address/type fields; fields=$fields',
        );
      }
      if (keyType != null && !keyType.toLowerCase().contains('sapling')) {
        throw ZcashModelException(
          'z_importkey result type did not confirm Sapling import: $keyType',
        );
      }
      return ZImportKeyResult(
        responseShape: 'object',
        address: address,
        keyType: keyType,
        message: message,
        imported: imported,
      );
    }
    throw ZcashModelException(
      'Unsupported z_importkey result type: ${value.runtimeType}',
    );
  }

  String get safeSummary {
    final parts = <String>['shape=$responseShape'];
    if (keyType != null) parts.add('type=$keyType');
    if (address != null) parts.add('addressPrefix=${_safePrefix(address!)}');
    if (imported != null) parts.add('imported=$imported');
    if (message != null && message!.isNotEmpty) parts.add('message=$message');
    return parts.join(',');
  }
}

class ZcashOperationStatus {
  final String operationId;
  final String status;
  final String? method;
  final int? creationTime;
  final double? executionSeconds;
  final Map<String, dynamic>? error;
  final Map<String, dynamic>? result;

  const ZcashOperationStatus({
    required this.operationId,
    required this.status,
    this.method,
    this.creationTime,
    this.executionSeconds,
    this.error,
    this.result,
  });

  factory ZcashOperationStatus.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final status = json['status'];
    if (id is! String || id.isEmpty) {
      throw const ZcashModelException('operation status missing id');
    }
    if (status is! String || status.isEmpty) {
      throw ZcashModelException('operation $id missing status');
    }
    return ZcashOperationStatus(
      operationId: id,
      status: status,
      method: json['method'] as String?,
      creationTime: _optionalInt(json['creation_time'], 'creation_time'),
      executionSeconds: json['execution_secs'] != null
          ? (json['execution_secs'] as num).toDouble()
          : null,
      error: json['error'] != null
          ? Map<String, dynamic>.from(json['error'] as Map)
          : null,
      result: json['result'] != null
          ? Map<String, dynamic>.from(json['result'] as Map)
          : null,
    );
  }

  bool get isSuccess => status == 'success';

  bool get isFailed => status == 'failed' || status == 'cancelled';

  String? get txid {
    final value = result?['txid'];
    return value is String ? value : null;
  }

  String? get errorMessage {
    final value = error?['message'] ?? error?['error'];
    return value is String ? value : null;
  }
}

int? _optionalInt(Object? value, String field) {
  if (value == null) return null;
  if (value is num) return value.toInt();
  throw ZcashModelException(
    'Expected $field to be numeric, got ${value.runtimeType}',
  );
}

int? _optionalZecAmount(Object? value, String field) {
  if (value == null) return null;
  return zecJsonValueToZatoshis(value, field: field);
}

class ZcashTotalBalance {
  final int transparentZatoshis;
  final int privateZatoshis;
  final int totalZatoshis;

  const ZcashTotalBalance({
    required this.transparentZatoshis,
    required this.privateZatoshis,
    required this.totalZatoshis,
  });

  factory ZcashTotalBalance.fromJson(Map<String, dynamic> json) {
    return ZcashTotalBalance(
      transparentZatoshis: zecJsonValueToZatoshis(
        json['transparent'] ?? 0,
        field: 'transparent',
      ),
      privateZatoshis: zecJsonValueToZatoshis(
        json['private'] ?? 0,
        field: 'private',
      ),
      totalZatoshis: zecJsonValueToZatoshis(json['total'] ?? 0, field: 'total'),
    );
  }
}
