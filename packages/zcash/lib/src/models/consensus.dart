import 'blockchain_info.dart';

enum ZcashConsensusNetwork {
  mainnet,
  testnet,
  regtest;

  factory ZcashConsensusNetwork.fromJson(String value) => switch (value) {
    'mainnet' || 'main' => ZcashConsensusNetwork.mainnet,
    'testnet' || 'test' => ZcashConsensusNetwork.testnet,
    'regtest' => ZcashConsensusNetwork.regtest,
    _ => throw FormatException('Unknown Zcash consensus network: $value'),
  };
}

class ZcashAddressPrefixConstants {
  final String saplingPaymentAddressHrp;
  final String saplingExtendedSpendingKeyHrp;
  final String saplingExtendedFullViewingKeyHrp;
  final String texAddressHrp;
  final String unifiedAddressHrp;
  final String unifiedFullViewingKeyHrp;
  final String unifiedIncomingViewingKeyHrp;
  final List<int> sproutAddressB58Prefix;
  final List<int> transparentPubkeyAddressB58Prefix;
  final List<int> transparentScriptAddressB58Prefix;
  final List<int> transparentSecretKeyB58Prefix;

  const ZcashAddressPrefixConstants({
    required this.saplingPaymentAddressHrp,
    required this.saplingExtendedSpendingKeyHrp,
    required this.saplingExtendedFullViewingKeyHrp,
    required this.texAddressHrp,
    required this.unifiedAddressHrp,
    required this.unifiedFullViewingKeyHrp,
    required this.unifiedIncomingViewingKeyHrp,
    required this.sproutAddressB58Prefix,
    required this.transparentPubkeyAddressB58Prefix,
    required this.transparentScriptAddressB58Prefix,
    required this.transparentSecretKeyB58Prefix,
  });

  factory ZcashAddressPrefixConstants.fromJson(Map<String, dynamic> json) =>
      ZcashAddressPrefixConstants(
        saplingPaymentAddressHrp: json['sapling_payment_address_hrp'] as String,
        saplingExtendedSpendingKeyHrp:
            json['sapling_extended_spending_key_hrp'] as String,
        saplingExtendedFullViewingKeyHrp:
            json['sapling_extended_full_viewing_key_hrp'] as String,
        texAddressHrp: json['tex_address_hrp'] as String,
        unifiedAddressHrp: json['unified_address_hrp'] as String,
        unifiedFullViewingKeyHrp:
            json['unified_full_viewing_key_hrp'] as String,
        unifiedIncomingViewingKeyHrp:
            json['unified_incoming_viewing_key_hrp'] as String,
        sproutAddressB58Prefix: _intList(json['sprout_address_b58_prefix']),
        transparentPubkeyAddressB58Prefix: _intList(
          json['transparent_pubkey_address_b58_prefix'],
        ),
        transparentScriptAddressB58Prefix: _intList(
          json['transparent_script_address_b58_prefix'],
        ),
        transparentSecretKeyB58Prefix: _intList(
          json['transparent_secret_key_b58_prefix'],
        ),
      );

  Map<String, Object?> toJson() => {
    'sapling_payment_address_hrp': saplingPaymentAddressHrp,
    'sapling_extended_spending_key_hrp': saplingExtendedSpendingKeyHrp,
    'sapling_extended_full_viewing_key_hrp': saplingExtendedFullViewingKeyHrp,
    'tex_address_hrp': texAddressHrp,
    'unified_address_hrp': unifiedAddressHrp,
    'unified_full_viewing_key_hrp': unifiedFullViewingKeyHrp,
    'unified_incoming_viewing_key_hrp': unifiedIncomingViewingKeyHrp,
    'sprout_address_b58_prefix': sproutAddressB58Prefix,
    'transparent_pubkey_address_b58_prefix': transparentPubkeyAddressB58Prefix,
    'transparent_script_address_b58_prefix': transparentScriptAddressB58Prefix,
    'transparent_secret_key_b58_prefix': transparentSecretKeyB58Prefix,
  };
}

