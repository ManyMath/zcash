import 'address.dart';

/// IVKs are hex BIP 32 `chain_code || compressed_pubkey` payloads.
class ZcashTransparentViewingKeys {
  final bool available;
  final String? externalIvk;
  final String? internalIvk;
  final String? defaultExternalAddress;
  final int? defaultExternalIndex;

  const ZcashTransparentViewingKeys({
    required this.available,
    this.externalIvk,
    this.internalIvk,
    this.defaultExternalAddress,
    this.defaultExternalIndex,
  });

  factory ZcashTransparentViewingKeys.fromJson(Map<String, dynamic> json) =>
      ZcashTransparentViewingKeys(
        available: json['available'] as bool? ?? false,
        externalIvk: json['external_ivk'] as String?,
        internalIvk: json['internal_ivk'] as String?,
        defaultExternalAddress: json['default_external_address'] as String?,
        defaultExternalIndex: (json['default_external_index'] as num?)?.toInt(),
      );

  Map<String, Object?> toJson() => {
    'available': available,
    'external_ivk': externalIvk,
    'internal_ivk': internalIvk,
    'default_external_address': defaultExternalAddress,
    'default_external_index': defaultExternalIndex,
  };
}

class ZcashSaplingViewingKey {
  final bool available;
  final String? defaultAddress;
  final int? defaultDiversifierIndex;

  const ZcashSaplingViewingKey({
    required this.available,
    this.defaultAddress,
    this.defaultDiversifierIndex,
  });

  factory ZcashSaplingViewingKey.fromJson(Map<String, dynamic> json) =>
      ZcashSaplingViewingKey(
        available: json['available'] as bool? ?? false,
        defaultAddress: json['default_address'] as String?,
        defaultDiversifierIndex: (json['default_diversifier_index'] as num?)
            ?.toInt(),
      );

  Map<String, Object?> toJson() => {
    'available': available,
    'default_address': defaultAddress,
    'default_diversifier_index': defaultDiversifierIndex,
  };
}

class ZcashOrchardViewingKey {
  final bool available;

  const ZcashOrchardViewingKey({required this.available});

  factory ZcashOrchardViewingKey.fromJson(Map<String, dynamic> json) =>
      ZcashOrchardViewingKey(available: json['available'] as bool? ?? false);

  Map<String, Object?> toJson() => {'available': available};
}

class ZcashViewingKeys {
  final ZcashAddressNetwork network;
  final int accountIndex;
  final ZcashTransparentViewingKeys transparent;
  final ZcashSaplingViewingKey sapling;
  final ZcashOrchardViewingKey orchard;

  const ZcashViewingKeys({
    required this.network,
    required this.accountIndex,
    required this.transparent,
    required this.sapling,
    required this.orchard,
  });

  bool get hasTransparent => transparent.available;
  bool get hasSapling => sapling.available;
  bool get hasOrchard => orchard.available;

  factory ZcashViewingKeys.fromJson(Map<String, dynamic> json) {
    final transparent = json['transparent'];
    if (transparent is! Map) {
      throw const FormatException('Viewing keys missing transparent object');
    }
    final sapling = json['sapling'];
    if (sapling is! Map) {
      throw const FormatException('Viewing keys missing sapling object');
    }
    final orchard = json['orchard'];
    if (orchard is! Map) {
      throw const FormatException('Viewing keys missing orchard object');
    }

    return ZcashViewingKeys(
      network: ZcashAddressNetwork.fromJson(json['network'] as String),
      accountIndex: (json['account_index'] as num).toInt(),
      transparent: ZcashTransparentViewingKeys.fromJson(
        transparent.cast<String, dynamic>(),
      ),
      sapling: ZcashSaplingViewingKey.fromJson(sapling.cast<String, dynamic>()),
      orchard: ZcashOrchardViewingKey.fromJson(orchard.cast<String, dynamic>()),
    );
  }

  Map<String, Object?> toJson() => {
    'network': network.name,
    'account_index': accountIndex,
    'transparent': transparent.toJson(),
    'sapling': sapling.toJson(),
    'orchard': orchard.toJson(),
  };
}
