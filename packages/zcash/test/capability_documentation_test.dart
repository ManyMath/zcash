@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

void main() {
  group('ShieldedCapabilityMatrix.current default boundaries', () {
    const matrix = ShieldedCapabilityMatrix.current;

    test('Orchard send and note discovery are unsupported by default', () {
      expect(
        matrix.statusFor(ShieldedPool.orchard, CapabilitySurface.walletSend),
        CapabilityStatus.unsupported,
      );
      expect(
        matrix.statusFor(
          ShieldedPool.orchard,
          CapabilitySurface.compactBlockNoteDiscovery,
        ),
        CapabilityStatus.unsupported,
        reason:
            'Orchard note discovery is reachable only via the experimental '
            'orchard-note-discovery feature; the default build is unsupported.',
      );
    });

    test('transparent and Sapling native build are unsupported by default', () {
      expect(
        matrix.statusFor(
          ShieldedPool.transparent,
          CapabilitySurface.walletSend,
        ),
        CapabilityStatus.unsupported,
      );
      expect(
        matrix.statusFor(
          ShieldedPool.sapling,
          CapabilitySurface.nativeTransactionBuild,
        ),
        CapabilityStatus.unsupported,
        reason:
            'Sapling build is experimental-gated and produces placeholder '
            'proofs; the default build is unsupported.',
      );
    });

    test('Orchard structural parsing stays parsedOnly, not discovery', () {
      expect(
        matrix.statusFor(
          ShieldedPool.orchard,
          CapabilitySurface.compactBlockActionParsing,
        ),
        CapabilityStatus.parsedOnly,
      );
      expect(
        matrix.statusFor(
          ShieldedPool.orchard,
          CapabilitySurface.unifiedAddressReceiver,
        ),
        CapabilityStatus.exposed,
        reason: 'receiver presence is exposed but is not send/scan support.',
      );
    });

    test('supported surfaces remain supported', () {
      expect(
        matrix.statusFor(
          ShieldedPool.sapling,
          CapabilitySurface.compactBlockNoteDiscovery,
        ),
        CapabilityStatus.supported,
      );
      expect(
        matrix.statusFor(
          ShieldedPool.transparent,
          CapabilitySurface.nativeAddressDerivation,
        ),
        CapabilityStatus.supported,
      );
      expect(
        matrix.statusFor(
          ShieldedPool.unifiedAddress,
          CapabilitySurface.nativeAddressDerivation,
        ),
        CapabilityStatus.supported,
      );
    });
  });

  group('NativeCapabilitySnapshot.documented default statuses', () {
    const snapshot = NativeCapabilitySnapshot.documented;

    test(
      'experimental-gated native capabilities are unsupported by default',
      () {
        for (final capability in const [
          NativeCapability.orchardNoteDiscovery,
          NativeCapability.transparentTransactionBuild,
          NativeCapability.saplingTransactionBuild,
          NativeCapability.orchardTransactionBuild,
        ]) {
          expect(
            snapshot.statusFor(capability),
            CapabilityStatus.unsupported,
            reason:
                '${capability.jsonKey} must be unsupported in the default '
                'build (behavior is feature-gated, never on by default).',
          );
        }
      },
    );

    test('always-on native capabilities report their stable status', () {
      expect(
        snapshot.statusFor(NativeCapability.unifiedAddressDerivation),
        CapabilityStatus.supported,
      );
      expect(
        snapshot.statusFor(NativeCapability.transparentAddressDerivation),
        CapabilityStatus.supported,
      );
      expect(
        snapshot.statusFor(NativeCapability.saplingScan),
        CapabilityStatus.supported,
      );
      expect(
        snapshot.statusFor(NativeCapability.equihashSolver),
        CapabilityStatus.supported,
      );
      expect(
        snapshot.statusFor(NativeCapability.orchardReceiverExposure),
        CapabilityStatus.exposed,
      );
      expect(
        snapshot.statusFor(NativeCapability.orchardCompactBlockParsing),
        CapabilityStatus.parsedOnly,
      );
    });

    test(
      'snapshot round-trips through JSON with stable enum-name statuses',
      () {
        final json = snapshot.toJson();
        final restored = NativeCapabilitySnapshot.fromJson(json);
        for (final capability in NativeCapability.values) {
          expect(
            restored.statusFor(capability),
            snapshot.statusFor(capability),
          );
        }
      },
    );

    test('Ironwood capabilities are reported as supported, by name', () {
      expect(
        snapshot.statusFor(NativeCapability.ironwoodNoteDiscovery),
        CapabilityStatus.supported,
      );
      expect(
        snapshot.statusFor(NativeCapability.ironwoodTransactionBuild),
        CapabilityStatus.supported,
      );

      final json = snapshot.toJson();
      final capabilities = json['capabilities'] as Map<String, Object?>;
      expect(capabilities['ironwood_note_discovery'], 'supported');
      expect(capabilities['ironwood_transaction_build'], 'supported');
    });

    test('Orchard native building is unsupported and bounded in time', () {
      expect(
        snapshot.statusFor(NativeCapability.orchardTransactionBuild),
        CapabilityStatus.unsupported,
      );
      final capabilities =
          snapshot.toJson()['capabilities'] as Map<String, Object?>;
      expect(capabilities['orchard_transaction_build'], 'unsupported');

      final documented = ShieldedCapabilityMatrix.current.capabilityFor(
        ShieldedPool.orchard,
        CapabilitySurface.nativeTransactionBuild,
      );
      expect(documented.status, CapabilityStatus.unsupported);
      expect(documented.boundary, contains('NU6.3'));
      expect(documented.boundary, contains('ZIP 258'));
    });

    test('Ironwood is a distinct pool in the documented matrix', () {
      final ironwood = ShieldedCapabilityMatrix.current.capabilitiesForPool(
        ShieldedPool.ironwood,
      );
      expect(
        ironwood,
        isNotEmpty,
        reason: 'Ironwood must appear in the matrix, not be implied by Orchard',
      );
      for (final capability in ironwood) {
        expect(capability.boundary, isNotEmpty);
      }
      for (final capability in ironwood) {
        expect(
          capability.status,
          CapabilityStatus.supported,
          reason: capability.surface.name,
        );
      }
    });
  });
}
