import 'dart:io';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';
import 'package:zcash/zcash.dart' hide TreeState;
import 'package:zcash/src/grpc/service.pb.dart' as lwd
    show TreeState, Duration;
import 'package:zcash/src/grpc/service.pbgrpc.dart' show
    CompactTxStreamerServiceBase, LightdInfo, BlockID, ChainSpec,
    BlockRange, RawTransaction, TxFilter, SendResponse,
    TransparentAddressBlockFilter, Balance, AddressList, Address,
    GetMempoolTxRequest, Empty, SubtreeRoot, GetSubtreeRootsArg,
    GetAddressUtxosReplyList, GetAddressUtxosArg, GetAddressUtxosReply,
    PingResponse;

Server? _server;
LightwalletdClient? _client;

Future<void> _startServer(_FakeStreamer fake) async {
  _server = Server.create(services: [fake]);
  await _server!.serve(address: InternetAddress.loopbackIPv4, port: 0);
  _client = LightwalletdClient(
    host: 'localhost',
    port: _server!.port!,
    useTls: false,
  );
}

Future<void> _stopServer() async {
  await _client?.close();
  await _server?.shutdown();
}

void main() {
  group('LightwalletdClient.getInfo', () {
    setUp(() => _startServer(_FakeStreamer(
          lightdInfo: LightdInfo()
            ..version = '0.4.1'
            ..vendor = 'ECC LightWalletD'
            ..chainName = 'main'
            ..blockHeight = Int64(2500000)
            ..saplingActivationHeight = Int64(419200),
        )));

    tearDown(_stopServer);

    test('deserialises LightdInfo fields', () async {
      final info = await _client!.getInfo();
      expect(info.version, '0.4.1');
      expect(info.vendor, 'ECC LightWalletD');
      expect(info.chainName, 'main');
      expect(info.blockHeight, Int64(2500000));
      expect(info.saplingActivationHeight, Int64(419200));
    });
  });

  group('LightwalletdClient.getBlockRange', () {
    setUp(() {
      final blocks = List.generate(
        5,
        (i) => CompactBlock()
          ..height = Int64(100 + i)
          ..protoVersion = 1,
      );
      return _startServer(_FakeStreamer(blocks: blocks));
    });

    tearDown(_stopServer);

    test('emits the expected number of CompactBlocks', () async {
      final range = BlockRange()
        ..start = (BlockID()..height = Int64(100))
        ..end = (BlockID()..height = Int64(104));
      final blocks = await _client!.getBlockRange(range).toList();
      expect(blocks, hasLength(5));
      expect(blocks.first.height, Int64(100));
      expect(blocks.last.height, Int64(104));
    });
  });

  group('LightwalletdClient.sendTransaction', () {
    setUp(() => _startServer(_FakeStreamer(
          sendResponse: SendResponse()
            ..errorCode = 0
            ..errorMessage = '',
        )));

    tearDown(_stopServer);

    test('returns SendResponse with error code 0 on success', () async {
      final txBytes = Uint8List.fromList([0xde, 0xad, 0xbe, 0xef]);
      final resp = await _client!.sendTransaction(txBytes);
      expect(resp.errorCode, 0);
      expect(resp.errorMessage, isEmpty);
    });

    test('returns non-zero error code on rejection', () async {
      await _stopServer();
      await _startServer(_FakeStreamer(
        sendResponse: SendResponse()
          ..errorCode = -1
          ..errorMessage = 'invalid transaction',
      ));
      final resp = await _client!.sendTransaction(Uint8List(0));
      expect(resp.errorCode, -1);
      expect(resp.errorMessage, 'invalid transaction');
    });
  });
}

class _FakeStreamer extends CompactTxStreamerServiceBase {
  final LightdInfo? lightdInfo;
  final List<CompactBlock>? blocks;
  final SendResponse? sendResponse;

  _FakeStreamer({this.lightdInfo, this.blocks, this.sendResponse});

  @override
  Future<LightdInfo> getLightdInfo(ServiceCall call, Empty request) async =>
      lightdInfo ?? LightdInfo();

  @override
  Future<BlockID> getLatestBlock(ServiceCall call, ChainSpec request) async =>
      BlockID()..height = Int64(0);

  @override
  Future<CompactBlock> getBlock(ServiceCall call, BlockID request) async =>
      CompactBlock();

  @override
  Future<CompactBlock> getBlockNullifiers(
          ServiceCall call, BlockID request) async =>
      CompactBlock();

  @override
  Stream<CompactBlock> getBlockRange(ServiceCall call, BlockRange request) =>
      Stream.fromIterable(blocks ?? []);

  @override
  Stream<CompactBlock> getBlockRangeNullifiers(
          ServiceCall call, BlockRange request) =>
      const Stream.empty();

  @override
  Future<RawTransaction> getTransaction(
          ServiceCall call, TxFilter request) async =>
      RawTransaction();

  @override
  Future<SendResponse> sendTransaction(
          ServiceCall call, RawTransaction request) async =>
      sendResponse ?? SendResponse();

  @override
  Stream<RawTransaction> getTaddressTxids(
          ServiceCall call, TransparentAddressBlockFilter request) =>
      const Stream.empty();

  @override
  Stream<RawTransaction> getTaddressTransactions(
          ServiceCall call, TransparentAddressBlockFilter request) =>
      const Stream.empty();

  @override
  Future<Balance> getTaddressBalance(
          ServiceCall call, AddressList request) async =>
      Balance();

  @override
  Future<Balance> getTaddressBalanceStream(
          ServiceCall call, Stream<Address> request) async =>
      Balance();

  @override
  Stream<CompactTx> getMempoolTx(
          ServiceCall call, GetMempoolTxRequest request) =>
      const Stream.empty();

  @override
  Stream<RawTransaction> getMempoolStream(ServiceCall call, Empty request) =>
      const Stream.empty();

  @override
  Future<lwd.TreeState> getTreeState(ServiceCall call, BlockID request) async =>
      lwd.TreeState();

  @override
  Future<lwd.TreeState> getLatestTreeState(
          ServiceCall call, Empty request) async =>
      lwd.TreeState();

  @override
  Stream<SubtreeRoot> getSubtreeRoots(
          ServiceCall call, GetSubtreeRootsArg request) =>
      const Stream.empty();

  @override
  Future<GetAddressUtxosReplyList> getAddressUtxos(
          ServiceCall call, GetAddressUtxosArg request) async =>
      GetAddressUtxosReplyList();

  @override
  Stream<GetAddressUtxosReply> getAddressUtxosStream(
          ServiceCall call, GetAddressUtxosArg request) =>
      const Stream.empty();

  @override
  Future<PingResponse> ping(ServiceCall call, lwd.Duration request) async =>
      PingResponse();
}
