import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

void main() {
  group('SaplingBuildResult', () {
    Map<String, Object?> validJson() => {
      'network': 'regtest',
      'transaction': '00' * 64,
      'txid': 'ab' * 32,
      'version': 'v5',
      'expiry_height': 30,
      'fee_zatoshis': 10000,
      'proof_validity': 'placeholder',
      'transparent': {'vin': 0, 'vout': 0},
      'sapling': {'spends': 1, 'outputs': 2},
      'total_spent_zatoshis': 100000,
      'total_output_zatoshis': 90000,
    };

    test('parses a complete native build result', () {
      final result = SaplingBuildResult.fromJson(validJson());
      expect(result.network, ZcashAddressNetwork.regtest);
      expect(result.transactionHex, '00' * 64);
      expect(result.txid, 'ab' * 32);
      expect(result.version, 'v5');
      expect(result.expiryHeight, 30);
      expect(result.feeZatoshis, 10000);
      expect(result.proofValidity, 'placeholder');
      expect(result.transparentVin, 0);
      expect(result.transparentVout, 0);
      expect(result.saplingSpends, 1);
      expect(result.saplingOutputs, 2);
      expect(result.totalSpentZatoshis, 100000);
      expect(result.totalOutputZatoshis, 90000);
    });

    test('carries the consensus branch the build signed for', () {
      final json = validJson()
        ..['version'] = 'v6'
        ..['consensus_branch_id'] = 'nu6.3';
      final result = SaplingBuildResult.fromJson(json);
      expect(result.consensusBranchId, 'nu6.3');
      expect(result.version, 'v6');
    });

    test('a result from a build without the field reads as unstated', () {
      final result = SaplingBuildResult.fromJson(validJson());
      expect(result.consensusBranchId, isEmpty);
    });

    test('reports the value a shielding build brought in transparently', () {
      final json = validJson()
        ..['transparent'] = {'vin': 1, 'vout': 0, 'input_zatoshis': 100000}
        ..['sapling'] = {'spends': 0, 'outputs': 2}
        ..['total_spent_zatoshis'] = 0;
      final result = SaplingBuildResult.fromJson(json);
      expect(result.transparentVin, 1);
      expect(result.transparentInputZatoshis, 100000);
      expect(result.totalSpentZatoshis, 0);
      expect(result.saplingSpends, 0);
    });

    test('a result without the transparent input total reads as zero', () {
      final result = SaplingBuildResult.fromJson(validJson());
      expect(result.transparentInputZatoshis, 0);
      expect(result.transparentVin, 0);
    });

    test(
      'placeholder proofs are reported as not real / not consensus-valid',
      () {
        final result = SaplingBuildResult.fromJson(validJson());
        expect(result.hasRealProofs, isFalse);
        expect(result.isConsensusValid, isFalse);
      },
    );

    test('real proofs are reported as real', () {
      final json = validJson()..['proof_validity'] = 'real';
      final result = SaplingBuildResult.fromJson(json);
      expect(result.proofValidity, 'real');
      expect(result.hasRealProofs, isTrue);
      expect(result.isConsensusValid, isTrue);
    });

    test('rejects a malformed (odd-length) transaction hex', () {
      final json = validJson()..['transaction'] = 'abc';
      expect(
        () => SaplingBuildResult.fromJson(json),
        throwsA(isA<ZcashModelException>()),
      );
    });

    test('rejects a txid that is not 32 bytes', () {
      final json = validJson()..['txid'] = 'ab' * 16;
      expect(
        () => SaplingBuildResult.fromJson(json),
        throwsA(isA<ZcashModelException>()),
      );
    });

    test('rejects a non-hex txid without echoing it', () {
      final json = validJson()..['txid'] = 'zz' * 32;
      expect(
        () => SaplingBuildResult.fromJson(json),
        throwsA(isA<ZcashModelException>()),
      );
    });
  });

  group('capability matrix', () {
    test('documents sapling transaction build as unsupported by default', () {
      expect(
        NativeCapabilitySnapshot.documented.statusFor(
          NativeCapability.saplingTransactionBuild,
        ),
        CapabilityStatus.unsupported,
      );
    });

    test('round-trips the sapling build capability key through JSON', () {
      final snapshot = NativeCapabilitySnapshot.fromJson({
        'capabilities': {
          'unified_address_derivation': 'supported',
          'transparent_address_derivation': 'supported',
          'sapling_scan': 'supported',
          'equihash_solver': 'supported',
          'orchard_receiver_exposure': 'exposed',
          'orchard_compact_block_parsing': 'parsedOnly',
          'orchard_note_discovery': 'unsupported',
          'transparent_transaction_build': 'unsupported',
          'sapling_transaction_build': 'experimental',
        },
      });
      expect(
        snapshot.statusFor(NativeCapability.saplingTransactionBuild),
        CapabilityStatus.experimental,
      );
    });

    test(
      'reports sapling nativeTransactionBuild as unsupported in the matrix',
      () {
        expect(
          ShieldedCapabilityMatrix.current.statusFor(
            ShieldedPool.sapling,
            CapabilitySurface.nativeTransactionBuild,
          ),
          CapabilityStatus.unsupported,
        );
      },
    );
  });

  group('SaplingFeeQuote', () {
    Map<String, Object?> validQuote() => {
      'quote_only': true,
      'network': 'regtest',
      'fee_zatoshis': 15000,
      'fee_rule': 'zip317',
      'consensus_branch_id': 'nu6.3',
      'total_input_zatoshis': 100000,
      'stated_output_zatoshis': 0,
      'max_output_zatoshis': 85000,
      'sapling_spends': 0,
      'transparent_inputs': 1,
      'outputs': 1,
    };

    test('parses a quote and reports it as funded', () {
      final quote = SaplingFeeQuote.fromJson(validQuote());
      expect(quote.feeZatoshis, 15000);
      expect(quote.feeRule, 'zip317');
      expect(quote.consensusBranchId, 'nu6.3');
      expect(quote.totalInputZatoshis, 100000);
      expect(quote.maxOutputZatoshis, 85000);
      expect(quote.isFunded, isTrue);
    });

    test('a shortfall is a null and not an error', () {
      final json = validQuote()..['max_output_zatoshis'] = null;
      final quote = SaplingFeeQuote.fromJson(json);
      expect(quote.maxOutputZatoshis, isNull);
      expect(quote.isFunded, isFalse);
      expect(
        quote.feeZatoshis,
        15000,
        reason: 'the fee is what tells the caller how much more to add',
      );
    });

    test('refuses to parse a build result as a quote', () {
      final json = validQuote()..remove('quote_only');
      expect(
        () => SaplingFeeQuote.fromJson(json),
        throwsA(isA<ZcashModelException>()),
      );
    });
  });
}
