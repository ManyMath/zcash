@TestOn('vm')
library;

import 'dart:io';

import 'package:fixnum/fixnum.dart';
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';
import 'package:zcash_flutter/zcash_flutter.dart' hide TreeState;
import 'package:zcash/lightwalletd_protos.dart' as lwd show TreeState, Duration;
import 'package:zcash/lightwalletd_protos.dart'
    show
        Address,
        AddressList,
        Balance,
        BlockID,
        BlockRange,
        ChainSpec,
        CompactTxStreamerServiceBase,
        Empty,
        GetAddressUtxosArg,
        GetAddressUtxosReply,
        GetAddressUtxosReplyList,
        GetMempoolTxRequest,
        GetSubtreeRootsArg,
        LightdInfo,
        PingResponse,
        RawTransaction,
        SendResponse,
        SubtreeRoot,
        TransparentAddressBlockFilter,
        TxFilter;

const _fingerprint = 'lightwalletd-sync-unit';

const _seedHex =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'
    '202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f';

bool get _libAvailable =>
    (Platform.environment['ZCASH_FFI_LIB'] ?? '').isNotEmpty;

List<int> _hashBytes(int height) {
  final bytes = List<int>.filled(32, 0);
  bytes[1] = height & 0xff;
  bytes[2] = (height >> 8) & 0xff;
  return bytes;
}

String _hashHex(int height) => [
  for (final b in _hashBytes(height)) b.toRadixString(16).padLeft(2, '0'),
].join();

CompactBlock _emptyBlock(int height) => CompactBlock()
  ..height = Int64(height)
  ..hash = _hashBytes(height)
  ..prevHash = _hashBytes(height - 1)
  ..chainMetadata = (ChainMetadata()
    ..saplingCommitmentTreeSize = 0
    ..orchardCommitmentTreeSize = 0
    ..ironwoodCommitmentTreeSize = 0);

CompactBlock _preNu63Block(int height) => _emptyBlock(height);

class _FakeServer extends CompactTxStreamerServiceBase {
  _FakeServer({required this.tip, this.blocks = const []});

  int tip;
  List<CompactBlock> blocks;

  final List<(int, int)> requested = [];

  @override
  Future<BlockID> getLatestBlock(ServiceCall call, ChainSpec request) async =>
      BlockID()..height = Int64(tip);

  @override
  Stream<CompactBlock> getBlockRange(ServiceCall call, BlockRange request) {
    final start = request.start.height.toInt();
    final end = request.end.height.toInt();
    requested.add((start, end));
    return Stream.fromIterable([
      for (final block in blocks)
        if (block.height.toInt() >= start && block.height.toInt() <= end) block,
    ]);
  }

  @override
  Future<lwd.TreeState> getTreeState(ServiceCall call, BlockID request) async {
    final height = request.height.toInt();
    return lwd.TreeState()
      ..height = Int64(height)
      // TreeState hash is displayed (reversed) order; a compact block's is not.
      ..hash = reverseTxidByteOrder(_hashHex(height))
      ..saplingTree = ''
      ..orchardTree = ''
      ..ironwoodTree = '';
  }

  @override
  Future<LightdInfo> getLightdInfo(ServiceCall call, Empty request) async =>
      LightdInfo();

  @override
  Future<CompactBlock> getBlock(ServiceCall call, BlockID request) async =>
      CompactBlock();

  @override
  Future<CompactBlock> getBlockNullifiers(
    ServiceCall call,
    BlockID request,
  ) async => CompactBlock();

  @override
  Stream<CompactBlock> getBlockRangeNullifiers(
    ServiceCall call,
    BlockRange request,
  ) => const Stream.empty();

  @override
  Future<RawTransaction> getTransaction(
    ServiceCall call,
    TxFilter request,
  ) async => RawTransaction();

  @override
  Future<SendResponse> sendTransaction(
    ServiceCall call,
    RawTransaction request,
  ) async => SendResponse();

  @override
  Stream<RawTransaction> getTaddressTxids(
    ServiceCall call,
    TransparentAddressBlockFilter request,
  ) => const Stream.empty();

