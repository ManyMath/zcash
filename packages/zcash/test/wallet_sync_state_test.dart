import 'dart:convert';

import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

const _fingerprint = 'wallet-sync-state-test';

List<int> _hashBytes(int height) {
  final bytes = List<int>.filled(32, 0);
  bytes[1] = height & 0xff;
  bytes[2] = (height >> 8) & 0xff;
  return bytes;
}

String _hashHex(int height) => [
  for (final b in _hashBytes(height)) b.toRadixString(16).padLeft(2, '0'),
].join();

CompactBlock _block(int height) => CompactBlock()
  ..height = Int64(height)
  ..hash = _hashBytes(height)
  ..prevHash = _hashBytes(height - 1)
  ..vtx.add(
    CompactTx()
      ..ironwoodActions.add(
        CompactOrchardAction()..nullifier = List<int>.filled(32, 7),
      ),
  );

class _Source {
  _Source({required this.tip});

  final int tip;
  final List<CompactBlockScanRange> fetched = [];

  Future<int> chainTip() async => tip;

  Future<ZcashLightwalletdScanSource> fetchRange(int start, int end) async {
    fetched.add(CompactBlockScanRange(start: start, end: end));
    return ZcashLightwalletdScanSource([
      for (var height = start; height <= end; height++) _block(height),
    ]);
  }

  Future<TreeState> fetchTreeState(int height) async => TreeState(
    hash: reverseTxidByteOrder(_hashHex(height)),
    height: height,
    time: 0,
    ironwood: ShieldedTree(finalState: 'tree-$height'),
  );

  Future<String?> servedBlockHashAt(int height) async =>
      height > tip ? null : _hashHex(height);

  Future<ZcashScanResult> scan(ScanInputEnvelope envelope) async {
    final range = envelope.range!;
    return ZcashScanResult(
      scannedBlocks: range.end - range.start + 1,
      discoveredNotes: 1,
      totalValue: 1000,
      scannedHeightRange: range,
      notes: [
        ZcashScannedNote(
          height: range.start,
          tx: 'ab' * 32,
          output: range.start,
          value: 1000,
          pool: 'ironwood',
          nullifier: range.start.toRadixString(16).padLeft(2, '0') * 32,
        ),
      ],
    );
  }
}

ZcashScanResult _coverage(int start, int end) => ZcashScanResult(
  scannedBlocks: end - start + 1,
  discoveredNotes: 0,
  totalValue: 0,
  scannedHeightRange: CompactBlockScanRange(start: start, end: end),
  notes: const [],
);

SaplingNoteStore _saplingCovering(int start, int end) =>
    SaplingNoteStore()
      ..apply(_coverage(start, end), accountFingerprint: _fingerprint);

OrchardNoteStore _orchardCovering(int start, int end) =>
    OrchardNoteStore()
      ..apply(_coverage(start, end), accountFingerprint: _fingerprint);

IronwoodNoteStore _ironwoodCovering(int start, int end) =>
    IronwoodNoteStore()
      ..apply(_coverage(start, end), accountFingerprint: _fingerprint);

ZcashWalletSyncState _walletCovering(int start, int end) =>
    ZcashWalletSyncState(
      cursor: ZcashLightwalletdSyncCursor(
        nextHeight: end + 1,
        priorIronwoodFrontier: 'tree-$end',
        priorBlockHash: _hashHex(end),
        trail: ZcashChainTrail(
          checkpoints: [
            ZcashChainCheckpoint(height: end, blockHash: _hashHex(end)),
          ],
        ),
      ),
      accountFingerprint: _fingerprint,
      sapling: _saplingCovering(start, end),
      orchard: _orchardCovering(start, end),
      ironwood: _ironwoodCovering(start, end),
    );

