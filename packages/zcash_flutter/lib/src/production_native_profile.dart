import 'package:zcash/zcash.dart';

class ZcashNativeFeatureProfile {
  const ZcashNativeFeatureProfile({
    required this.cargoFeatures,
    required this.requiredCapabilities,
  });

  final Set<String> cargoFeatures;

  final Set<NativeCapability> requiredCapabilities;

  List<String> get cargoArguments {
    final features = cargoFeatures.toList()..sort();
    return ['--no-default-features', '--features', features.join(',')];
  }
}

const productionWalletNativeFeatureProfile = ZcashNativeFeatureProfile(
  cargoFeatures: {
    'ironwood-note-discovery',
    'ironwood-tx-build',
    'orchard-note-discovery',
    // Required by staged regtest wallets to create the pre-NU6.3 Orchard
    // source note that ZIP 318 later migrates. The native builder itself
    // remains consensus-gated and refuses Orchard outputs after activation.
    'orchard-tx-build',
    'sapling-spend-build',
    'transparent-tx-build',
  },
  requiredCapabilities: {
    NativeCapability.unifiedAddressDerivation,
    NativeCapability.transparentAddressDerivation,
    NativeCapability.saplingScan,
    NativeCapability.orchardNoteDiscovery,
    NativeCapability.orchardTransactionBuild,
    NativeCapability.transparentTransactionBuild,
    NativeCapability.saplingTransactionBuild,
    NativeCapability.ironwoodNoteDiscovery,
    NativeCapability.ironwoodTransactionBuild,
    NativeCapability.memoRead,
  },
);

class ZcashProductionNativeCapabilitiesException implements Exception {
  ZcashProductionNativeCapabilitiesException(
    Iterable<NativeCapability> missingCapabilities,
  ) : missingCapabilities = List.unmodifiable(missingCapabilities);

  final List<NativeCapability> missingCapabilities;

  @override
  String toString() =>
      'ZcashProductionNativeCapabilitiesException: the native Zcash library '
      'does not support the production wallet capabilities: '
      '${missingCapabilities.map((capability) => capability.jsonKey).join(', ')}';
}

void requireProductionWalletNativeCapabilities(
  NativeCapabilitySnapshot capabilities,
) {
  final missing = [
    for (final capability
        in productionWalletNativeFeatureProfile.requiredCapabilities)
      if (capabilities.statusFor(capability) != CapabilityStatus.supported &&
          capabilities.statusFor(capability) != CapabilityStatus.experimental)
        capability,
  ]..sort((a, b) => a.jsonKey.compareTo(b.jsonKey));
  if (missing.isNotEmpty) {
    throw ZcashProductionNativeCapabilitiesException(missing);
  }
}
