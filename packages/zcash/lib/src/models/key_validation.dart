import 'address.dart';

enum ZcashKeyType {
  ufvk,
  saplingExtendedSpendingKey,
  saplingExtendedFullViewingKey,
  transparentXpub;

  String get label => switch (this) {
    ZcashKeyType.ufvk => 'ufvk',
    ZcashKeyType.saplingExtendedSpendingKey => 'sapling_extended_spending_key',
    ZcashKeyType.saplingExtendedFullViewingKey =>
      'sapling_extended_full_viewing_key',
    ZcashKeyType.transparentXpub => 'transparent_xpub',
  };

  factory ZcashKeyType.fromJson(String value) => switch (value) {
    'ufvk' => ZcashKeyType.ufvk,
    'sapling_extended_spending_key' => ZcashKeyType.saplingExtendedSpendingKey,
    'sapling_extended_full_viewing_key' =>
      ZcashKeyType.saplingExtendedFullViewingKey,
    'transparent_xpub' => ZcashKeyType.transparentXpub,
    _ => throw FormatException('Unknown key type: $value'),
  };
}

enum ZcashKeyValidationReason {
  invalid,

  wrongNetwork;

  factory ZcashKeyValidationReason.fromJson(String value) => switch (value) {
    'invalid' => ZcashKeyValidationReason.invalid,
    'wrong_network' => ZcashKeyValidationReason.wrongNetwork,
    _ => throw FormatException('Unknown key validation reason: $value'),
  };
}

class ZcashKeyComponents {
  final bool orchard;
  final bool sapling;
  final bool transparent;

  const ZcashKeyComponents({
    required this.orchard,
    required this.sapling,
    required this.transparent,
  });

  factory ZcashKeyComponents.fromJson(Map<String, dynamic> json) =>
      ZcashKeyComponents(
        orchard: json['orchard'] as bool? ?? false,
        sapling: json['sapling'] as bool? ?? false,
        transparent: json['transparent'] as bool? ?? false,
      );

  Map<String, Object?> toJson() => {
    'orchard': orchard,
    'sapling': sapling,
    'transparent': transparent,
  };
}

class ZcashKeyValidation {
  final ZcashKeyType keyType;
  final ZcashAddressNetwork network;
  final bool valid;
  final ZcashKeyValidationReason? reason;
  final ZcashKeyComponents? components;

  const ZcashKeyValidation({
    required this.keyType,
    required this.network,
    required this.valid,
    this.reason,
    this.components,
  });

  factory ZcashKeyValidation.fromJson(Map<String, dynamic> json) {
    final reason = json['reason'];
    final components = json['components'];
    return ZcashKeyValidation(
      keyType: ZcashKeyType.fromJson(json['key_type'] as String),
      network: ZcashAddressNetwork.fromJson(json['network'] as String),
      valid: json['valid'] as bool? ?? false,
      reason: reason is String
          ? ZcashKeyValidationReason.fromJson(reason)
          : null,
      components: components is Map
          ? ZcashKeyComponents.fromJson(components.cast<String, dynamic>())
          : null,
    );
  }

  Map<String, Object?> toJson() => {
    'key_type': keyType.label,
    'network': network.name,
    'valid': valid,
    if (reason != null)
      'reason': reason == ZcashKeyValidationReason.wrongNetwork
          ? 'wrong_network'
          : 'invalid',
    if (components != null) 'components': components!.toJson(),
  };
}