  @override
  Stream<RawTransaction> getTaddressTransactions(
    ServiceCall call,
    TransparentAddressBlockFilter request,
  ) => const Stream.empty();

  @override
  Future<Balance> getTaddressBalance(
    ServiceCall call,
    AddressList request,
  ) async => Balance();

  @override
  Future<Balance> getTaddressBalanceStream(
    ServiceCall call,
    Stream<Address> request,
  ) async => Balance();

  @override
  Stream<CompactTx> getMempoolTx(
    ServiceCall call,
    GetMempoolTxRequest request,
  ) => const Stream.empty();

  @override
  Stream<RawTransaction> getMempoolStream(ServiceCall call, Empty request) =>
      const Stream.empty();

  @override
  Future<lwd.TreeState> getLatestTreeState(
    ServiceCall call,
    Empty request,
  ) async => lwd.TreeState();

  @override
  Stream<SubtreeRoot> getSubtreeRoots(
    ServiceCall call,
    GetSubtreeRootsArg request,
  ) => const Stream.empty();

  @override
  Future<GetAddressUtxosReplyList> getAddressUtxos(
    ServiceCall call,
    GetAddressUtxosArg request,
  ) async => GetAddressUtxosReplyList();

  @override
  Stream<GetAddressUtxosReply> getAddressUtxosStream(
    ServiceCall call,
    GetAddressUtxosArg request,
  ) => const Stream.empty();

  @override
  Future<PingResponse> ping(ServiceCall call, lwd.Duration request) async =>
      PingResponse();
}

class _OnceStaleServer extends _FakeServer {
  _OnceStaleServer({
    required super.tip,
    required super.blocks,
    required this.staleRange,
  });

  final (int, int) staleRange;
  var _servedStale = false;

  @override
  Stream<CompactBlock> getBlockRange(ServiceCall call, BlockRange request) {
    final range = (request.start.height.toInt(), request.end.height.toInt());
    if (range == staleRange && !_servedStale) {
      _servedStale = true;
      requested.add(range);
      return Stream.fromIterable([
        for (var h = range.$1; h <= range.$2; h++)
          _emptyBlock(h)..prevHash = List<int>.filled(32, 0xee),
      ]);
    }
    return super.getBlockRange(call, request);
  }
}

