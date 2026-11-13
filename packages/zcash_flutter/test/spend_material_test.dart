@TestOn('vm')
library;

import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';
import 'package:zcash_flutter/zcash_flutter.dart';

const _account = 'account-7';
const _tx = '1111111111111111111111111111111111111111111111111111111111111111';
const _nullifier =
    '2222222222222222222222222222222222222222222222222222222222222222';

List<int> _hashBytes(int height) {
  final bytes = List<int>.filled(32, 0);
  bytes[0] = height & 0xff;
  bytes[1] = (height >> 8) & 0xff;
  return bytes;
}

String _hashHex(int height) => [
  for (final byte in _hashBytes(height)) byte.toRadixString(16).padLeft(2, '0'),
].join();

CompactBlock _block(int height) => CompactBlock()
  ..height = Int64(height)
  ..hash = _hashBytes(height)
  ..prevHash = _hashBytes(height - 1)
  ..chainMetadata = (ChainMetadata()
    ..saplingCommitmentTreeSize = 0
    ..orchardCommitmentTreeSize = 0
    ..ironwoodCommitmentTreeSize = 1);

TreeState _treeState(int height, {String ironwood = 'frontier'}) => TreeState(
  height: height,
  hash: reverseTxidByteOrder(_hashHex(height)),
  time: 0,
  sapling: const ShieldedTree(finalState: ''),
  orchard: const ShieldedTree(finalState: ''),
  ironwood: ShieldedTree(finalState: ironwood),
);

ZcashScannedNote _note({int height = 20, int value = 50000, String? witness}) =>
    ZcashScannedNote(
      height: height,
      tx: _tx,
      output: 0,
      value: value,
      pool: 'ironwood',
      nullifier: _nullifier,
      commitmentPosition: 0,
      witness: witness,
      recipient: 'u1test',
      rseed: '3333333333333333333333333333333333333333333333333333333333333333',
      rho: '4444444444444444444444444444444444444444444444444444444444444444',
      noteVersion: 'v3',
    );

ZcashWalletSyncState _restoredWallet() {
  final discovered = ZcashScanResult(
    scannedBlocks: 1,
    discoveredNotes: 1,
    totalValue: 50000,
    notes: [_note(witness: '55' * 40)],
    scannedHeightRange: const CompactBlockScanRange(start: 20, end: 20),
  );
  final sapling = SaplingNoteStore()
    ..apply(discovered, accountFingerprint: _account);
  final orchard = OrchardNoteStore()
    ..apply(discovered, accountFingerprint: _account);
  final ironwood = IronwoodNoteStore()
    ..apply(discovered, accountFingerprint: _account);
  final wallet = ZcashWalletSyncState(
    network: ZcashAddressNetwork.regtest,
    cursor: ZcashLightwalletdSyncCursor.origin(height: 21),
    accountFingerprint: _account,
    sapling: sapling,
    orchard: orchard,
    ironwood: ironwood,
  );
  return ZcashWalletSyncState.fromJson(wallet.toJson());
}

class _FakeSource implements ZcashSpendMaterialSource {
  _FakeSource({
    this.reacquiredValue = 50000,
    this.reorgOnRecheck = false,
    this.treeReorgOnRecheck = false,
    this.boundaryAnchor =
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  });

  final int reacquiredValue;
  final bool reorgOnRecheck;
  final bool treeReorgOnRecheck;
  final String boundaryAnchor;
  final List<(int, int)> ranges = [];
  final List<int> treeStates = [];
  ScanInputEnvelope? envelope;

  @override
  String get network => 'regtest';

  @override
  Future<ZcashLightwalletdScanSource> fetchRange(int start, int end) async {
    ranges.add((start, end));
    if (start == end && reorgOnRecheck) {
      return ZcashLightwalletdScanSource([
        _block(end)..hash = List<int>.filled(32, 0xee),
      ]);
    }
    return ZcashLightwalletdScanSource([
      for (var height = start; height <= end; height++) _block(height),
    ]);
  }

  @override
  Future<TreeState> fetchTreeState(int height) async {
    treeStates.add(height);
    if (height == 25 && treeReorgOnRecheck && treeStates.length == 3) {
      return _treeState(height, ironwood: 'changed-frontier');
    }
    return _treeState(height);
  }

