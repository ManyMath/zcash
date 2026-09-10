@TestOn('vm')
library;

import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';
import 'package:zcash/zcash.dart';
import 'package:zcash/lightwalletd_protos.dart' as lwd;

void main() {
  group('Orchard parsed-only data classification', () {
    test('classifies compact-block Orchard fields as parsed-only data', () {
      final block = lwd.CompactBlock(
        chainMetadata: lwd.ChainMetadata(orchardCommitmentTreeSize: 42),
        vtx: [
          lwd.CompactTx(
            actions: [
              lwd.CompactOrchardAction(
                nullifier: [1],
                cmx: [2],
                ephemeralKey: [3],
                ciphertext: [4],
              ),
              lwd.CompactOrchardAction(nullifier: [5]),
            ],
          ),
          lwd.CompactTx(
            actions: [
              lwd.CompactOrchardAction(cmx: [6]),
            ],
          ),
        ],
      );

      final actions = OrchardDataClassifier.compactBlockActions(block);
      final metadata = OrchardDataClassifier.chainMetadata(block.chainMetadata);

      expect(actions.status, CapabilityStatus.parsedOnly);
      expect(actions.present, isTrue);
      expect(actions.count, 3);
      expect(actions.surface, OrchardParsedDataSurface.compactBlockActions);
      expect(actions.boundary, contains('not Orchard note discovery'));
      expect(metadata.status, CapabilityStatus.parsedOnly);
      expect(metadata.present, isTrue);
      expect(metadata.count, 1);
      expect(metadata.description, contains('orchardCommitmentTreeSize=42'));
    });

    test(
      'classifies lightwalletd and JSON-RPC Orchard tree strings as parsed-only',
      () {
        final protoTreeState = lwd.TreeState(orchardTree: 'proto-orchard-tree');
        final jsonTreeState = TreeState.fromJson({
          'hash': '00',
          'height': 123,
          'time': 456,
          'orchard': {
            'commitments': {'finalState': 'json-orchard-tree'},
          },
        });

        final protoClassification = OrchardDataClassifier.lightwalletdTreeState(
          protoTreeState,
        );
        final jsonClassification = OrchardDataClassifier.jsonRpcTreeState(
          jsonTreeState,
        );

        expect(protoClassification.status, CapabilityStatus.parsedOnly);
        expect(protoClassification.present, isTrue);
        expect(protoClassification.description, contains('orchardTree'));
        expect(jsonClassification.status, CapabilityStatus.parsedOnly);
        expect(jsonClassification.present, isTrue);
        expect(jsonClassification.description, contains('json-orchard-tree'));
      },
    );

    test(
      'classifies Orchard subtree request and root shapes as parsed-only',
      () {
        final arg = lwd.GetSubtreeRootsArg(
          startIndex: 7,
          shieldedProtocol: lwd.ShieldedProtocol.orchard,
          maxEntries: 16,
        );
        final root = lwd.SubtreeRoot(
          rootHash: [1, 2, 3],
          completingBlockHash: [4, 5, 6],
          completingBlockHeight: Int64(1234),
        );

        final argClassification = OrchardDataClassifier.subtreeRootsArg(arg);
        final rootClassification = OrchardDataClassifier.subtreeRoot(root);

        expect(argClassification.status, CapabilityStatus.parsedOnly);
        expect(argClassification.present, isTrue);
        expect(argClassification.description, contains('startIndex=7'));
        expect(rootClassification.status, CapabilityStatus.parsedOnly);
        expect(rootClassification.present, isTrue);
        expect(rootClassification.description, contains('height=1234'));
      },
    );

    test('represents missing Orchard fields as parsed-only absence', () {
      final emptyBlock = lwd.CompactBlock(
        vtx: [
          lwd.CompactTx(outputs: [lwd.CompactSaplingOutput()]),
        ],
      );
      final protoTreeStateWithoutOrchard = lwd.TreeState(
        saplingTree: 'sapling',
      );
      final protoTreeStateWithEmptyOrchard = lwd.TreeState(orchardTree: '');
      final jsonTreeStateWithoutOrchard = TreeState.fromJson({
        'hash': '00',
        'height': 123,
        'time': 456,
        'sapling': {
          'commitments': {'finalState': 'sapling-tree'},
        },
      });
      final saplingSubtreeArg = lwd.GetSubtreeRootsArg(
        shieldedProtocol: lwd.ShieldedProtocol.sapling,
      );
      final emptySubtreeRoot = lwd.SubtreeRoot();

      for (final classification in [
        OrchardDataClassifier.compactBlockActions(emptyBlock),
        OrchardDataClassifier.chainMetadata(null),
        OrchardDataClassifier.chainMetadata(lwd.ChainMetadata()),
        OrchardDataClassifier.lightwalletdTreeState(
          protoTreeStateWithoutOrchard,
        ),
        OrchardDataClassifier.lightwalletdTreeState(
          protoTreeStateWithEmptyOrchard,
        ),
        OrchardDataClassifier.jsonRpcTreeState(jsonTreeStateWithoutOrchard),
        OrchardDataClassifier.subtreeRootsArg(saplingSubtreeArg),
        OrchardDataClassifier.subtreeRoot(emptySubtreeRoot),
      ]) {
        expect(classification.status, CapabilityStatus.parsedOnly);
        expect(classification.present, isFalse);
        expect(classification.count, 0);
        expect(classification.boundary, contains('not Orchard note discovery'));
      }
    });

    test('does not promote unsupported Orchard wallet semantics', () {
      final matrix = ShieldedCapabilityMatrix.current;

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
      expect(
        matrix.statusFor(
          ShieldedPool.orchard,
          CapabilitySurface.nativeAddressDerivation,
        ),
        isNot(CapabilityStatus.supported),
      );
    });
  });
}
