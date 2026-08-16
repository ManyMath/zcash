import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

const _ironwoodAnchor =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
const _recipient = 'uregtest1recipient';
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
      pool: 'ironwood',
      nullifier: nullifier,
      commitmentPosition: 0,
      isChange: false,
      recipient: 'uregtest1example',
      rseed: '11' * 32,
      rho: '22' * 32,
      noteVersion: 'v3',
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
  ironwoodAnchor: _ironwoodAnchor,
);

int _stubFee(List<ZcashScannedNote> spends) =>
    5000 * (spends.length < 2 ? 2 : spends.length);

IronwoodSendPlan _plan() => IronwoodSendPlan.fromScan(
  scan: _scan(notes: [_note()]),
  recipientAddress: _recipient,
  amountZatoshis: 50000,
  targetHeight: 300,
  feeForSpends: _stubFee,
);

IronwoodPreparedSend _prepared({int expiryHeight = 340}) {
  final plan = _plan();
  return IronwoodPreparedSend(
    plan: plan,
    transaction: IronwoodBuildResult(
      network: ZcashAddressNetwork.regtest,
      transactionHex: 'ff' * 20,
      txid: _txid,
      version: 'v6',
      consensusBranchId: 'nu6.3',
      expiryHeight: expiryHeight,
      feeZatoshis: plan.feeZatoshis,
      feeRule: 'zip317',
      proofValidity: 'real',
      ironwoodAnchor: plan.anchorHex,
      ironwoodAnchorSource: 'anchor',
      vin: 0,
      vout: 0,
      ironwoodActions: 2,
      ironwoodSpends: plan.notes.length,
      ironwoodChangeOutputs: 1,
      totalInputZatoshis: plan.inputZatoshis,
      ironwoodInputZatoshis: plan.inputZatoshis,
      ironwoodChangeZatoshis: plan.changeZatoshis,
      nonIronwoodOutputZatoshis: 0,
      ironwoodOutputZatoshis: plan.amountZatoshis,
      rng: 'system',
    ),
  );
}

class _NodeSaidNo implements Exception {}

