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
}