  @override
  Future<ZcashScanResult> scan(ScanInputEnvelope input) async {
    if (input.blocks.isEmpty) {
      return ZcashScanResult(
        scannedBlocks: 0,
        discoveredNotes: 0,
        totalValue: 0,
        notes: const [],
        ironwoodAnchor: boundaryAnchor,
      );
    }
    envelope = input;
    return ZcashScanResult(
      scannedBlocks: input.blocks.length,
      discoveredNotes: 1,
      totalValue: reacquiredValue,
      notes: [_note(value: reacquiredValue, witness: 'aa')],
      scannedHeightRange: input.range,
      ironwoodAnchor:
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    );
  }
}

void main() {
  ZcashSpendMaterialRequest requestFor(ZcashWalletSyncState wallet) =>
      ZcashSpendMaterialRequest.ironwood(
        accountFingerprint: wallet.accountFingerprint,
        notes: wallet.ironwood.notes,
        anchorHeight: 25,
      );

  test(
    'restore then reacquire returns exact ephemeral Ironwood material',
    () async {
      final wallet = _restoredWallet();
      final serializedBefore = wallet.toJson().toString();
      final source = _FakeSource();

      final material = await acquireNativeSpendMaterial(
        wallet: wallet,
        request: requestFor(wallet),
        source: source,
      );

      expect(source.ranges, [(20, 25), (25, 25)]);
      expect(source.treeStates, [19, 25, 25]);
      expect(source.envelope!.includeOrchardWitnesses, isTrue);
      expect(source.envelope!.watchedNullifiers!.ironwood, [_nullifier]);
      expect(material.anchorHeight, 25);
      expect(material.anchorBlockHash, _hashHex(25));
      expect(material.notes.single.witness, 'aa');
      expect(material.notes.single.value, 50000);
      expect(wallet.toJson().toString(), serializedBefore);
      expect(wallet.toJson().toString(), isNot(contains('aa')));
      expect(material.toString(), isNot(contains('aa')));
      expect(material.toString(), isNot(contains(_nullifier)));
    },
  );

  test(
    'rejects a request for another account before reading the chain',
    () async {
      final wallet = _restoredWallet();
      final source = _FakeSource();
      final request = ZcashSpendMaterialRequest.ironwood(
        accountFingerprint: 'another-account',
        notes: wallet.ironwood.notes,
        anchorHeight: 25,
      );

      await expectLater(
        acquireNativeSpendMaterial(
          wallet: wallet,
          request: request,
          source: source,
        ),
        throwsA(isA<ZcashModelException>()),
      );
      expect(source.ranges, isEmpty);
    },
  );

  test('rejects a reacquired note whose durable identity changed', () async {
    final wallet = _restoredWallet();

    await expectLater(
      acquireNativeSpendMaterial(
        wallet: wallet,
        request: requestFor(wallet),
        source: _FakeSource(reacquiredValue: 49999),
      ),
      throwsA(
        isA<ZcashModelException>().having(
          (e) => e.message,
          'message',
          contains('identity'),
        ),
      ),
    );
  });

  test(
    'fails closed when the anchor block changes during acquisition',
    () async {
      final wallet = _restoredWallet();

      await expectLater(
        acquireNativeSpendMaterial(
          wallet: wallet,
          request: requestFor(wallet),
          source: _FakeSource(reorgOnRecheck: true),
        ),
        throwsA(isA<ZcashChainReorgException>()),
      );
    },
  );

  test(
    'fails closed when the anchor tree changes during acquisition',
    () async {
      final wallet = _restoredWallet();

      await expectLater(
        acquireNativeSpendMaterial(
          wallet: wallet,
          request: requestFor(wallet),
          source: _FakeSource(treeReorgOnRecheck: true),
        ),
        throwsA(isA<ZcashChainReorgException>()),
      );
    },
  );

  test('rejects a scan root that is not the exact anchor tree root', () async {
    final wallet = _restoredWallet();

    await expectLater(
      acquireNativeSpendMaterial(
        wallet: wallet,
        request: requestFor(wallet),
        source: _FakeSource(
          boundaryAnchor:
              'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
        ),
      ),
      throwsA(
        isA<ZcashModelException>().having(
          (error) => error.message,
          'message',
          contains('anchor root'),
        ),
      ),
    );
  });
}