void main() {
  group('ZcashWalletSyncState', () {
    test('a wallet at its birthday holds three empty stores', () {
      final wallet = ZcashWalletSyncState.atBirthday(
        cursor: ZcashLightwalletdSyncCursor.origin(height: 11),
        accountFingerprint: _fingerprint,
      );

      expect(wallet.cursor.nextHeight, 11);
      expect(wallet.balance().totalZatoshis, 0);
      expect(wallet.sapling.coveredThrough, isNull);
      expect(wallet.orchard.coveredThrough, isNull);
      expect(wallet.ironwood.coveredThrough, isNull);
    });

    test('a synced wallet writes down the position it reached', () async {
      final source = _Source(tip: 40);
      final wallet = ZcashWalletSyncState.atBirthday(
        cursor: ZcashLightwalletdSyncCursor.origin(height: 11),
        accountFingerprint: _fingerprint,
      );
      final sync = wallet.syncThrough(
        chainTip: source.chainTip,
        fetchRange: source.fetchRange,
        fetchTreeState: source.fetchTreeState,
        scan: source.scan,
        servedBlockHashAt: source.servedBlockHashAt,
        rangeSize: 10,
      );

      expect(await sync.syncToTip(), isA<ZcashSyncCaughtUp>());

      expect(wallet.cursor.nextHeight, 41);
      expect(wallet.ironwood.coveredThrough, 40);
      expect(wallet.sapling.coveredThrough, 40);
      expect(wallet.orchard.coveredThrough, 40);
      expect(wallet.balance().totalZatoshis, 3000);
      expect(wallet.balance().spendableZatoshis, 0);

      final restored = ZcashWalletSyncState.fromJson(
        (jsonDecode(jsonEncode(wallet.toJson())) as Map)
            .cast<String, Object?>(),
      );
      expect(restored.cursor.nextHeight, 41);
      expect(restored.cursor.priorIronwoodFrontier, 'tree-40');
      expect(restored.balance().totalZatoshis, 3000);
      expect(restored.accountFingerprint, _fingerprint);
    });

    test('a restored wallet continues from where it stopped', () async {
      final source = _Source(tip: 40);
      final wallet = ZcashWalletSyncState.atBirthday(
        cursor: ZcashLightwalletdSyncCursor.origin(height: 11),
        accountFingerprint: _fingerprint,
      );
      await wallet
          .syncThrough(
            chainTip: () async => 20,
            fetchRange: source.fetchRange,
            fetchTreeState: source.fetchTreeState,
            scan: source.scan,
            servedBlockHashAt: source.servedBlockHashAt,
            rangeSize: 10,
          )
          .syncToTip();

      final reopened = ZcashWalletSyncState.fromJson(wallet.toJson());
      final second = _Source(tip: 30);
      await reopened
          .syncThrough(
            chainTip: second.chainTip,
            fetchRange: second.fetchRange,
            fetchTreeState: second.fetchTreeState,
            scan: second.scan,
            servedBlockHashAt: second.servedBlockHashAt,
            rangeSize: 10,
          )
          .syncToTip();

      expect(second.fetched.first.start, 21);
      expect(reopened.ironwood.coveredThrough, 30);
    });
  });

  group('a wallet whose four documents were written at different moments', () {
    test('refuses stores behind the cursor, naming the wedge', () {
      expect(
        () => ZcashWalletSyncState(
          cursor: ZcashLightwalletdSyncCursor.origin(height: 201),
          accountFingerprint: _fingerprint,
          sapling: _saplingCovering(11, 150),
          orchard: _orchardCovering(11, 150),
          ironwood: _ironwoodCovering(11, 150),
        ),
        throwsA(
          isA<ZcashModelException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('behind the cursor'),
              contains('151-200'),
              contains('a cursor does not go backwards'),
            ),
          ),
        ),
      );
    });

    test('refuses stores ahead of the cursor, which nothing else catches', () {
      expect(
        () => ZcashWalletSyncState(
          cursor: ZcashLightwalletdSyncCursor.origin(height: 151),
          accountFingerprint: _fingerprint,
          sapling: _saplingCovering(11, 200),
          orchard: _orchardCovering(11, 200),
          ironwood: _ironwoodCovering(11, 200),
        ),
        throwsA(
          isA<ZcashModelException>().having(
            (e) => e.message,
            'message',
            contains('ahead of the cursor'),
          ),
        ),
      );
    });

    test('refuses three stores at three positions', () {
      expect(
        () => ZcashWalletSyncState(
          cursor: ZcashLightwalletdSyncCursor.origin(height: 201),
          accountFingerprint: _fingerprint,
          sapling: _saplingCovering(11, 200),
          orchard: _orchardCovering(11, 200),
          ironwood: _ironwoodCovering(11, 150),
        ),
        throwsA(
          isA<ZcashModelException>().having(
            (e) => e.message,
            'message',
            allOf(contains('different heights'), contains('Ironwood 150')),
          ),
        ),
      );
    });

    test('refuses an empty store beside covered ones', () {
      expect(
        () => ZcashWalletSyncState(
          cursor: ZcashLightwalletdSyncCursor.origin(height: 201),
          accountFingerprint: _fingerprint,
          sapling: SaplingNoteStore(),
          orchard: OrchardNoteStore(),
          ironwood: _ironwoodCovering(11, 200),
        ),
        throwsA(
          isA<ZcashModelException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('different heights'),
              contains('never been read at all'),
            ),
          ),
        ),
      );
    });

    test('refuses stores that end together and begin apart', () {
      expect(
        () => ZcashWalletSyncState(
          cursor: ZcashLightwalletdSyncCursor.origin(height: 201),
          accountFingerprint: _fingerprint,
          sapling: _saplingCovering(11, 200),
          orchard: _orchardCovering(11, 200),
          ironwood: _ironwoodCovering(130, 200),
        ),
        throwsA(
          isA<ZcashModelException>().having(
            (e) => e.message,
            'message',
            contains('begin at different heights'),
          ),
        ),
      );
    });

    test('refuses a store accumulating another account', () {
      expect(
        () => ZcashWalletSyncState(
          cursor: ZcashLightwalletdSyncCursor.origin(height: 201),
          accountFingerprint: _fingerprint,
          sapling: _saplingCovering(11, 200),
          orchard: _orchardCovering(11, 200),
          ironwood: IronwoodNoteStore()
            ..apply(_coverage(11, 200), accountFingerprint: 'another-wallet'),
        ),
        throwsA(
          isA<ZcashModelException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('different account'),
              isNot(contains('another-wallet')),
            ),
          ),
        ),
      );
    });
  });

  group('the document', () {
    test('refuses an absent or unknown version', () {
      final document = _walletCovering(11, 200).toJson();

      expect(
        () => ZcashWalletSyncState.fromJson(
          {...document}..remove('wallet_sync_version'),
        ),
        throwsA(isA<ZcashModelException>()),
      );
      expect(
        () => ZcashWalletSyncState.fromJson({
          ...document,
          'wallet_sync_version': 2,
        }),
        throwsA(
          isA<ZcashModelException>().having(
            (e) => e.message,
            'message',
            contains('half understands'),
          ),
        ),
      );
    });

    test('refuses one that names no account', () {
      final document = _walletCovering(11, 200).toJson()
        ..remove('account_fingerprint');

      expect(
        () => ZcashWalletSyncState.fromJson(document),
        throwsA(
          isA<ZcashModelException>().having(
            (e) => e.message,
            'message',
            contains('names the account it belongs to'),
          ),
        ),
      );
    });

    test('refuses a store document filed under the wrong pool', () {
      final document = _walletCovering(11, 200).toJson();

      expect(
        () => ZcashWalletSyncState.fromJson({
          ...document,
          'sapling': document['orchard'],
        }),
        throwsA(
          isA<NoteStoreException>().having(
            (e) => e.refusal,
            'refusal',
            NoteStoreRefusal.wrongPool,
          ),
        ),
      );
    });

    test('the cursor refusals still run on the way in', () {
      final document = _walletCovering(11, 200).toJson();
      final cursor = (document['cursor']! as Map<String, Object?>);

      expect(
        () => ZcashWalletSyncState.fromJson({
          ...document,
          'cursor': {...cursor, 'frontier_height': 150},
        }),
        throwsA(isA<ZcashModelException>()),
      );
    });

    test('refuses to write a set it would refuse to read', () {
      final wallet = _walletCovering(11, 200);
      wallet.ironwood.apply(
        _coverage(201, 210),
        accountFingerprint: _fingerprint,
      );

      expect(() => wallet.toJson(), throwsA(isA<ZcashModelException>()));
    });
  });

  group('one sync at a time', () {
    test('refuses a second sync over the same stores', () {
      final source = _Source(tip: 40);
      final wallet = ZcashWalletSyncState.atBirthday(
        cursor: ZcashLightwalletdSyncCursor.origin(height: 11),
        accountFingerprint: _fingerprint,
      );
      ZcashChainSync make() => wallet.syncThrough(
        chainTip: source.chainTip,
        fetchRange: source.fetchRange,
        fetchTreeState: source.fetchTreeState,
        scan: source.scan,
        servedBlockHashAt: source.servedBlockHashAt,
      );

      expect(make(), isA<ZcashChainSync>());
      expect(
        make,
        throwsA(
          isA<ZcashModelException>().having(
            (e) => e.message,
            'message',
            contains('already has a sync'),
          ),
        ),
      );
    });
  });
}
