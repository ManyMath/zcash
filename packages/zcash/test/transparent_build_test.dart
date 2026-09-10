import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

void main() {
  group('TransparentBuildResult', () {
    Map<String, Object?> validJson() => {
      'network': 'regtest',
      'transaction': '00' * 64,
      'txid': 'ab' * 32,
      'version': 'v5',
      'expiry_height': 30,
      'fee_zatoshis': 10000,
      'transparent': {'vin': 1, 'vout': 1},
      'total_input_zatoshis': 100000,
      'total_output_zatoshis': 90000,
    };

    test('parses a complete native build result', () {
      final result = TransparentBuildResult.fromJson(validJson());
      expect(result.network, ZcashAddressNetwork.regtest);
      expect(result.transactionHex, '00' * 64);
      expect(result.txid, 'ab' * 32);
      expect(result.version, 'v5');
      expect(result.expiryHeight, 30);
      expect(result.feeZatoshis, 10000);
      expect(result.vin, 1);
      expect(result.vout, 1);
      expect(result.totalInputZatoshis, 100000);
      expect(result.totalOutputZatoshis, 90000);
    });

    test('rejects a malformed (odd-length) transaction hex', () {
      final json = validJson()..['transaction'] = 'abc';
      expect(
        () => TransparentBuildResult.fromJson(json),
        throwsA(isA<ZcashModelException>()),
      );
    });

    test('rejects a txid that is not 32 bytes', () {
      final json = validJson()..['txid'] = 'ab' * 16;
      expect(
        () => TransparentBuildResult.fromJson(json),
        throwsA(isA<ZcashModelException>()),
      );
    });

    test('rejects a non-hex txid without echoing it', () {
      final json = validJson()..['txid'] = 'zz' * 32;
      expect(
        () => TransparentBuildResult.fromJson(json),
        throwsA(isA<ZcashModelException>()),
      );
    });
  });

  group('capability matrix', () {
    test(
      'documents transparent transaction build as unsupported by default',
      () {
        expect(
          NativeCapabilitySnapshot.documented.statusFor(
            NativeCapability.transparentTransactionBuild,
          ),
          CapabilityStatus.unsupported,
        );
      },
    );

    test('round-trips the new native capability key through JSON', () {
      final snapshot = NativeCapabilitySnapshot.fromJson({
        'capabilities': {
          'unified_address_derivation': 'supported',
          'transparent_address_derivation': 'supported',
          'sapling_scan': 'supported',
          'equihash_solver': 'supported',
          'orchard_receiver_exposure': 'exposed',
          'orchard_compact_block_parsing': 'parsedOnly',
          'orchard_note_discovery': 'unsupported',
          'transparent_transaction_build': 'experimental',
        },
      });
      expect(
        snapshot.statusFor(NativeCapability.transparentTransactionBuild),
        CapabilityStatus.experimental,
      );
    });

    test('reports transparent walletSend as unsupported in the matrix', () {
      expect(
        ShieldedCapabilityMatrix.current.statusFor(
          ShieldedPool.transparent,
          CapabilitySurface.walletSend,
        ),
        CapabilityStatus.unsupported,
      );
    });
  });
}
