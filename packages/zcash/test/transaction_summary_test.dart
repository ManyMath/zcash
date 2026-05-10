import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

void main() {
  group('ZcashTransactionSummary', () {
    Map<String, dynamic> v5Json() => {
      'ffi_result_version': 1,
      'status': 'ok',
      'network': 'mainnet',
      'txid':
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'version': 'v5',
      'header': 2147483653,
      'version_group_id': 654776626,
      'consensus_branch_id': 'nu5',
      'consensus_branch_id_hex': 'c2d6d0b4',
      'lock_time': 0,
      'expiry_height': 0,
      'transparent': {'present': true, 'vin': 1, 'vout': 2},
      'sapling': {'present': false, 'spends': 0, 'outputs': 0},
      'orchard': {'present': true, 'actions': 3},
      'sprout': {'present': false, 'joinsplits': 0},
    };

    test('parses a v5 summary with bundle counts', () {
      final summary = ZcashTransactionSummary.fromJson(v5Json());

      expect(summary.network, ZcashAddressNetwork.mainnet);
      expect(summary.version, ZcashTransactionVersion.v5);
      expect(summary.consensusBranchId, 'nu5');
      expect(summary.consensusBranchIdHex, 'c2d6d0b4');
      expect(summary.transparent.present, isTrue);
      expect(summary.transparent.vin, 1);
      expect(summary.transparent.vout, 2);
      expect(summary.sapling.present, isFalse);
      expect(summary.orchard.present, isTrue);
      expect(summary.orchard.actions, 3);
      expect(summary.sprout.present, isFalse);
    });

    test('round-trips through toJson', () {
      final summary = ZcashTransactionSummary.fromJson(v5Json());
      final json = summary.toJson();

      expect(json['version'], 'v5');
      expect(json['consensus_branch_id'], 'nu5');
      expect((json['transparent']! as Map)['vin'], 1);
      expect((json['orchard']! as Map)['actions'], 3);

      final reparsed = ZcashTransactionSummary.fromJson(
        json.cast<String, dynamic>(),
      );
      expect(reparsed.txid, summary.txid);
      expect(reparsed.orchard.actions, 3);
    });

    test('parses a pre-v5 summary with null consensus branch id', () {
      final summary = ZcashTransactionSummary.fromJson({
        'network': 'testnet',
        'txid':
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb0',
        'version': 'v4',
        'header': 2147483652,
        'version_group_id': 2301567109,
        'consensus_branch_id': null,
        'consensus_branch_id_hex': null,
        'lock_time': 0,
        'expiry_height': 0,
        'transparent': {'present': false, 'vin': 0, 'vout': 0},
        'sapling': {'present': false, 'spends': 0, 'outputs': 0},
        'orchard': {'present': false, 'actions': 0},
        'sprout': {'present': false, 'joinsplits': 0},
      });

      expect(summary.version, ZcashTransactionVersion.v4);
      expect(summary.consensusBranchId, isNull);
      expect(summary.consensusBranchIdHex, isNull);
      expect(summary.toJson()['consensus_branch_id'], isNull);
    });

    test('rejects an unknown transaction version', () {
      expect(
        () => ZcashTransactionVersion.fromJson('v99'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('ZcashTransactionId', () {
    test('parses txid and v5 auth digest', () {
      final txid = 'a' * 64;
      final auth = 'b' * 64;
      final id = ZcashTransactionId.fromJson({
        'txid': txid,
        'auth_digest': auth,
      });
      expect(id.txid, txid);
      expect(id.authDigest, auth);
      expect(id.toJson()['auth_digest'], auth);
    });

    test('parses a null auth digest for pre-v5', () {
      final txid = 'c' * 64;
      final id = ZcashTransactionId.fromJson({
        'txid': txid,
        'auth_digest': null,
      });
      expect(id.txid, txid);
      expect(id.authDigest, isNull);
      expect(id.toJson()['auth_digest'], isNull);
    });

    test('rejects a malformed txid', () {
      expect(
        () => ZcashTransactionId.fromJson({'txid': 'not-hex'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects a malformed auth digest', () {
      expect(
        () => ZcashTransactionId.fromJson({
          'txid': 'd' * 64,
          'auth_digest': 'zz',
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
