import 'address.dart';

class TransactionInfo {
  final String txid;
  final String hex;
  final int? height;
  final String? blockHash;
  final int? confirmations;
  final int? time;

  const TransactionInfo({
    required this.txid,
    required this.hex,
    this.height,
    this.blockHash,
    this.confirmations,
    this.time,
  });

  factory TransactionInfo.fromJson(Map<String, dynamic> json) =>
      TransactionInfo(
        txid: json['txid'] as String,
        hex: json['hex'] as String,
        height: json['height'] != null ? (json['height'] as num).toInt() : null,
        blockHash: json['blockhash'] as String?,
        confirmations: json['confirmations'] != null
            ? (json['confirmations'] as num).toInt()
            : null,
        time: json['time'] != null ? (json['time'] as num).toInt() : null,
      );

  bool get isMined => blockHash != null;

  @override
  String toString() =>
      'TransactionInfo(txid: $txid, height: $height, '
      'confirmations: $confirmations)';
}

enum ZcashTransactionVersion {
  sprout,
  v3,
  v4,
  v5,

  /// ZIP 229, added by NU6.3.
  v6;

  String get label => switch (this) {
    ZcashTransactionVersion.sprout => 'sprout',
    ZcashTransactionVersion.v3 => 'v3',
    ZcashTransactionVersion.v4 => 'v4',
    ZcashTransactionVersion.v5 => 'v5',
    ZcashTransactionVersion.v6 => 'v6',
  };

  factory ZcashTransactionVersion.fromJson(String value) => switch (value) {
    'sprout' => ZcashTransactionVersion.sprout,
    'v3' => ZcashTransactionVersion.v3,
    'v4' => ZcashTransactionVersion.v4,
    'v5' => ZcashTransactionVersion.v5,
    'v6' => ZcashTransactionVersion.v6,
    _ => throw FormatException('Unknown transaction version: $value'),
  };
}

class ZcashTransparentBundleSummary {
  final bool present;
  final int vin;
  final int vout;

  const ZcashTransparentBundleSummary({
    required this.present,
    required this.vin,
    required this.vout,
  });

  factory ZcashTransparentBundleSummary.fromJson(Map<String, dynamic> json) =>
      ZcashTransparentBundleSummary(
        present: json['present'] as bool? ?? false,
        vin: (json['vin'] as num?)?.toInt() ?? 0,
        vout: (json['vout'] as num?)?.toInt() ?? 0,
      );

  Map<String, Object?> toJson() => {
    'present': present,
    'vin': vin,
    'vout': vout,
  };
}

class ZcashSaplingBundleSummary {
  final bool present;
  final int spends;
  final int outputs;

  const ZcashSaplingBundleSummary({
    required this.present,
    required this.spends,
    required this.outputs,
  });

  factory ZcashSaplingBundleSummary.fromJson(Map<String, dynamic> json) =>
      ZcashSaplingBundleSummary(
        present: json['present'] as bool? ?? false,
        spends: (json['spends'] as num?)?.toInt() ?? 0,
        outputs: (json['outputs'] as num?)?.toInt() ?? 0,
      );

  Map<String, Object?> toJson() => {
    'present': present,
    'spends': spends,
    'outputs': outputs,
  };
}

class ZcashOrchardBundleSummary {
  final bool present;
  final int actions;

  const ZcashOrchardBundleSummary({
    required this.present,
    required this.actions,
  });

  factory ZcashOrchardBundleSummary.fromJson(Map<String, dynamic> json) =>
      ZcashOrchardBundleSummary(
        present: json['present'] as bool? ?? false,
        actions: (json['actions'] as num?)?.toInt() ?? 0,
      );

  Map<String, Object?> toJson() => {'present': present, 'actions': actions};
}

class ZcashIronwoodBundleSummary {
  final bool present;
  final int actions;

  const ZcashIronwoodBundleSummary({
    required this.present,
    required this.actions,
  });

  static const absent = ZcashIronwoodBundleSummary(present: false, actions: 0);

  factory ZcashIronwoodBundleSummary.fromJson(Map<String, dynamic> json) =>
      ZcashIronwoodBundleSummary(
        present: json['present'] as bool? ?? false,
        actions: (json['actions'] as num?)?.toInt() ?? 0,
      );

  Map<String, Object?> toJson() => {'present': present, 'actions': actions};
}

class ZcashSproutBundleSummary {
  final bool present;
  final int joinsplits;

  const ZcashSproutBundleSummary({
    required this.present,
    required this.joinsplits,
  });

  factory ZcashSproutBundleSummary.fromJson(Map<String, dynamic> json) =>
      ZcashSproutBundleSummary(
        present: json['present'] as bool? ?? false,
        joinsplits: (json['joinsplits'] as num?)?.toInt() ?? 0,
      );

  Map<String, Object?> toJson() => {
    'present': present,
    'joinsplits': joinsplits,
  };
}

