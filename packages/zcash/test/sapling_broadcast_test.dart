import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

const _saplingAnchor =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
const _recipient = 'zregtestsapling1recipient';
const _change = 'zregtestsapling1mine';
const _txid =
    '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';
const _nullifier =
    'ab00000000000000000000000000000000000000000000000000000000000000';

ZcashScannedNote _note({int value = 100000, String nullifier = _nullifier}) =>
    ZcashScannedNote(
      height: 200,
      tx: 'aa' * 32,
      output: 0,
      value: value,
      pool: 'sapling',
      nullifier: nullifier,
      commitmentPosition: 0,
      isChange: false,
      recipient: 'zregtestsapling1example',
      rseed: '11' * 32,
      witness: '33' * 40,
    );

ZcashScanResult _scan({
  List<ZcashScannedNote> notes = const [],
  List<ZcashObservedSpend> spends = const [],
}) => ZcashScanResult(
  scannedBlocks: 10,
  discoveredNotes: notes.length,
  totalValue: 0,
  notes: notes,
  spends: spends,
  saplingAnchor: _saplingAnchor,
);

int _stubFee(List<ZcashScannedNote> spends) =>
    5000 * (spends.length < 2 ? 2 : spends.length);

SaplingSendPlan _plan() => SaplingSendPlan.fromScan(
  scan: _scan(notes: [_note()]),
  recipientAddress: _recipient,
  changeAddress: _change,
  amountZatoshis: 50000,
  targetHeight: 300,
  feeForSpends: _stubFee,
);

SaplingPreparedSend _prepared({int expiryHeight = 340}) {
  final plan = _plan();
  return SaplingPreparedSend(
    plan: plan,
    transaction: SaplingBuildResult(
      network: ZcashAddressNetwork.regtest,
      transactionHex: 'ff' * 20,
      txid: _txid,
      version: 'v6',
      consensusBranchId: 'nu6.3',
      expiryHeight: expiryHeight,
      feeZatoshis: plan.feeZatoshis,
      proofValidity: 'real',
      transparentVin: 0,
      transparentVout: 0,
      saplingSpends: plan.notes.length,
      saplingOutputs: 2,
      totalSpentZatoshis: plan.inputZatoshis,
      totalOutputZatoshis: plan.amountZatoshis + plan.changeZatoshis,
    ),
  );
}

String get _scanTxId {
  final bytes = [
    for (var i = 0; i < _txid.length; i += 2) _txid.substring(i, i + 2),
  ];
  return bytes.reversed.join();
}

ZcashObservedSpend _spend({
  String pool = 'sapling',
  String? tx,
  String nullifier = _nullifier,
}) => ZcashObservedSpend(
  height: 320,
  tx: tx ?? _scanTxId,
  pool: pool,
  nullifier: nullifier,
  index: 0,
);

void main() {
  group('broadcastSaplingSend', () {
    test('a submitted payment comes back as a receipt with both names', () {
      return expectLater(
        broadcastSaplingSend(
          send: _prepared(),
          submit: (hex) async => _txid,
          chainHeight: 300,
        ).then((receipt) {
          expect(receipt.txid, _txid);
          expect(
            receipt.scanTxId,
            isNot(receipt.txid),
            reason: 'the two encodings of one hash are not the same string',
          );
          expect(receipt.committedNullifiers, {_nullifier});
          expect(receipt.hasExpiredAt(300), isFalse);
          expect(
            receipt.hasExpiredAt(339),
            isFalse,
            reason: 'planned at 339 it is mined at 340, its last legal block',
          );
          expect(
            receipt.hasExpiredAt(340),
            isTrue,
            reason:
                'a transaction may be mined at its expiry height but not past '
                'it, so planning at 340 means a block at 341 — too late',
          );
          expect(receipt.hasExpiredAt(341), isTrue);
        }),
        completes,
      );
    });

    test('an undetermined failure is not a failure, and holds the notes', () {
      expect(
        broadcastSaplingSend(
          send: _prepared(),
          submit: (hex) async => throw StateError('socket closed'),
        ),
        throwsA(
          isA<SaplingBroadcastException>()
              .having(
                (e) => e.refusal,
                'refusal',
                SaplingBroadcastRefusal.undetermined,
              )
              .having((e) => e.notesRemainCommitted, 'committed', isTrue),
        ),
      );
    });

    test('a rejection the caller can identify frees the notes', () {
      expect(
        broadcastSaplingSend(
          send: _prepared(),
          submit: (hex) async => throw StateError('bad-txns'),
          isRejection: (error) => error is StateError,
        ),
        throwsA(
          isA<SaplingBroadcastException>()
              .having(
                (e) => e.refusal,
                'refusal',
                SaplingBroadcastRefusal.rejected,
              )
              .having((e) => e.notesRemainCommitted, 'committed', isFalse),
        ),
      );
    });

    test('an expired payment is refused locally, never sent', () {
      var submitted = false;
      expect(
        broadcastSaplingSend(
          send: _prepared(expiryHeight: 310),
          submit: (hex) async {
            submitted = true;
            return _txid;
          },
          chainHeight: 311,
        ),
        throwsA(
          isA<SaplingBroadcastException>()
              .having(
                (e) => e.refusal,
                'refusal',
                SaplingBroadcastRefusal.expired,
              )
              .having((e) => e.notesRemainCommitted, 'committed', isFalse),
        ),
      );
      expect(submitted, isFalse);
    });

    test('an acknowledgement naming another transaction is fatal', () {
      expect(
        broadcastSaplingSend(
          send: _prepared(),
          submit: (hex) async => 'dd' * 32,
        ),
        throwsA(
          isA<SaplingBroadcastException>()
              .having(
                (e) => e.refusal,
                'refusal',
                SaplingBroadcastRefusal.txidMismatch,
              )
              .having((e) => e.notesRemainCommitted, 'committed', isTrue),
        ),
      );
    });

    test('a transport that echoes no id is not a mismatch', () async {
      final receipt = await broadcastSaplingSend(
        send: _prepared(),
        submit: (hex) async => '',
      );
      expect(receipt.txid, _txid);
    });
  });

  group('SaplingBroadcastReceipt.confirmationIn', () {
    Future<SaplingBroadcastReceipt> receipt() =>
        broadcastSaplingSend(send: _prepared(), submit: (hex) async => _txid);

    test('finds the payment in a later scan', () async {
      final r = await receipt();
      final scan = _scan(spends: [_spend()]);

      expect(r.isConfirmedBy(scan), isTrue);
      expect(r.confirmationIn(scan)!.height, 320);
    });

    test('the displayed byte order never matches, and never complains', () {
      return receipt().then((r) {
        final scan = _scan(spends: [_spend(tx: _txid)]);
        expect(r.isConfirmedBy(scan), isFalse);
      });
    });

    test('the same nullifier spent in another pool is not a confirmation', () {
      return receipt().then((r) {
        final scan = _scan(spends: [_spend(pool: 'ironwood')]);
        expect(r.isConfirmedBy(scan), isFalse);
      });
    });

    test('another transaction spending another note is not a confirmation', () {
      return receipt().then((r) {
        final scan = _scan(spends: [_spend(nullifier: 'ff' * 32)]);
        expect(r.isConfirmedBy(scan), isFalse);
      });
    });

    test('a scan that has seen nothing confirms nothing', () {
      return receipt().then((r) {
        expect(r.isConfirmedBy(_scan()), isFalse);
        expect(r.confirmationIn(_scan()), isNull);
      });
    });
  });
}
