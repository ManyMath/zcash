import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

const _account = 'history-account';

ZcashScannedNote _note({
  required int value,
  required String nullifier,
  required String tx,
  String pool = 'ironwood',
  int output = 0,
  int height = 200,
}) => ZcashScannedNote(
  height: height,
  tx: tx * 32,
  output: output,
  value: value,
  pool: pool,
  nullifier: nullifier,
  commitmentPosition: 0,
  isChange: false,
  recipient: 'uregtest1example',
  rseed: '11' * 32,
  rho: pool == 'sapling' ? null : '22' * 32,
  noteVersion: pool == 'sapling' ? null : (pool == 'ironwood' ? 'v3' : 'v2'),
  witness: '33' * 40,
);

ZcashObservedSpend _spend({
  required String nullifier,
  required String tx,
  String pool = 'ironwood',
  int height = 300,
}) => ZcashObservedSpend(
  height: height,
  tx: tx * 32,
  pool: pool,
  nullifier: nullifier,
  index: 0,
);

ZcashScanResult _scan(
  int from,
  int to, {
  List<ZcashScannedNote> notes = const [],
  List<ZcashObservedSpend> spends = const [],
}) => ZcashScanResult(
  scannedBlocks: to - from + 1,
  discoveredNotes: notes.length,
  totalValue: notes.fold(0, (sum, note) => sum + note.value),
  notes: notes,
  spends: spends,
  scannedHeightRange: CompactBlockScanRange(start: from, end: to),
);

void main() {
  test('a note paid to the wallet is an incoming entry', () {
    final ironwood = IronwoodNoteStore()
      ..apply(
        _scan(
          100,
          250,
          notes: [_note(value: 500000, nullifier: 'n1' * 16, tx: 'a1')],
        ),
        accountFingerprint: _account,
      );

    final entry = ZcashTransactionHistory.fromStores(
      ironwood: ironwood,
    ).entries.single;
    expect(entry.receivedZatoshis, 500000);
    expect(entry.spentZatoshis, 0);
    expect(entry.netZatoshis, 500000);
    expect(entry.isOutgoing, isFalse);
    expect(entry.height, 200);
    expect(entry.txid, reverseTxidByteOrder('a1' * 32));
  });

  test('a payment with change nets to what left the wallet', () {
    final ironwood = IronwoodNoteStore()
      ..apply(
        _scan(
          100,
          400,
          notes: [
            _note(value: 500000, nullifier: 'n1' * 16, tx: 'a1', height: 200),
            _note(value: 120000, nullifier: 'n2' * 16, tx: 'b2', height: 300),
          ],
          spends: [_spend(nullifier: 'n1' * 16, tx: 'b2', height: 300)],
        ),
        accountFingerprint: _account,
      );

    final entries = ZcashTransactionHistory.fromStores(
      ironwood: ironwood,
    ).entries;
    expect(entries.map((e) => e.height), [300, 200], reason: 'newest first');
    final payment = entries.first;
    expect(payment.isOutgoing, isTrue);
    expect(payment.spentZatoshis, 500000);
    expect(payment.receivedZatoshis, 120000);
    expect(payment.netZatoshis, -380000, reason: 'sent plus fee');
  });

  test('a spend is valued by pool and nullifier, never by bytes alone', () {
    final sapling = SaplingNoteStore()
      ..apply(
        _scan(
          100,
          400,
          notes: [
            _note(
              value: 700000,
              nullifier: 'aa' * 32,
              tx: 'a1',
              pool: 'sapling',
            ),
          ],
        ),
        accountFingerprint: _account,
      );
    final ironwood = IronwoodNoteStore()
      ..apply(
        _scan(
          100,
          400,
          spends: [_spend(nullifier: 'aa' * 32, tx: 'c3')],
        ),
        accountFingerprint: _account,
      );

    final spendEntry = ZcashTransactionHistory.fromStores(
      sapling: sapling,
      ironwood: ironwood,
    ).entries.firstWhere((e) => e.protocolTxid == 'c3' * 32);
    expect(spendEntry.spentZatoshis, 0);
    expect(spendEntry.unvaluedSpends, 1);
    expect(spendEntry.isOutgoing, isTrue);
  });

  test('a rollback takes the abandoned chain out of the history', () {
    final ironwood = IronwoodNoteStore()
      ..apply(
        _scan(
          100,
          400,
          notes: [
            _note(value: 500000, nullifier: 'n1' * 16, tx: 'a1', height: 200),
            _note(value: 90000, nullifier: 'n2' * 16, tx: 'b2', height: 350),
          ],
        ),
        accountFingerprint: _account,
      )
      ..rollbackTo(300);

    final entries = ZcashTransactionHistory.fromStores(
      ironwood: ironwood,
    ).entries;
    expect(entries.map((e) => e.protocolTxid), ['a1' * 32]);
  });

  test('a wallet with no stores has no history', () {
    expect(ZcashTransactionHistory.fromStores().entries, isEmpty);
  });
}