void main() {
  Server? server;
  LightwalletdClient? client;
  late _FakeServer fake;

  Future<void> start(_FakeServer streamer) async {
    fake = streamer;
    server = Server.create(services: [streamer]);
    await server!.serve(address: InternetAddress.loopbackIPv4, port: 0);
    client = LightwalletdClient(
      host: 'localhost',
      port: server!.port!,
      useTls: false,
    );
  }

  tearDown(() async {
    await client?.close();
    await server?.shutdown();
    client = null;
    server = null;
  });

  ZcashWalletSyncState walletAt(int height) => ZcashWalletSyncState.atBirthday(
    cursor: ZcashLightwalletdSyncCursor.origin(height: height),
    accountFingerprint: _fingerprint,
  );

  group('openNativeLightwalletdSync', () {
    test('a sync above the server is caught up, and scans nothing', () async {
      await start(_FakeServer(tip: 40));
      final wallet = walletAt(41);

      final outcome = await openNativeLightwalletdSync(
        client: client!,
        wallet: wallet,
        ufvk: 'unused-by-a-caught-up-sync',
        network: ZcashNetwork.regtest,
      ).step();

      expect(outcome, isA<ZcashSyncCaughtUp>());
      expect((outcome as ZcashSyncCaughtUp).chainHeight, 40);
      expect(fake.requested, isEmpty);
    });

    test('the second opinion refuses a blind server before the scan', () async {
      await start(
        _FakeServer(tip: 12, blocks: [_preNu63Block(11), _preNu63Block(12)]),
      );
      final wallet = walletAt(11);

      final sync = openNativeLightwalletdSync(
        client: client!,
        wallet: wallet,
        ufvk: 'never-reached',
        network: ZcashNetwork.regtest,
        nodeCommitmentTreeSizes: (height) async =>
            const ZcashCommitmentTreeSizes(ironwood: 6),
      );

      await expectLater(
        sync.step(),
        throwsA(
          isA<ZcashModelException>().having(
            (e) => e.message,
            'message',
            contains('no Ironwood notes and no error'),
          ),
        ),
      );
      expect(fake.requested, [(11, 12)]);
      expect(wallet.cursor.nextHeight, 11);
      expect(wallet.ironwood.coveredThrough, isNull);
    });

    test('the same server with no second opinion is not refused', () async {
      await start(
        _FakeServer(tip: 12, blocks: [_preNu63Block(11), _preNu63Block(12)]),
      );
      final wallet = walletAt(11);

      final sync = openNativeLightwalletdSync(
        client: client!,
        wallet: wallet,
        ufvk: 'reached-and-then-fails-without-a-library',
        network: ZcashNetwork.regtest,
      );

      await expectLater(
        sync.step(),
        throwsA(
          isA<Object>().having(
            (e) => e.toString(),
            'toString',
            isNot(contains('no Ironwood notes and no error')),
          ),
        ),
      );
      expect(fake.requested, [(11, 12)]);
    });
  });

  group('openNativeLightwalletdSync, end to end against a real scanner', () {
    test('syncs a range from a server and writes the wallet down', () async {
      await start(
        _FakeServer(
          tip: 14,
          blocks: [for (var h = 11; h <= 14; h++) _emptyBlock(h)],
        ),
      );
      final wallet = walletAt(11);
      final ufvk = deriveNativeAccountMetadata(
        seedHex: _seedHex,
        network: ZcashNetwork.regtest,
        bindings: ZcashFfiBindings.open(Platform.environment['ZCASH_FFI_LIB']!),
      ).ufvk;

      final sync = openNativeLightwalletdSync(
        client: client!,
        wallet: wallet,
        ufvk: ufvk,
        network: ZcashNetwork.regtest,
        rangeSize: 2,
        bindings: ZcashFfiBindings.open(Platform.environment['ZCASH_FFI_LIB']!),
      );

      expect(await sync.syncToTip(), isA<ZcashSyncCaughtUp>());

      expect(fake.requested, [(11, 12), (13, 14)]);
      expect(wallet.cursor.nextHeight, 15);
      expect(wallet.sapling.coveredThrough, 14);
      expect(wallet.orchard.coveredThrough, 14);
      expect(wallet.ironwood.coveredThrough, 14);
      expect(wallet.balance().totalZatoshis, 0);

      final reopened = ZcashWalletSyncState.fromJson(wallet.toJson());
      expect(reopened.cursor.nextHeight, 15);
      expect(reopened.cursor.priorBlockHash, _hashHex(14));
    });

    test(
      'a lookahead from a chain that moved is fetched again, not a reorg',
      () async {
        await start(
          _OnceStaleServer(
            tip: 14,
            blocks: [for (var h = 11; h <= 14; h++) _emptyBlock(h)],
            staleRange: (13, 14),
          ),
        );
        final bindings = ZcashFfiBindings.open(
          Platform.environment['ZCASH_FFI_LIB']!,
        );
        final wallet = walletAt(11);
        final sync = openNativeLightwalletdSync(
          client: client!,
          wallet: wallet,
          ufvk: deriveNativeAccountMetadata(
            seedHex: _seedHex,
            network: ZcashNetwork.regtest,
            bindings: bindings,
          ).ufvk,
          network: ZcashNetwork.regtest,
          rangeSize: 2,
          bindings: bindings,
        );

        expect(await sync.syncToTip(), isA<ZcashSyncCaughtUp>());
        expect(fake.requested, [(11, 12), (13, 14), (13, 14)]);
        expect(wallet.cursor.nextHeight, 15);
        expect(wallet.cursor.priorBlockHash, _hashHex(14));
      },
    );
  }, skip: _libAvailable ? false : 'ZCASH_FFI_LIB not set');
}
