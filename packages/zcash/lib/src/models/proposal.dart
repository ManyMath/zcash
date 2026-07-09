import 'dart:convert';
import 'dart:typed_data';

import 'address.dart';
import 'spend.dart';

const int maxMoneyZatoshis = 21000000 * zatoshisPerZec;

/// ZIP 302's memo limit, which the ZIP 321 parser shares.
const int maxMemoLengthBytes = 512;

/// ZIP 302: at most [maxMemoLengthBytes], and only to a memo-capable output.
String? zcashMemoRefusalReason(
  Uint8List memo, {
  required bool recipientCanCarryMemo,
  String recipientDescription = 'recipient',
}) {
  if (memo.length > maxMemoLengthBytes) {
    return 'memo exceeds $maxMemoLengthBytes bytes: ${memo.length}';
  }
  if (!recipientCanCarryMemo) {
    return 'a memo cannot be delivered to a $recipientDescription';
  }
  return null;
}

/// Every transparent address, including ZIP 320 `tex`, starts with `t`.
bool zcashAddressIsTransparent(String address) =>
    address.startsWith('t') || address.startsWith('T');

enum ProposalOutputPool {
  transparent('transparent'),
  sapling('sapling'),
  orchard('orchard');

  const ProposalOutputPool(this.jsonValue);

  final String jsonValue;

  factory ProposalOutputPool.fromJson(String value) => switch (value) {
    'transparent' => ProposalOutputPool.transparent,
    'sapling' => ProposalOutputPool.sapling,
    'orchard' => ProposalOutputPool.orchard,
    _ => throw ZcashModelException('Unknown proposal output pool: $value'),
  };

  bool get isSendSupported => this != ProposalOutputPool.orchard;

  bool get supportsMemo => this != ProposalOutputPool.transparent;
}

enum ProposalFeeRule {
  zip317('zip317'),
  fixed('fixed');

  const ProposalFeeRule(this.jsonValue);

  final String jsonValue;

  factory ProposalFeeRule.fromJson(String value) => switch (value) {
    'zip317' => ProposalFeeRule.zip317,
    'fixed' => ProposalFeeRule.fixed,
    _ => throw ZcashModelException('Unknown proposal fee rule: $value'),
  };
}

class ProposalRecipient {
  final String address;

  final int amountZatoshis;

  final ProposalOutputPool pool;

  final Uint8List? memo;

  ProposalRecipient({
    required this.address,
    required this.amountZatoshis,
    this.pool = ProposalOutputPool.sapling,
    this.memo,
  }) {
    if (address.isEmpty) {
      throw const ZcashModelException('Recipient address cannot be empty');
    }
    if (amountZatoshis <= 0) {
      throw ZcashModelException(
        'Recipient amount must be positive zatoshis: $amountZatoshis',
      );
    }
    if (amountZatoshis > maxMoneyZatoshis) {
      throw ZcashModelException(
        'Recipient amount exceeds max money: $amountZatoshis',
      );
    }
    final memoBytes = memo;
    if (memoBytes != null) {
      final refusal = zcashMemoRefusalReason(
        memoBytes,
        recipientCanCarryMemo: pool.supportsMemo,
        recipientDescription: '${pool.jsonValue} recipient',
      );
      if (refusal != null) {
        throw ZcashModelException(refusal);
      }
    }
  }

  bool get isSendSupported => pool.isSendSupported;

