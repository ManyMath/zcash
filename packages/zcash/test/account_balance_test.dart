import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

ZcashScannedNote _note({
  required String pool,
  required int value,
  String? nullifier,
  bool complete = true,
  bool witness = true,
}) => ZcashScannedNote(
  height: 200,
  tx: 'aa' * 32,
  output: 0,
  value: value,
  pool: pool,
  nullifier: nullifier,
  commitmentPosition: 0,
  isChange: false,
  recipient: complete
      ? (pool == 'sapling' ? 'zregtestsapling1example' : 'uregtest1example')
      : null,
  rseed: complete ? '11' * 32 : null,
  rho: complete && pool != 'sapling' ? '22' * 32 : null,
  noteVersion: complete && pool != 'sapling'
      ? (pool == 'orchard' ? 'v2' : 'v3')
      : null,
  witness: complete && witness ? '33' * 40 : null,
);

ZcashObservedSpend _spend({required String pool, required String nullifier}) =>
    ZcashObservedSpend(
      height: 210,
      tx: 'bb' * 32,
      pool: pool,
      nullifier: nullifier,
      index: 0,
    );

ZcashScanResult _scan({
  List<ZcashScannedNote> notes = const [],
  List<ZcashObservedSpend> spends = const [],
}) => ZcashScanResult(
  scannedBlocks: 10,
  discoveredNotes: notes.length,
  totalValue: notes.fold(0, (sum, note) => sum + note.value),
  notes: notes,
  spends: spends,
);

TransparentCoinSet _transparent(
  List<AddressUtxo> utxos, {
  int chainHeight = 500,
  Set<String> coinbase = const {},
}) => TransparentCoinSet.fromUtxos(
  utxos: utxos,
  chainHeight: chainHeight,
  coinbaseOutpoints: coinbase,
);

AddressUtxo _utxo(int satoshis) => AddressUtxo(
  address: 'tmExample',
  txid: 'cc' * 32,
  outputIndex: 0,
  script: '76a914',
  satoshis: satoshis,
  height: 100,
);

