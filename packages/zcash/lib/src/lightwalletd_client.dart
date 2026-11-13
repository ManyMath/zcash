import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:grpc/grpc.dart';

import 'grpc/service.pbgrpc.dart' hide Duration;
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
  final Duration rpcTimeout;

  LightwalletdClient._({
    ClientChannel? channel,
    required CompactTxStreamerClient stub,
    required this.rpcTimeout,
  }) : _channel = channel,
       _stub = stub;

  factory LightwalletdClient({
    String host = 'localhost',
    int port = 9067,
    bool useTls = true,
    ChannelCredentials? credentials,
    Duration rpcTimeout = const Duration(seconds: 30),
  }) {
    if (rpcTimeout <= Duration.zero) {
      throw ArgumentError.value(rpcTimeout, 'rpcTimeout', 'must be positive');
    }
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
      rpcTimeout: rpcTimeout,
    );
  }

  factory LightwalletdClient.fromStub(
    CompactTxStreamerClient stub, {
    Duration rpcTimeout = const Duration(seconds: 30),
  }) {
    if (rpcTimeout <= Duration.zero) {
      throw ArgumentError.value(rpcTimeout, 'rpcTimeout', 'must be positive');
    }
    return LightwalletdClient._(stub: stub, rpcTimeout: rpcTimeout);
  }

  CallOptions get _callOptions => CallOptions(timeout: rpcTimeout);

  Future<LightdInfo> getInfo() =>
      _stub.getLightdInfo(Empty(), options: _callOptions);

  Future<BlockID> getLatestBlock() =>
      _stub.getLatestBlock(ChainSpec(), options: _callOptions);

  Future<CompactBlock> getBlock(BlockID id) =>
      _stub.getBlock(id, options: _callOptions);

  Stream<CompactBlock> getBlockRange(BlockRange range) {
    final rangeLabel = _validateHeightRange(range, method: 'GetBlockRange');
    return _getBlockRange(range, rangeLabel);
  }

  Stream<CompactBlock> _getBlockRange(
    BlockRange range,
    String rangeLabel,
  ) async* {
    if (range.poolTypes.isNotEmpty) {
      await _assertPoolTypesSupported(rangeLabel);
    }
    try {
      await for (final block in _stub.getBlockRange(
        range,
        options: _callOptions,
      )) {
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

  Stream<CompactBlock> getBlockRangeByHeight(
    int start,
    int end, {
    Iterable<PoolType> poolTypes = const [],
  }) => getBlockRange(
    BlockRange()
      ..start = (BlockID()..height = Int64(start))
      ..end = (BlockID()..height = Int64(end))
      ..poolTypes.addAll(poolTypes),
  );

  Future<void> _assertPoolTypesSupported(String rangeLabel) async {
    final version = (await getInfo()).lightwalletProtocolVersion;
    final match = RegExp(
      r'^v?(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$',
    ).firstMatch(version);
    final supported =
        match != null &&
        (int.parse(match.group(1)!) > 0 || int.parse(match.group(2)!) >= 4);
    if (!supported) {
      throw LightwalletdClientException(
        'server does not advertise lightwallet protocol v0.4.0 or newer; '
        'non-default compact-block pool requests are unsafe',
        method: 'GetBlockRange',
        range: rangeLabel,
      );
    }
  }

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
      _stub.getAddressUtxosStream(arg, options: _callOptions);

  Future<List<GetAddressUtxosReply>> getAddressUtxos(
    List<String> addresses, {
    int startHeight = 0,
    int maxEntries = 0,
  }) {
    if (addresses.isEmpty || addresses.any((address) => address.isEmpty)) {
      throw ArgumentError.value(
        addresses,
        'addresses',
        'must contain at least one non-empty transparent address',
      );
    }
    if (startHeight < 0 || maxEntries < 0) {
      throw ArgumentError('startHeight and maxEntries must be non-negative');
    }
    final request = GetAddressUtxosArg()
      ..addresses.addAll(addresses)
      ..startHeight = Int64(startHeight)
      ..maxEntries = maxEntries;
    return _stub.getAddressUtxosStream(request, options: _callOptions).toList();
  }

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
