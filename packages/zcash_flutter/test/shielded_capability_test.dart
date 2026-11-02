@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:zcash_flutter/zcash_flutter.dart';

void main() {
  group('shielded pool capability contract', () {
    test('classifies current Sapling and Orchard support boundaries', () {
      final matrix = ShieldedCapabilityMatrix.current;

      expect(
        matrix.statusFor(
          ShieldedPool.sapling,
          CapabilitySurface.compactBlockNoteDiscovery,
        ),
        CapabilityStatus.supported,
      );
      expect(
        matrix.statusFor(
          ShieldedPool.orchard,
          CapabilitySurface.unifiedAddressReceiver,
        ),
        CapabilityStatus.exposed,
      );
      expect(
        matrix.statusFor(
          ShieldedPool.orchard,
          CapabilitySurface.lightwalletdCompactBlockFields,
        ),
        CapabilityStatus.parsedOnly,
      );
      expect(
        matrix.statusFor(
          ShieldedPool.orchard,
          CapabilitySurface.compactBlockNoteDiscovery,
        ),
        CapabilityStatus.unsupported,
      );
      expect(
        matrix.statusFor(ShieldedPool.orchard, CapabilitySurface.walletSend),
        CapabilityStatus.unsupported,
      );

      final orchardReceiver = matrix.capabilityFor(
        ShieldedPool.orchard,
        CapabilitySurface.unifiedAddressReceiver,
      );
      expect(orchardReceiver.proof, contains('receiver tests'));
      expect(
        orchardReceiver.boundary,
        allOf(contains('Receiver presence'), contains('not Orchard send')),
      );
    });

    test('summarizes Orchard as readiness without wallet support', () {
      final orchardCapabilities = ShieldedCapabilityMatrix.current
          .capabilitiesForPool(ShieldedPool.orchard);

      expect(orchardCapabilities, isNotEmpty);
      expect(
        orchardCapabilities
            .where(
              (capability) =>
                  capability.surface != CapabilitySurface.noteMemoRead,
            )
            .map((capability) => capability.status),
        isNot(contains(CapabilityStatus.supported)),
        reason:
            'only reading a memo, which moves no value, is supported for '
            'Orchard in the default build',
      );
      expect(
        orchardCapabilities.map((capability) => capability.status),
        containsAll([
          CapabilityStatus.exposed,
          CapabilityStatus.parsedOnly,
          CapabilityStatus.unsupported,
        ]),
      );
      expect(
        orchardCapabilities
            .where(
              (capability) => capability.status == CapabilityStatus.unsupported,
            )
            .map((capability) => capability.boundary.toLowerCase()),
        everyElement(anyOf(contains('orchard'), contains('unsupported'))),
      );
    });

    test('documents native capability statuses without native imports', () {
      final documented = NativeCapabilitySnapshot.documented;

      expect(
        documented.statusFor(NativeCapability.unifiedAddressDerivation),
        CapabilityStatus.supported,
      );
      expect(
        documented.statusFor(NativeCapability.transparentAddressDerivation),
        CapabilityStatus.supported,
      );
      expect(
        documented.statusFor(NativeCapability.saplingScan),
        CapabilityStatus.supported,
      );
      expect(
        documented.statusFor(NativeCapability.equihashSolver),
        CapabilityStatus.supported,
      );
      expect(
        documented.statusFor(NativeCapability.orchardReceiverExposure),
        CapabilityStatus.exposed,
      );
      expect(
        documented.statusFor(NativeCapability.orchardCompactBlockParsing),
        CapabilityStatus.parsedOnly,
      );
      expect(
        documented.statusFor(NativeCapability.orchardNoteDiscovery),
        CapabilityStatus.unsupported,
      );
    });

    test('separates parsed Orchard actions from Orchard note discovery', () {
      final matrix = ShieldedCapabilityMatrix.current;

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
          CapabilitySurface.compactBlockNoteDiscovery,
        ),
        CapabilityStatus.unsupported,
      );
      final parsing = matrix.capabilityFor(
        ShieldedPool.orchard,
        CapabilitySurface.compactBlockActionParsing,
      );
      expect(parsing.boundary.toLowerCase(), contains('not'));
    });

    test('documents the experimental Orchard note-discovery gate', () {
      final discovery = ShieldedCapabilityMatrix.current.capabilityFor(
        ShieldedPool.orchard,
        CapabilitySurface.compactBlockNoteDiscovery,
      );

      expect(discovery.status, CapabilityStatus.unsupported);
      expect(discovery.proof.toLowerCase(), contains('orchard-note-discovery'));
      expect(discovery.boundary.toLowerCase(), contains('experimental'));
    });

    test('parses experimental Orchard note-discovery capability', () {
      final parsed = NativeCapabilitySnapshot.fromJson({
        'capabilities': {
          'sapling_scan': 'supported',
          'orchard_note_discovery': 'experimental',
        },
      });

      expect(
        parsed.statusFor(NativeCapability.orchardNoteDiscovery),
        CapabilityStatus.experimental,
      );
    });

    test('parses native capability snapshots fail-closed', () {
      final parsed = NativeCapabilitySnapshot.fromJson({
        'capabilities': {
          'sapling_scan': 'supported',
          'orchard_note_discovery': 'unsupported',
        },
      });

      expect(
        parsed.statusFor(NativeCapability.saplingScan),
        CapabilityStatus.supported,
      );
      expect(
        parsed.statusFor(NativeCapability.orchardNoteDiscovery),
        CapabilityStatus.unsupported,
      );
      expect(
        parsed.statusFor(NativeCapability.equihashSolver),
        CapabilityStatus.unsupported,
      );
      expect(
        () => NativeCapabilitySnapshot.fromJson({
          'capabilities': {'future_feature': 'supported'},
        }),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('unsupported key "future_feature"'),
          ),
        ),
      );
      expect(
        () => NativeCapabilitySnapshot.fromJson({
          'capabilities': {'sapling_scan': 'maybe'},
        }),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('unsupported native capability status "maybe"'),
          ),
        ),
      );
    });
  });
}