class ZcashTransactionSummary {
  final ZcashAddressNetwork network;
  final String txid;
  final ZcashTransactionVersion version;
  final int header;
  final int versionGroupId;

  final String? consensusBranchId;

  final String? consensusBranchIdHex;

  final int lockTime;
  final int expiryHeight;
  final ZcashTransparentBundleSummary transparent;
  final ZcashSaplingBundleSummary sapling;
  final ZcashOrchardBundleSummary orchard;
  final ZcashIronwoodBundleSummary ironwood;
  final ZcashSproutBundleSummary sprout;

  const ZcashTransactionSummary({
    required this.network,
    required this.txid,
    required this.version,
    required this.header,
    required this.versionGroupId,
    this.consensusBranchId,
    this.consensusBranchIdHex,
    required this.lockTime,
    required this.expiryHeight,
    required this.transparent,
    required this.sapling,
    required this.orchard,
    this.ironwood = ZcashIronwoodBundleSummary.absent,
    required this.sprout,
  });

  factory ZcashTransactionSummary.fromJson(Map<String, dynamic> json) =>
      ZcashTransactionSummary(
        network: ZcashAddressNetwork.fromJson(json['network'] as String),
        txid: json['txid'] as String,
        version: ZcashTransactionVersion.fromJson(json['version'] as String),
        header: (json['header'] as num).toInt(),
        versionGroupId: (json['version_group_id'] as num).toInt(),
        consensusBranchId: json['consensus_branch_id'] as String?,
        consensusBranchIdHex: json['consensus_branch_id_hex'] as String?,
        lockTime: (json['lock_time'] as num).toInt(),
        expiryHeight: (json['expiry_height'] as num).toInt(),
        transparent: ZcashTransparentBundleSummary.fromJson(
          (json['transparent'] as Map).cast<String, dynamic>(),
        ),
        sapling: ZcashSaplingBundleSummary.fromJson(
          (json['sapling'] as Map).cast<String, dynamic>(),
        ),
        orchard: ZcashOrchardBundleSummary.fromJson(
          (json['orchard'] as Map).cast<String, dynamic>(),
        ),
        ironwood: json['ironwood'] is Map
            ? ZcashIronwoodBundleSummary.fromJson(
                (json['ironwood'] as Map).cast<String, dynamic>(),
              )
            : ZcashIronwoodBundleSummary.absent,
        sprout: ZcashSproutBundleSummary.fromJson(
          (json['sprout'] as Map).cast<String, dynamic>(),
        ),
      );

  Map<String, Object?> toJson() => {
    'network': network.name,
    'txid': txid,
    'version': version.label,
    'header': header,
    'version_group_id': versionGroupId,
    'consensus_branch_id': consensusBranchId,
    'consensus_branch_id_hex': consensusBranchIdHex,
    'lock_time': lockTime,
    'expiry_height': expiryHeight,
    'transparent': transparent.toJson(),
    'sapling': sapling.toJson(),
    'orchard': orchard.toJson(),
    'ironwood': ironwood.toJson(),
    'sprout': sprout.toJson(),
  };

  @override
  String toString() =>
      'ZcashTransactionSummary(txid: $txid, version: ${version.label}, '
      'network: ${network.name})';
}

/// [authDigest] is the ZIP 244 auth commitment (internal byte order), v5+.
class ZcashTransactionId {
  final String txid;
  final String? authDigest;

  const ZcashTransactionId({required this.txid, this.authDigest});

  factory ZcashTransactionId.fromJson(Map<String, dynamic> json) {
    final auth = json['auth_digest'];
    return ZcashTransactionId(
      txid: _require32ByteHex(json['txid'], 'txid'),
      authDigest: auth == null ? null : _require32ByteHex(auth, 'auth_digest'),
    );
  }

  Map<String, Object?> toJson() => {'txid': txid, 'auth_digest': authDigest};

  @override
  String toString() => 'ZcashTransactionId(txid: $txid)';
}

/// Swaps between display (RPC) and protocol (scan) txid byte order. Both are
/// 64 hex chars, so a missed swap never matches and never fails.
String reverseTxidByteOrder(String txid) {
  _require32ByteHex(txid, 'txid');
  final buffer = StringBuffer();
  for (var i = txid.length - 2; i >= 0; i -= 2) {
    buffer.write(txid.substring(i, i + 2));
  }
  return buffer.toString();
}

String _require32ByteHex(Object? value, String field) {
  if (value is! String || value.length != 64) {
    throw FormatException('Invalid 32-byte hex for "$field"');
  }
  for (final unit in value.codeUnits) {
    final isDigit = unit >= 0x30 && unit <= 0x39;
    final isLower = unit >= 0x61 && unit <= 0x66;
    final isUpper = unit >= 0x41 && unit <= 0x46;
    if (!isDigit && !isLower && !isUpper) {
      throw FormatException('Invalid 32-byte hex for "$field"');
    }
  }
  return value;
}