class ZcashConsensusActivation {
  final String name;
  final int activationHeight;
  final String? branchId;
  final String? status;

  const ZcashConsensusActivation({
    required this.name,
    required this.activationHeight,
    this.branchId,
    this.status,
  });

  factory ZcashConsensusActivation.fromJson(Map<String, dynamic> json) =>
      ZcashConsensusActivation(
        name: json['name'] as String,
        activationHeight: _activationHeight(json),
        branchId: json['branch_id'] as String? ?? json['branchId'] as String?,
        status: json['status'] as String?,
      );

  factory ZcashConsensusActivation.fromRpcUpgrade(
    String branchId,
    NetworkUpgrade upgrade,
  ) => ZcashConsensusActivation(
    name: upgrade.name,
    activationHeight: upgrade.activationHeight,
    branchId: branchId,
    status: upgrade.status,
  );

  Map<String, Object?> toJson() => {
    'name': name,
    'activation_height': activationHeight,
    if (branchId != null) 'branch_id': branchId,
    if (status != null) 'status': status,
  };
}

class ZcashNetworkConstants {
  final ZcashConsensusNetwork network;
  final int coinType;
  final int zatoshisPerZec;
  final int maxMoneyZatoshis;
  final int coinbaseMaturityBlocks;
  final ZcashAddressPrefixConstants addressPrefixes;
  final List<ZcashConsensusActivation> activationHeights;

  const ZcashNetworkConstants({
    required this.network,
    required this.coinType,
    required this.zatoshisPerZec,
    required this.maxMoneyZatoshis,
    required this.coinbaseMaturityBlocks,
    required this.addressPrefixes,
    required this.activationHeights,
  });

  factory ZcashNetworkConstants.fromJson(Map<String, dynamic> json) {
    final prefixes = json['address_prefixes'];
    if (prefixes is! Map) {
      throw const FormatException('Network constants missing prefix object');
    }
    final activations = json['activation_heights'];
    if (activations is! List) {
      throw const FormatException('Network constants missing activations list');
    }

    return ZcashNetworkConstants(
      network: ZcashConsensusNetwork.fromJson(
        json['network_kind'] as String? ?? json['network'] as String,
      ),
      coinType: (json['coin_type'] as num).toInt(),
      zatoshisPerZec: (json['zatoshis_per_zec'] as num).toInt(),
      maxMoneyZatoshis: (json['max_money_zatoshis'] as num).toInt(),
      coinbaseMaturityBlocks: (json['coinbase_maturity_blocks'] as num).toInt(),
      addressPrefixes: ZcashAddressPrefixConstants.fromJson(
        prefixes.cast<String, dynamic>(),
      ),
      activationHeights: activations
          .map(
            (activation) => ZcashConsensusActivation.fromJson(
              (activation as Map).cast<String, dynamic>(),
            ),
          )
          .toList(growable: false),
    );
  }

  ZcashConsensusActivation? activationByName(String name) {
    for (final activation in activationHeights) {
      if (activation.name == name) return activation;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'network_kind': network.name,
    'coin_type': coinType,
    'zatoshis_per_zec': zatoshisPerZec,
    'max_money_zatoshis': maxMoneyZatoshis,
    'coinbase_maturity_blocks': coinbaseMaturityBlocks,
    'address_prefixes': addressPrefixes.toJson(),
    'activation_heights': activationHeights
        .map((activation) => activation.toJson())
        .toList(),
  };
}

List<int> _intList(Object? value) {
  if (value is! List) {
    throw const FormatException('Expected integer list');
  }
  return value.map((item) => (item as num).toInt()).toList(growable: false);
}

int _activationHeight(Map<String, dynamic> json) {
  final value = json['activation_height'] ?? json['activationheight'];
  if (value is! num) {
    throw const FormatException('Activation missing height');
  }
  return value.toInt();
}