  String? get memoHex {
    final memoBytes = memo;
    if (memoBytes == null) return null;
    final buffer = StringBuffer();
    for (final byte in memoBytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  factory ProposalRecipient.fromJson(Map<String, dynamic> json) {
    final memoHex = json['memo'];
    return ProposalRecipient(
      address: json['address'] as String? ?? '',
      amountZatoshis: zecJsonValueToZatoshis(
        json['amount'] ?? 0,
        field: 'amount',
      ),
      pool: json['pool'] == null
          ? ProposalOutputPool.sapling
          : ProposalOutputPool.fromJson(json['pool'] as String),
      memo: memoHex == null ? null : _decodeMemoHex(memoHex as String),
    );
  }

  Map<String, Object?> toJson() => {
    'address': address,
    'amount': zatoshisToZecJsonValue(amountZatoshis),
    'pool': pool.jsonValue,
    if (memoHex != null) 'memo': memoHex,
  };
}

class ProposalRequest {
  static const int schemaVersion = 1;

  final ZcashAddressNetwork network;
  final List<ProposalRecipient> recipients;
  final PrivacyPolicy privacyPolicy;
  final ProposalFeeRule feeRule;

  final int? fixedFeeZatoshis;

  final int minConfirmations;

  ProposalRequest({
    required this.network,
    required this.recipients,
    this.privacyPolicy = PrivacyPolicy.fullPrivacy,
    this.feeRule = ProposalFeeRule.zip317,
    this.fixedFeeZatoshis,
    this.minConfirmations = 10,
  }) {
    if (recipients.isEmpty) {
      throw const ZcashModelException(
        'Proposal must have at least one recipient',
      );
    }
    if (minConfirmations < 0) {
      throw ZcashModelException(
        'minConfirmations must be non-negative: $minConfirmations',
      );
    }
    if (feeRule == ProposalFeeRule.fixed) {
      final fee = fixedFeeZatoshis;
      if (fee == null) {
        throw const ZcashModelException(
          'fixed fee rule requires fixedFeeZatoshis',
        );
      }
      if (fee < 0 || fee > maxMoneyZatoshis) {
        throw ZcashModelException('fixedFeeZatoshis out of range: $fee');
      }
    } else if (fixedFeeZatoshis != null) {
      throw const ZcashModelException(
        'fixedFeeZatoshis is only valid with the fixed fee rule',
      );
    }
    final total = totalRecipientZatoshis;
    if (total > maxMoneyZatoshis) {
      throw ZcashModelException(
        'Total recipient amount exceeds max money: $total',
      );
    }
  }

  int get totalRecipientZatoshis =>
      recipients.fold(0, (sum, r) => sum + r.amountZatoshis);

  List<ProposalOutputPool> get unsupportedSendPools {
    final seen = <ProposalOutputPool>{};
    final result = <ProposalOutputPool>[];
    for (final r in recipients) {
      if (!r.isSendSupported && seen.add(r.pool)) {
        result.add(r.pool);
      }
    }
    return result;
  }

  bool get isSendSupported => unsupportedSendPools.isEmpty;

  factory ProposalRequest.fromJson(Map<String, dynamic> json) {
    final version = json['proposal_request_version'];
    if (version != null && version != schemaVersion) {
      throw ZcashModelException(
        'Unsupported proposal_request_version: $version',
      );
    }
    final rawRecipients = json['recipients'];
    if (rawRecipients is! List) {
      throw const ZcashModelException('Proposal recipients must be a list');
    }
    final feeRule = json['fee_rule'] == null
        ? ProposalFeeRule.zip317
        : ProposalFeeRule.fromJson(json['fee_rule'] as String);
    return ProposalRequest(
      network: ZcashAddressNetwork.fromJson(
        json['network'] as String? ?? 'mainnet',
      ),
      recipients: rawRecipients
          .map(
            (e) =>
                ProposalRecipient.fromJson(Map<String, dynamic>.from(e as Map)),
          )
          .toList(),
      privacyPolicy: json['privacy_policy'] == null
          ? PrivacyPolicy.fullPrivacy
          : PrivacyPolicy.fromRpcValue(json['privacy_policy'] as String),
      feeRule: feeRule,
      fixedFeeZatoshis: json['fixed_fee'] == null
          ? null
          : zecJsonValueToZatoshis(json['fixed_fee'], field: 'fixed_fee'),
      minConfirmations: (json['min_confirmations'] as num?)?.toInt() ?? 10,
    );
  }

  Map<String, Object?> toJson() => {
    'proposal_request_version': schemaVersion,
    'network': switch (network) {
      ZcashAddressNetwork.mainnet => 'mainnet',
      ZcashAddressNetwork.testnet => 'testnet',
      ZcashAddressNetwork.regtest => 'regtest',
    },
    'recipients': recipients.map((r) => r.toJson()).toList(),
    'privacy_policy': privacyPolicy.rpcValue,
    'fee_rule': feeRule.jsonValue,
    if (fixedFeeZatoshis != null)
      'fixed_fee': zatoshisToZecJsonValue(fixedFeeZatoshis!),
    'min_confirmations': minConfirmations,
  };

  String toJsonString() => jsonEncode(toJson());
}

Uint8List _decodeMemoHex(String hex) {
  if (hex.length.isOdd) {
    throw ZcashModelException('Recipient memo must be even-length hex');
  }
  final bytes = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < bytes.length; i++) {
    final byte = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    if (byte == null) {
      throw const ZcashModelException('Recipient memo must be valid hex');
    }
    bytes[i] = byte;
  }
  return bytes;
}
