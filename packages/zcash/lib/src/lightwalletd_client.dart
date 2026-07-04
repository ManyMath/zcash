import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:grpc/grpc.dart';

import 'grpc/service.pbgrpc.dart';
import 'grpc/compact_formats.pb.dart';

export 'grpc/compact_formats.pb.dart';
export 'grpc/compact_formats.pbenum.dart';
export 'grpc/service.pb.dart' hide TreeState, Duration;
export 'grpc/service.pbenum.dart';

class LightwalletdClientException implements Exception {
  final String message;
  final String method;
  final String? range;
  final Object? cause;

  const LightwalletdClientException(
    this.message, {
    required this.method,
    this.range,
    this.cause,
  });

  @override
  String toString() {
    final parts = <String>[
      'LightwalletdClientException: $message',
      'method=$method',
    ];
    if (range != null) parts.add('range=$range');
    if (cause != null) parts.add('cause=$cause');
    return parts.join('\n');
  }
}

class LightwalletdClient {
  final ClientChannel? _channel;
  final CompactTxStreamerClient _stub;

  LightwalletdClient._({
    ClientChannel? channel,
    required CompactTxStreamerClient stub,
  }) : _channel = channel,
       _stub = stub;

  factory LightwalletdClient({
    String host = 'localhost',
    int port = 9067,
    bool useTls = true,
    ChannelCredentials? credentials,
  }) {
    final creds =
        credentials ??
        (useTls
            ? const ChannelCredentials.secure()
            : const ChannelCredentials.insecure());
    final channel = ClientChannel(
      host,
      port: port,
      options: ChannelOptions(credentials: creds),
    );
    return LightwalletdClient._(
      channel: channel,
      stub: CompactTxStreamerClient(channel),
    );
  }

  factory LightwalletdClient.fromStub(CompactTxStreamerClient stub) =>
      LightwalletdClient._(stub: stub);

  Future<LightdInfo> getInfo() => _stub.getLightdInfo(Empty());

  Future<BlockID> getLatestBlock() => _stub.getLatestBlock(ChainSpec());

  Future<CompactBlock> getBlock(BlockID id) => _stub.getBlock(id);

  Stream<CompactBlock> getBlockRange(BlockRange range) {
    final rangeLabel = _validateHeightRange(range, method: 'GetBlockRange');
    return _getBlockRange(range, rangeLabel);
  }

  Stream<CompactBlock> _getBlockRange(
    BlockRange range,
    String rangeLabel,
  ) async* {
    try {
      await for (final block in _stub.getBlockRange(range)) {
        yield block;
      }
    } on Object catch (error) {
      throw LightwalletdClientException(
        'gRPC stream failed',
        method: 'GetBlockRange',
        range: rangeLabel,
        cause: error,
      );
    }
  }

  Stream<CompactBlock> getBlockRangeByHeight(int start, int end) =>
      getBlockRange(
        BlockRange()
          ..start = (BlockID()..height = Int64(start))
          ..end = (BlockID()..height = Int64(end)),
      );

  Future<TreeState> getTreeStateAtHeight(int height) =>
      getTreeState(BlockID()..height = Int64(height));

  Future<int> getTipHeight() async => (await getLatestBlock()).height.toInt();

  Future<RawTransaction> getTransaction(TxFilter filter) =>
      _stub.getTransaction(filter);

  Future<SendResponse> sendTransaction(Uint8List txBytes) {
    final raw = RawTransaction()..data = txBytes;
    return _stub.sendTransaction(raw);
  }

  Stream<RawTransaction> getTaddressTxids(
    TransparentAddressBlockFilter filter,
  ) => _stub.getTaddressTransactions(filter);

  Future<Balance> getTaddressBalance(List<String> addresses) {
    final req = AddressList()..addresses.addAll(addresses);
    return _stub.getTaddressBalance(req);
  }

  Stream<GetAddressUtxosReply> getTaddressUtxos(GetAddressUtxosArg arg) =>
      _stub.getAddressUtxosStream(arg);

  Stream<CompactTx> getMempoolTx(GetMempoolTxRequest request) =>
      _stub.getMempoolTx(request);

  Future<TreeState> getTreeState(BlockID id) => _stub.getTreeState(id);

  Future<TreeState> getLatestTreeState() => _stub.getLatestTreeState(Empty());

  Stream<SubtreeRoot> getSubtreeRoots(GetSubtreeRootsArg arg) =>
      _stub.getSubtreeRoots(arg);

  Future<void> close() async => _channel?.shutdown();
}

String _validateHeightRange(BlockRange range, {required String method}) {
  if (!range.hasStart() || !range.hasEnd()) {
    throw LightwalletdClientException(
      'block range must include start and end heights',
      method: method,
      range: _rangeLabel(range),
    );
  }
  if (!range.start.hasHeight() || !range.end.hasHeight()) {
    throw LightwalletdClientException(
      'block range must use heights, not hashes',
      method: method,
      range: _rangeLabel(range),
    );
  }
  final start = range.start.height;
  final end = range.end.height;
  if (end < start) {
    throw LightwalletdClientException(
      'block range end must be greater than or equal to start',
      method: method,
      range: _rangeLabel(range),
    );
  }
  return _rangeLabel(range);
}

String _rangeLabel(BlockRange range) {
  String idLabel(BlockID id, bool hasId) {
    if (!hasId) return 'missing';
    if (id.hasHeight()) return id.height.toString();
    if (id.hasHash()) return 'hash:${id.hash.length}bytes';
    return 'unset';
  }

  return '${idLabel(range.start, range.hasStart())}..'
      '${idLabel(range.end, range.hasEnd())}';
}
