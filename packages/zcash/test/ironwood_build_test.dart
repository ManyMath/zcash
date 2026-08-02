import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

void main() {
  group('IronwoodBuildResult', () {
    Map<String, Object?> validJson() => {
      'network': 'regtest',
      'transaction': '00' * 64,
      'txid': 'ab' * 32,
      'version': 'v6',
      'expiry_height': 30,
      'fee_zatoshis': 15000,
      'fee_rule': 'zip317',
      'proof_validity': 'real',
      'ironwood_anchor': 'cd' * 32,
      'ironwood_anchor_source': 'tree',
      'ironwood_anchor_tree_size': 3,
      'transparent': {'vin': 1, 'vout': 0},
      'sapling': {'spends': 0, 'outputs': 0},
      'ironwood': {'actions': 2, 'outputs': 1},
      'total_input_zatoshis': 100000,
      'transparent_input_zatoshis': 100000,
      'sapling_input_zatoshis': 0,
      'non_ironwood_output_zatoshis': 0,
      'ironwood_output_zatoshis': 85000,
      'rng': 'os',
    };

    test('parses a complete native build result', () {
      final result = IronwoodBuildResult.fromJson(validJson());
      expect(result.network, ZcashAddressNetwork.regtest);
      expect(result.transactionHex, '00' * 64);
      expect(result.txid, 'ab' * 32);
      expect(result.version, 'v6');
      expect(result.expiryHeight, 30);
      expect(result.feeZatoshis, 15000);
      expect(result.feeRule, 'zip317');
      expect(result.ironwoodAnchor, 'cd' * 32);
      expect(result.ironwoodAnchorSource, 'tree');
      expect(result.ironwoodAnchorTreeSize, 3);
      expect(result.vin, 1);
      expect(result.vout, 0);
      expect(result.ironwoodActions, 2);
      expect(result.totalInputZatoshis, 100000);
      expect(result.transparentInputZatoshis, 100000);
      expect(result.saplingInputZatoshis, 0);
      expect(result.nonIronwoodOutputZatoshis, 0);
      expect(result.ironwoodOutputZatoshis, 85000);
      expect(result.rng, 'os');
      expect(result.spendsSapling, isFalse);
    });

    test('reports a Sapling -> Ironwood migration distinctly', () {
      final result = IronwoodBuildResult.fromJson(
        validJson()
          ..['sapling'] = {'spends': 1, 'outputs': 2}
          ..['transparent'] = {'vin': 0, 'vout': 0}
          ..['transparent_input_zatoshis'] = 0
          ..['sapling_input_zatoshis'] = 100000,
      );
      expect(result.spendsSapling, isTrue);
      expect(result.saplingSpends, 1);
      expect(result.saplingOutputs, 2);
      expect(result.saplingInputZatoshis, 100000);
      expect(result.transparentInputZatoshis, 0);
      expect(result.vin, 0);
    });

    test('reports a canonical Orchard -> Ironwood migration', () {
      // ZIP 318 canonical shape: 1 Orchard spend (2 actions), 1 Ironwood.
      final result = IronwoodBuildResult.fromJson(
        validJson()
          ..['orchard'] = {'spends': 1, 'actions': 2, 'change_outputs': 0}
          ..['ironwood'] = {'actions': 1, 'outputs': 1}
          ..['zip318_canonical'] = true
          ..['transparent'] = {'vin': 0, 'vout': 0}
          ..['transparent_input_zatoshis'] = 0
          ..['orchard_input_zatoshis'] = 1000000
          ..['total_input_zatoshis'] = 1000000
          ..['ironwood_output_zatoshis'] = 985000,
      );
      expect(result.spendsOrchard, isTrue);
      expect(result.spendsSapling, isFalse);
      expect(result.zip318Canonical, isTrue);
      expect(result.orchardSpends, 1);
      expect(result.orchardActions, 2);
      expect(result.ironwoodActions, 1);
      expect(result.orchardInputZatoshis, 1000000);
      expect(result.keptOrchardChange, isFalse);
    });

    test('keeps Orchard change invisible in the action count', () {
      final result = IronwoodBuildResult.fromJson(
        validJson()
          ..['orchard'] = {'spends': 1, 'actions': 2, 'change_outputs': 1}
          ..['ironwood'] = {'actions': 1, 'outputs': 1}
          ..['zip318_canonical'] = true
          ..['orchard_input_zatoshis'] = 1000000
          ..['orchard_change_zatoshis'] = 300000,
      );
      expect(result.orchardActions, 2);
      expect(result.orchardChangeOutputs, 1);
      expect(result.keptOrchardChange, isTrue);
      expect(result.orchardChangeZatoshis, 300000);
    });

    test('reports an ordinary Ironwood -> Ironwood payment', () {
      final result = IronwoodBuildResult.fromJson(
        validJson()
          ..['ironwood'] = {
            'spends': 1,
            'actions': 2,
            'outputs': 2,
            'change_outputs': 1,
          }
          ..['transparent'] = {'vin': 0, 'vout': 0}
          ..['transparent_input_zatoshis'] = 0
          ..['ironwood_input_zatoshis'] = 1000000
          ..['ironwood_change_zatoshis'] = 250000
          ..['total_input_zatoshis'] = 1000000
          ..['ironwood_output_zatoshis'] = 735000,
      );
      expect(result.spendsIronwood, isTrue);
      expect(result.ironwoodSpends, 1);
      expect(result.ironwoodChangeOutputs, 1);
      expect(result.ironwoodInputZatoshis, 1000000);
      expect(result.ironwoodChangeZatoshis, 250000);
      expect(result.keptIronwoodChange, isTrue);
      expect(result.zip318Canonical, isFalse);
      expect(result.spendsOrchard, isFalse);
      expect(result.spendsSapling, isFalse);
      expect(result.ironwoodActions, 2);
    });

    test('treats a shielding result as spending no Ironwood', () {
      final result = IronwoodBuildResult.fromJson(validJson());
      expect(result.spendsIronwood, isFalse);
      expect(result.ironwoodSpends, 0);
      expect(result.ironwoodInputZatoshis, 0);
      expect(result.keptIronwoodChange, isFalse);
    });

    test('treats a Path C result with no Orchard section as no spends', () {
      final result = IronwoodBuildResult.fromJson(validJson());
      expect(result.orchardSpends, 0);
      expect(result.orchardActions, 0);
      expect(result.spendsOrchard, isFalse);
      expect(result.zip318Canonical, isFalse);
    });

    test('treats a Path C result with no Sapling section as no spends', () {
      final result = IronwoodBuildResult.fromJson(
        validJson()..remove('sapling'),
      );
      expect(result.saplingSpends, 0);
      expect(result.spendsSapling, isFalse);
    });

    test('reports real Ironwood proofs as consensus-valid', () {
      expect(
        IronwoodBuildResult.fromJson(validJson()).isConsensusValid,
        isTrue,
      );
    });

    test('distinguishes a declared empty tree from a supplied anchor', () {
      final empty = IronwoodBuildResult.fromJson(
        validJson()..['ironwood_anchor_tree_size'] = 0,
      );
      expect(empty.usedEmptyTreeAnchor, isTrue);

      final supplied = IronwoodBuildResult.fromJson(
        validJson()
          ..['ironwood_anchor_source'] = 'anchor'
          ..['ironwood_anchor_tree_size'] = null,
      );
      expect(supplied.ironwoodAnchorTreeSize, isNull);
      expect(supplied.usedEmptyTreeAnchor, isFalse);
    });

    test('flags a deterministic (test-only) RNG seed', () {
      expect(
        IronwoodBuildResult.fromJson(validJson()).isDeterministic,
        isFalse,
      );
      final seeded = IronwoodBuildResult.fromJson(
        validJson()..['rng'] = 'deterministic',
      );
      expect(seeded.isDeterministic, isTrue);
    });

    test('rejects a malformed (odd-length) transaction hex', () {
      expect(
        () =>
            IronwoodBuildResult.fromJson(validJson()..['transaction'] = 'abc'),
        throwsA(isA<ZcashModelException>()),
      );
    });

    test('rejects an anchor that is not 32 bytes', () {
      expect(
        () => IronwoodBuildResult.fromJson(
          validJson()..['ironwood_anchor'] = 'cd' * 16,
        ),
        throwsA(isA<ZcashModelException>()),
      );
    });

    test('rejects a non-hex anchor without echoing it', () {
      expect(
        () => IronwoodBuildResult.fromJson(
          validJson()..['ironwood_anchor'] = 'zz' * 32,
        ),
        throwsA(isA<ZcashModelException>()),
      );
    });

    test('rejects a result with no Ironwood action count', () {
      expect(
        () => IronwoodBuildResult.fromJson(validJson()..remove('ironwood')),
        throwsA(isA<ZcashModelException>()),
      );
    });
  });

  group('v6 transaction summary', () {
    Map<String, dynamic> summaryJson({Map<String, Object?>? ironwood}) => {
      'network': 'regtest',
      'txid': 'ab' * 32,
      'version': 'v6',
      'header': 0,
      'version_group_id': 0,
      'consensus_branch_id': 'nu6.3',
      'consensus_branch_id_hex': '37a5165b',
      'lock_time': 0,
      'expiry_height': 30,
      'transparent': {'present': true, 'vin': 1, 'vout': 0},
      'sapling': {'present': false, 'spends': 0, 'outputs': 0},
      'orchard': {'present': false, 'actions': 0},
      'ironwood': ?ironwood,
      'sprout': {'present': false, 'joinsplits': 0},
    };

    test('parses the v6 transaction version', () {
      expect(
        ZcashTransactionVersion.fromJson('v6'),
        ZcashTransactionVersion.v6,
      );
      expect(ZcashTransactionVersion.v6.label, 'v6');
    });

    test('reports the Ironwood bundle separately from Orchard', () {
      final summary = ZcashTransactionSummary.fromJson(
        summaryJson(ironwood: {'present': true, 'actions': 2}),
      );
      expect(summary.version, ZcashTransactionVersion.v6);
      expect(summary.ironwood.present, isTrue);
      expect(summary.ironwood.actions, 2);
      expect(summary.orchard.present, isFalse);
      expect(summary.toJson()['ironwood'], {'present': true, 'actions': 2});
    });

    test('treats a summary without an Ironwood field as having no bundle', () {
      final summary = ZcashTransactionSummary.fromJson(summaryJson());
      expect(summary.ironwood.present, isFalse);
      expect(summary.ironwood.actions, 0);
    });
  });

  group('tree state anchor source', () {
    test('parses the Ironwood tree alongside Sapling and Orchard', () {
      final state = TreeState.fromJson({
        'hash': 'ab' * 32,
        'height': 3428143,
        'time': 0,
        'sapling': {
          'commitments': {'finalState': '01'},
        },
        'orchard': {
          'commitments': {'finalState': '02'},
        },
        'ironwood': {
          'commitments': {'finalState': '03'},
        },
      });
      expect(state.sapling?.finalState, '01');
      expect(state.orchard?.finalState, '02');
      expect(state.ironwood?.finalState, '03');
    });

    test('leaves the Ironwood tree null before activation', () {
      final state = TreeState.fromJson({
        'hash': 'ab' * 32,
        'height': 3000000,
        'time': 0,
        'orchard': {
          'commitments': {'finalState': '02'},
        },
      });
      expect(state.ironwood, isNull);
    });
  });

  group('IronwoodFeeQuote', () {
    Map<String, Object?> quote({Object? maxOutput = 85000}) => {
      'quote_only': true,
      'network': 'regtest',
      'fee_zatoshis': 15000,
      'fee_rule': 'zip317',
      'consensus_branch_id': 'nu6.3',
      'total_input_zatoshis': 100000,
      'non_ironwood_output_zatoshis': 0,
      'max_ironwood_output_zatoshis': maxOutput,
      'ironwood_spends': 0,
      'orchard_spends': 0,
      'sapling_spends': 0,
      'transparent_inputs': 1,
    };

    test('parses a funded quote', () {
      final parsed = IronwoodFeeQuote.fromJson(quote());
      expect(parsed.feeZatoshis, 15000);
      expect(parsed.feeRule, 'zip317');
      expect(parsed.consensusBranchId, 'nu6.3');
      expect(parsed.maxIronwoodOutputZatoshis, 85000);
      expect(parsed.isFunded, isTrue);
      expect(parsed.transparentInputs, 1);
    });

    test('a shortfall is a quote, not a failure', () {
      final parsed = IronwoodFeeQuote.fromJson(quote(maxOutput: null));
      expect(parsed.isFunded, isFalse);
      expect(parsed.maxIronwoodOutputZatoshis, isNull);
      expect(parsed.feeZatoshis, 15000);
    });

    test('refuses to read a build result as a quote', () {
      final notAQuote = quote()..remove('quote_only');
      expect(
        () => IronwoodFeeQuote.fromJson(notAQuote),
        throwsA(isA<ZcashModelException>()),
      );
    });
  });
}
