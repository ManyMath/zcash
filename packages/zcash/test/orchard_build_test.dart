import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

void main() {
  group('OrchardBuildResult', () {
    Map<String, Object?> validJson() => {
      'network': 'regtest',
      'transaction': '00' * 64,
      'txid': 'ab' * 32,
      'version': 'v5',
      'expiry_height': 30,
      'fee_zatoshis': 15000,
      'fee_rule': 'zip317',
      'proof_validity': 'real',
      'orchard_anchor': 'cd' * 32,
      'orchard_anchor_source': 'tree',
      'orchard_anchor_tree_size': 3,
      'transparent': {'vin': 1, 'vout': 0},
      'orchard': {'actions': 2, 'outputs': 1},
      'total_input_zatoshis': 100000,
      'non_orchard_output_zatoshis': 0,
      'orchard_output_zatoshis': 85000,
      'rng': 'os',
    };

    test('parses a complete native build result', () {
      final result = OrchardBuildResult.fromJson(validJson());
      expect(result.network, ZcashAddressNetwork.regtest);
      expect(result.transactionHex, '00' * 64);
      expect(result.txid, 'ab' * 32);
      expect(result.version, 'v5');
      expect(result.expiryHeight, 30);
      expect(result.feeZatoshis, 15000);
      expect(result.feeRule, 'zip317');
      expect(result.orchardAnchor, 'cd' * 32);
      expect(result.orchardAnchorSource, 'tree');
      expect(result.orchardAnchorTreeSize, 3);
      expect(result.vin, 1);
      expect(result.vout, 0);
      expect(result.orchardActions, 2);
      expect(result.totalInputZatoshis, 100000);
      expect(result.nonOrchardOutputZatoshis, 0);
      expect(result.orchardOutputZatoshis, 85000);
      expect(result.rng, 'os');
      expect(result.isDeterministic, isFalse);
    });

    test('reports the consensus branch the transaction is signed for', () {
      expect(
        OrchardBuildResult.fromJson(
          validJson()..['consensus_branch_id'] = 'nu6.2',
        ).consensusBranchId,
        'nu6.2',
      );
      expect(
        OrchardBuildResult.fromJson(validJson()).consensusBranchId,
        isEmpty,
      );
    });

    test('reports real proofs, since there is no placeholder mode', () {
      expect(OrchardBuildResult.fromJson(validJson()).isConsensusValid, isTrue);
      expect(
        OrchardBuildResult.fromJson(
          validJson()..['proof_validity'] = 'placeholder',
        ).isConsensusValid,
        isFalse,
      );
    });

    test('distinguishes a declared empty tree from a supplied anchor', () {
      final empty = OrchardBuildResult.fromJson(
        validJson()..['orchard_anchor_tree_size'] = 0,
      );
      expect(empty.usedEmptyTreeAnchor, isTrue);

      final supplied = OrchardBuildResult.fromJson(
        validJson()
          ..['orchard_anchor_source'] = 'anchor'
          ..['orchard_anchor_tree_size'] = null,
      );
      expect(supplied.usedEmptyTreeAnchor, isFalse);
      expect(supplied.orchardAnchorTreeSize, isNull);
    });

    test('reports a deterministic build as such', () {
      final result = OrchardBuildResult.fromJson(
        validJson()..['rng'] = 'deterministic',
      );
      expect(result.isDeterministic, isTrue);
    });

    test('rejects malformed anchors and missing totals', () {
      expect(
        () => OrchardBuildResult.fromJson(
          validJson()..['orchard_anchor'] = 'cd' * 16,
        ),
        throwsA(isA<ZcashModelException>()),
      );
      expect(
        () => OrchardBuildResult.fromJson(
          validJson()..remove('orchard_output_zatoshis'),
        ),
        throwsA(isA<ZcashModelException>()),
      );
      expect(
        () => OrchardBuildResult.fromJson(validJson()..['orchard'] = {}),
        throwsA(isA<ZcashModelException>()),
      );
    });
  });
}