void main() {
  group('reverseTxidByteOrder', () {
    test('is its own inverse and actually reverses', () {
      final scanOrder = reverseTxidByteOrder(_txid);

      expect(scanOrder, isNot(_txid));
      expect(scanOrder.substring(0, 2), _txid.substring(62, 64));
      expect(reverseTxidByteOrder(scanOrder), _txid);
    });

    test('refuses anything that is not a 32-byte hash', () {
      expect(() => reverseTxidByteOrder('abcd'), throwsFormatException);
    });
  });

  group('broadcastIronwoodSend', () {
    test('hands the transaction over and names it both ways', () async {
      final send = _prepared();
      var submitted = '';

      final receipt = await broadcastIronwoodSend(
        send: send,
        chainHeight: 299,
        submit: (hex) async {
          submitted = hex;
          return _txid;
        },
      );

      expect(submitted, send.transactionHex);
      expect(receipt.txid, _txid);
      expect(receipt.scanTxId, reverseTxidByteOrder(_txid));
      expect(receipt.broadcastAtHeight, 299);
      expect(receipt.expiryHeight, 340);
      expect(receipt.committedNullifiers, {_nullifier});
    });

    test(
      'accepts a transport that acknowledges without echoing an id',
      () async {
        final receipt = await broadcastIronwoodSend(
          send: _prepared(),
          submit: (_) async => '',
        );

        expect(receipt.txid, _txid);
      },
    );

    test('refuses to send a payment the chain has already outlived', () async {
      var called = false;

      await expectLater(
        broadcastIronwoodSend(
          send: _prepared(expiryHeight: 340),
          chainHeight: 341,
          submit: (_) async {
            called = true;
            return _txid;
          },
        ),
        throwsA(
          isA<IronwoodBroadcastException>()
              .having(
                (e) => e.refusal,
                'refusal',
                IronwoodBroadcastRefusal.expired,
              )
              .having(
                (e) => e.notesRemainCommitted,
                'notesRemainCommitted',
                isFalse,
              ),
        ),
      );
      expect(called, isFalse, reason: 'nothing was sent');
    });

    test(
      'treats an unclassified failure as undetermined, not as a failure',
      () async {
        await expectLater(
          broadcastIronwoodSend(
            send: _prepared(),
            submit: (_) async => throw Exception('connection reset'),
          ),
          throwsA(
            isA<IronwoodBroadcastException>()
                .having(
                  (e) => e.refusal,
                  'refusal',
                  IronwoodBroadcastRefusal.undetermined,
                )
                .having(
                  (e) => e.notesRemainCommitted,
                  'notesRemainCommitted',
                  isTrue,
                ),
          ),
        );
      },
    );

    test(
      'frees the notes only when the caller can say the node refused',
      () async {
        await expectLater(
          broadcastIronwoodSend(
            send: _prepared(),
            submit: (_) async => throw _NodeSaidNo(),
            isRejection: (error) => error is _NodeSaidNo,
          ),
          throwsA(
            isA<IronwoodBroadcastException>()
                .having(
                  (e) => e.refusal,
                  'refusal',
                  IronwoodBroadcastRefusal.rejected,
                )
                .having(
                  (e) => e.notesRemainCommitted,
                  'notesRemainCommitted',
                  isFalse,
                ),
          ),
        );
      },
    );

    test('refuses an acknowledgement naming a different transaction', () async {
      await expectLater(
        broadcastIronwoodSend(
          send: _prepared(),
          submit: (_) async => 'ee' * 32,
        ),
        throwsA(
          isA<IronwoodBroadcastException>()
              .having(
                (e) => e.refusal,
                'refusal',
                IronwoodBroadcastRefusal.txidMismatch,
              )
              .having(
                (e) => e.notesRemainCommitted,
                'notesRemainCommitted',
                isTrue,
              ),
        ),
      );
    });
  });

  group('IronwoodBroadcastReceipt', () {
    Future<IronwoodBroadcastReceipt> receipt() =>
        broadcastIronwoodSend(send: _prepared(), submit: (_) async => _txid);

    test('recognises its own transaction in a later scan', () async {
      final r = await receipt();
      final scan = _scan(
        spends: [
          ZcashObservedSpend(
            height: 305,
            tx: r.scanTxId,
            pool: 'ironwood',
            nullifier: _nullifier,
            index: 0,
          ),
        ],
      );

      expect(r.isConfirmedBy(scan), isTrue);
      expect(r.confirmationIn(scan)!.height, 305);
    });

    test('does not recognise it under the displayed byte order', () async {
      final r = await receipt();
      final scan = _scan(
        spends: [
          ZcashObservedSpend(
            height: 305,
            tx: _txid,
            pool: 'ironwood',
            nullifier: _nullifier,
            index: 0,
          ),
        ],
      );

      expect(r.isConfirmedBy(scan), isFalse);
    });

    test('does not accept another pool\'s spend of the same bytes', () async {
      final r = await receipt();
      final scan = _scan(
        spends: [
          ZcashObservedSpend(
            height: 305,
            tx: r.scanTxId,
            pool: 'orchard',
            nullifier: _nullifier,
            index: 0,
          ),
        ],
      );

      expect(r.isConfirmedBy(scan), isFalse);
    });

    test('is not confirmed by a scan that saw nothing', () async {
      final r = await receipt();

      expect(r.isConfirmedBy(_scan()), isFalse);
      expect(r.confirmationIn(_scan()), isNull);
    });

    test('reports when the chain has passed its expiry', () async {
      final r = await receipt();

      expect(r.hasExpiredAt(339), isFalse);
      expect(r.hasExpiredAt(340), isTrue);
      expect(r.hasExpiredAt(341), isTrue);
    });
  });
}
