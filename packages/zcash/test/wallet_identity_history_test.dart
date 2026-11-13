import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

void main() {
  test('account fingerprint is deterministic and network/account bound', () {
    final main = zcashAccountFingerprint(
      network: ZcashAddressNetwork.mainnet,
      accountIndex: 0,
      ufvk: 'uview-fixture',
    );

    expect(main, hasLength(64));
    expect(main, matches(RegExp(r'^[0-9a-f]+$')));
    expect(
      zcashAccountFingerprint(
        network: ZcashAddressNetwork.mainnet,
        accountIndex: 0,
        ufvk: 'uview-fixture',
      ),
      main,
    );
    expect(
      zcashAccountFingerprint(
        network: ZcashAddressNetwork.testnet,
        accountIndex: 0,
        ufvk: 'uview-fixture',
      ),
      isNot(main),
    );
    expect(
      zcashAccountFingerprint(
        network: ZcashAddressNetwork.mainnet,
        accountIndex: 1,
        ufvk: 'uview-fixture',
      ),
      isNot(main),
    );
    expect(main, isNot(contains('uview-fixture')));
  });

  test('wallet document persists network and canonical history block hash', () {
    const blockHash =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final fingerprint = zcashAccountFingerprint(
      network: ZcashAddressNetwork.regtest,
      accountIndex: 0,
      ufvk: 'uview-regtest-fixture',
    );
    final ironwood = IronwoodNoteStore()
      ..apply(
        ZcashScanResult(
          scannedBlocks: 1,
          discoveredNotes: 1,
          totalValue: 50000,
          scannedHeightRange: const CompactBlockScanRange(start: 200, end: 200),
          notes: const [
            ZcashScannedNote(
              height: 200,
              tx: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
              output: 0,
              value: 50000,
              pool: 'ironwood',
              blockHash: blockHash,
            ),
          ],
        ),
        accountFingerprint: fingerprint,
      );
    final wallet = ZcashWalletSyncState(
      network: ZcashAddressNetwork.regtest,
      cursor: const ZcashLightwalletdSyncCursor(nextHeight: 201),
      accountFingerprint: fingerprint,
      sapling: SaplingNoteStore()
        ..apply(
          const ZcashScanResult(
            scannedBlocks: 1,
            discoveredNotes: 0,
            totalValue: 0,
            scannedHeightRange: CompactBlockScanRange(start: 200, end: 200),
            notes: [],
          ),
          accountFingerprint: fingerprint,
        ),
      orchard: OrchardNoteStore()
        ..apply(
          const ZcashScanResult(
            scannedBlocks: 1,
            discoveredNotes: 0,
            totalValue: 0,
            scannedHeightRange: CompactBlockScanRange(start: 200, end: 200),
            notes: [],
          ),
          accountFingerprint: fingerprint,
        ),
      ironwood: ironwood,
    );

    final document = wallet.toJson();
    final restored = ZcashWalletSyncState.fromJson(document);

    expect(document['network'], 'regtest');
    expect(restored.network, ZcashAddressNetwork.regtest);
    expect(restored.accountFingerprint, fingerprint);
    expect(restored.history().entries.single.blockHash, blockHash);
  });

  test(
    'note store refuses a canonical block identity change without rollback',
    () {
      const firstHash =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      const secondHash =
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      const tx =
          'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
      final store = IronwoodNoteStore();

      ZcashScanResult scan(String blockHash) => ZcashScanResult(
        scannedBlocks: 1,
        discoveredNotes: 1,
        totalValue: 50000,
        scannedHeightRange: const CompactBlockScanRange(start: 200, end: 200),
        notes: [
          ZcashScannedNote(
            height: 200,
            tx: tx,
            output: 0,
            value: 50000,
            pool: 'ironwood',
            blockHash: blockHash,
          ),
        ],
      );

      store.apply(scan(firstHash), accountFingerprint: 'account');

      expect(
        () => store.apply(scan(secondHash), accountFingerprint: 'account'),
        throwsA(
          isA<NoteStoreException>().having(
            (error) => error.refusal,
            'refusal',
            NoteStoreRefusal.malformed,
          ),
        ),
      );
    },
  );

  test('note store refuses malformed persisted block identity', () {
    final store = IronwoodNoteStore()
      ..apply(
        const ZcashScanResult(
          scannedBlocks: 1,
          discoveredNotes: 1,
          totalValue: 50000,
          scannedHeightRange: CompactBlockScanRange(start: 200, end: 200),
          notes: [
            ZcashScannedNote(
              height: 200,
              tx: 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
              output: 0,
              value: 50000,
              pool: 'ironwood',
              blockHash:
                  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            ),
          ],
        ),
        accountFingerprint: 'account',
      );
    final document = store.toJson();
    final notes = document['notes']! as List<Object?>;
    (notes.single as Map<String, Object?>)['block_hash'] = 'not-a-hash';

    expect(
      () => IronwoodNoteStore.fromJson(document),
      throwsA(
        isA<NoteStoreException>().having(
          (error) => error.refusal,
          'refusal',
          NoteStoreRefusal.malformed,
        ),
      ),
    );
  });

  test('note store refuses malformed scanned block identity', () {
    final store = IronwoodNoteStore();
    expect(
      () => store.apply(
        const ZcashScanResult(
          scannedBlocks: 1,
          discoveredNotes: 1,
          totalValue: 50000,
          scannedHeightRange: CompactBlockScanRange(start: 200, end: 200),
          notes: [
            ZcashScannedNote(
              height: 200,
              tx: 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
              output: 0,
              value: 50000,
              pool: 'ironwood',
              blockHash: 'not-a-hash',
            ),
          ],
        ),
        accountFingerprint: 'account',
      ),
      throwsA(
        isA<NoteStoreException>().having(
          (error) => error.refusal,
          'refusal',
          NoteStoreRefusal.malformed,
        ),
      ),
    );
    expect(store.accountFingerprint, isNull);
    expect(store.notes, isEmpty);
    expect(store.coveredThrough, isNull);
  });
}