void main() {
  group('ZcashAccountBalance', () {
    test('sorts one scan into three pools plus transparent', () {
      final balance = ZcashAccountBalance.fromScan(
        scan: _scan(
          notes: [
            _note(pool: 'sapling', value: 100000, nullifier: 'a1' * 32),
            _note(pool: 'orchard', value: 200000, nullifier: 'a2' * 32),
            _note(pool: 'ironwood', value: 400000, nullifier: 'a3' * 32),
          ],
        ),
        transparent: _transparent([_utxo(50000)]),
      );

      expect(balance.byPool, {
        'sapling': 100000,
        'orchard': 200000,
        'ironwood': 400000,
        'transparent': 50000,
      });
      expect(balance.totalZatoshis, 750000);
      expect(balance.transparentZatoshis, 50000);
      expect(balance.isFullyUsable, isTrue);
    });

    test('Orchard value is migratable and never counted as spendable', () {
      final balance = ZcashAccountBalance.fromScan(
        scan: _scan(
          notes: [
            _note(pool: 'sapling', value: 100000, nullifier: 'a1' * 32),
            _note(pool: 'orchard', value: 900000, nullifier: 'a2' * 32),
          ],
        ),
      );

      expect(balance.spendableZatoshis, 100000);
      expect(balance.migratableZatoshis, 900000);
      expect(
        balance.totalZatoshis,
        1000000,
        reason: 'it is still the wallet\'s money and must still be shown',
      );
      expect(balance.capabilities['orchard'], ZcashPoolCapability.migratable);
      expect(balance.capabilities['ironwood'], ZcashPoolCapability.spendable);
    });

    test('transparent value is not folded into the spendable total', () {
      final balance = ZcashAccountBalance.fromScan(
        scan: _scan(),
        transparent: _transparent([_utxo(700000)]),
      );

      expect(balance.spendableZatoshis, 0);
      expect(balance.totalZatoshis, 700000);
      expect(
        balance.capabilities['transparent'],
        ZcashPoolCapability.shieldable,
      );
    });

    test('a spend in one pool never removes another pool\'s note', () {
      final shared = 'ab' * 32;
      final balance = ZcashAccountBalance.fromScan(
        scan: _scan(
          notes: [
            _note(pool: 'sapling', value: 100000, nullifier: shared),
            _note(pool: 'orchard', value: 200000, nullifier: shared),
            _note(pool: 'ironwood', value: 400000, nullifier: shared),
          ],
          spends: [_spend(pool: 'sapling', nullifier: shared)],
        ),
      );

      expect(balance.byPool['sapling'], 0);
      expect(balance.byPool['orchard'], 200000);
      expect(balance.byPool['ironwood'], 400000);
      expect(balance.totalZatoshis, 600000);
    });

    test('notes that cannot be moved are money, and are reported as such', () {
      final balance = ZcashAccountBalance.fromScan(
        scan: _scan(
          notes: [
            _note(
              pool: 'sapling',
              value: 100000,
              nullifier: 'a1' * 32,
              witness: false,
            ),
            _note(pool: 'ironwood', value: 400000, nullifier: null),
          ],
        ),
      );

      expect(balance.spendableZatoshis, 0);
      expect(balance.totalZatoshis, 500000);
      expect(balance.unusableZatoshis, 500000);
      expect(balance.isFullyUsable, isFalse);
    });

    test('an empty wallet is zero everywhere and fully usable', () {
      final balance = ZcashAccountBalance.fromScan(scan: _scan());

      expect(balance.totalZatoshis, 0);
      expect(balance.spendableZatoshis, 0);
      expect(balance.migratableZatoshis, 0);
      expect(balance.unusableZatoshis, 0);
      expect(
        balance.isFullyUsable,
        isTrue,
        reason: 'nothing is missing from a wallet that holds nothing',
      );
    });

    test('an immature coinbase coin is held, and not usable', () {
      final coin = _utxo(625000000);
      final balance = ZcashAccountBalance.fromScan(
        scan: _scan(),
        transparent: _transparent(
          [coin],
          chainHeight: 150,
          coinbase: {'${coin.txid}:0'},
        ),
      );

      expect(balance.totalZatoshis, 625000000);
      expect(balance.unusableZatoshis, 625000000);
      expect(balance.isFullyUsable, isFalse);
      expect(balance.transparent.nextMaturityHeight, 100 + 99);
    });

    test('the per-pool sets are the ones a send path takes', () {
      final balance = ZcashAccountBalance.fromScan(
        scan: _scan(
          notes: [
            _note(pool: 'sapling', value: 100000, nullifier: 'a1' * 32),
            _note(pool: 'ironwood', value: 400000, nullifier: 'a3' * 32),
          ],
        ),
      );

      expect(balance.sapling, isA<SaplingNoteSet>());
      expect(balance.ironwood, isA<IronwoodNoteSet>());
      expect(balance.orchard, isA<OrchardNoteSet>());
      expect(balance.sapling.spendable.single.pool, 'sapling');
      expect(balance.ironwood.spendable.single.pool, 'ironwood');
    });
  });

  group('ZcashAccountBalance.fromStores', () {
    ZcashScanResult ranged(ZcashScanResult scan) => ZcashScanResult(
      scannedBlocks: scan.scannedBlocks,
      discoveredNotes: scan.discoveredNotes,
      totalValue: scan.totalValue,
      notes: scan.notes,
      spends: scan.spends,
      scannedHeightRange: const CompactBlockScanRange(start: 1, end: 500),
    );

    test('over one scan it holds the same money as the scan does', () {
      final scan = _scan(
        notes: [
          _note(pool: 'sapling', value: 100000, nullifier: 'a1' * 32),
          _note(pool: 'orchard', value: 200000, nullifier: 'a2' * 32),
          _note(pool: 'ironwood', value: 400000, nullifier: 'a3' * 32),
        ],
      );
      final transparent = _transparent([_utxo(50000)]);
      final fromScan = ZcashAccountBalance.fromScan(
        scan: scan,
        transparent: transparent,
      );

      final sapling = SaplingNoteStore()
        ..apply(ranged(scan), accountFingerprint: 'account-a');
      final orchard = OrchardNoteStore()
        ..apply(ranged(scan), accountFingerprint: 'account-a');
      final ironwood = IronwoodNoteStore()
        ..apply(ranged(scan), accountFingerprint: 'account-a');
      final fromStores = ZcashAccountBalance.fromStores(
        sapling: sapling,
        orchard: orchard,
        ironwood: ironwood,
        transparent: transparent,
      );

      expect(fromStores.totalZatoshis, fromScan.totalZatoshis);
      expect(fromStores.byPool, fromScan.byPool);
      expect(fromStores.untrackableZatoshis, fromScan.untrackableZatoshis);

      expect(fromScan.spendableZatoshis, 500000);
      expect(fromStores.spendableZatoshis, 0);
      expect(fromStores.migratableZatoshis, 0);
      expect(fromStores.unusableZatoshis, 700000);
      expect(fromStores.isFullyUsable, isFalse);
    });

    test('untrackable value is named, not folded away', () {
      final scan = _scan(
        notes: [
          _note(pool: 'ironwood', value: 250000),
          _note(pool: 'sapling', value: 100000, nullifier: 'a1' * 32),
        ],
      );
      final balance = ZcashAccountBalance.fromStores(
        sapling: SaplingNoteStore()
          ..apply(ranged(scan), accountFingerprint: 'account-a'),
        orchard: OrchardNoteStore()
          ..apply(ranged(scan), accountFingerprint: 'account-a'),
        ironwood: IronwoodNoteStore()
          ..apply(ranged(scan), accountFingerprint: 'account-a'),
      );

      expect(balance.untrackableZatoshis, 250000);
      expect(balance.totalZatoshis, 350000);
      expect(balance.spendableZatoshis, 0);
    });

    test('stores accumulating different accounts are refused', () {
      final scan = ranged(
        _scan(
          notes: [_note(pool: 'sapling', value: 1, nullifier: 'a1' * 32)],
        ),
      );

      try {
        ZcashAccountBalance.fromStores(
          sapling: SaplingNoteStore()
            ..apply(scan, accountFingerprint: 'account-a'),
          orchard: OrchardNoteStore()
            ..apply(scan, accountFingerprint: 'account-b'),
          ironwood: IronwoodNoteStore()
            ..apply(scan, accountFingerprint: 'account-a'),
        );
        fail('expected the mixed accounts to be refused');
      } on NoteStoreException catch (e) {
        expect(e.refusal, NoteStoreRefusal.foreignAccount);
        expect(e.message, isNot(contains('account-a')));
        expect(e.message, isNot(contains('account-b')));
      }
    });

    test('a store that has never been applied to is not a foreign account', () {
      final scan = ranged(
        _scan(
          notes: [_note(pool: 'sapling', value: 100, nullifier: 'a1' * 32)],
        ),
      );
      final balance = ZcashAccountBalance.fromStores(
        sapling: SaplingNoteStore()
          ..apply(scan, accountFingerprint: 'account-a'),
        orchard: OrchardNoteStore(),
        ironwood: IronwoodNoteStore(),
      );

      expect(balance.totalZatoshis, 100);
    });
  });
}
