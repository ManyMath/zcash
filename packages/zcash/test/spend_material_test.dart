import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

const _account = 'account-7';
const _tx = '1111111111111111111111111111111111111111111111111111111111111111';
const _nullifier =
    '2222222222222222222222222222222222222222222222222222222222222222';

ZcashScannedNote _ironwoodNote({int height = 20, String? witness}) =>
    ZcashScannedNote(
      height: height,
      tx: _tx,
      output: 0,
      value: 50000,
      pool: 'ironwood',
      nullifier: _nullifier,
      commitmentPosition: 3,
      witness: witness,
      recipient: 'u1test',
      rseed: '3333333333333333333333333333333333333333333333333333333333333333',
      rho: '4444444444444444444444444444444444444444444444444444444444444444',
      noteVersion: 'v3',
    );

void main() {
  group('ZcashSpendMaterialRequest', () {
    test('captures only durable Ironwood note identity', () {
      final request = ZcashSpendMaterialRequest.ironwood(
        accountFingerprint: _account,
        notes: [_ironwoodNote(witness: 'aa')],
        anchorHeight: 25,
      );

      expect(request.accountFingerprint, _account);
      expect(request.anchorHeight, 25);
      expect(request.pool, 'ironwood');
      expect(request.noteIdentities, hasLength(1));
      expect(request.noteIdentities.single.tx, _tx);
      expect(request.noteIdentities.single.nullifier, _nullifier);
      expect(request.toString(), isNot(contains(_nullifier)));
      expect(request.toString(), isNot(contains('aa')));
    });

    test('rejects an anchor before the note', () {
      expect(
        () => ZcashSpendMaterialRequest.ironwood(
          accountFingerprint: _account,
          notes: [_ironwoodNote(height: 20)],
          anchorHeight: 19,
        ),
        throwsA(
          isA<ZcashModelException>().having(
            (e) => e.message,
            'message',
            contains('predates'),
          ),
        ),
      );
    });
  });
}
