import 'package:test/test.dart';
import 'package:zcash_flutter/zcash_flutter.dart';

void main() {
  test('the production wallet profile enables every wallet capability', () {
    expect(productionWalletNativeFeatureProfile.cargoFeatures, {
      'ironwood-note-discovery',
      'ironwood-tx-build',
      'orchard-note-discovery',
      'orchard-tx-build',
      'sapling-spend-build',
      'transparent-tx-build',
    });
  });

  test('the production profile produces deterministic Cargo arguments', () {
    expect(productionWalletNativeFeatureProfile.cargoArguments, [
      '--no-default-features',
      '--features',
      'ironwood-note-discovery,ironwood-tx-build,orchard-note-discovery,'
          'orchard-tx-build,sapling-spend-build,transparent-tx-build',
    ]);
  });

  test('the production capability assertion accepts a complete library', () {
    final capabilities = NativeCapabilitySnapshot({
      for (final capability
          in productionWalletNativeFeatureProfile.requiredCapabilities)
        capability: CapabilityStatus.supported,
    });

    expect(
      () => requireProductionWalletNativeCapabilities(capabilities),
      returnsNormally,
    );
  });

  test('the assertion reports every missing production capability', () {
    final capabilities = NativeCapabilitySnapshot({
      for (final capability
          in productionWalletNativeFeatureProfile.requiredCapabilities)
        capability: CapabilityStatus.supported,
      NativeCapability.orchardNoteDiscovery: CapabilityStatus.unsupported,
      NativeCapability.saplingTransactionBuild: CapabilityStatus.unsupported,
    });

    expect(
      () => requireProductionWalletNativeCapabilities(capabilities),
      throwsA(
        isA<ZcashProductionNativeCapabilitiesException>()
            .having(
              (error) => error.missingCapabilities,
              'missingCapabilities',
              containsAll({
                NativeCapability.orchardNoteDiscovery,
                NativeCapability.saplingTransactionBuild,
              }),
            )
            .having(
              (error) => error.toString(),
              'message',
              allOf(
                contains('orchard_note_discovery'),
                contains('sapling_transaction_build'),
              ),
            ),
      ),
    );
  });
}
