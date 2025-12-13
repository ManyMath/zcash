import 'dart:typed_data';

import 'package:grpc/grpc.dart';

import 'grpc/service.pbgrpc.dart';
import 'grpc/compact_formats.pb.dart';

export 'grpc/compact_formats.pb.dart';
export 'grpc/compact_formats.pbenum.dart';
// TreeState clashes with the JSON-RPC model of the same name.
export 'grpc/service.pb.dart' hide TreeState;
export 'grpc/service.pbenum.dart';

class LightwalletdClient {
  final ClientChannel _channel;
  final CompactTxStreamerClient _stub;

  LightwalletdClient._({
    required ClientChannel channel,
    required CompactTxStreamerClient stub,
  })  : _channel = channel,
        _stub = stub;

  factory LightwalletdClient({
    String host = 'localhost',
    int port = 9067,
    bool useTls = true,
    ChannelCredentials? credentials,
  }) {
    final creds = credentials ??
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

  Future<LightdInfo> getInfo() => _stub.getLightdInfo(Empty());

  Future<BlockID> getLatestBlock() => _stub.getLatestBlock(ChainSpec());

  Future<CompactBlock> getBlock(BlockID id) => _stub.getBlock(id);

  Stream<CompactBlock> getBlockRange(BlockRange range) =>
      _stub.getBlockRange(range);

  Future<RawTransaction> getTransaction(TxFilter filter) =>
      _stub.getTransaction(filter);

  Future<SendResponse> sendTransaction(Uint8List txBytes) {
    final raw = RawTransaction()..data = txBytes;
    return _stub.sendTransaction(raw);
  }

  Stream<RawTransaction> getTaddressTxids(
          TransparentAddressBlockFilter filter) =>
      _stub.getTaddressTransactions(filter);

  Future<Balance> getTaddressBalance(List<String> addresses) {
    final req = AddressList()..addresses.addAll(addresses);
    return _stub.getTaddressBalance(req);
  }

  Stream<GetAddressUtxosReply> getTaddressUtxos(GetAddressUtxosArg arg) =>
      _stub.getAddressUtxosStream(arg);

  Stream<CompactTx> getMempoolTx(GetMempoolTxRequest request) =>
      _stub.getMempoolTx(request);

  Future<TreeState> getTreeState(BlockID id) => _stub.getTreeState(id);

  Future<TreeState> getLatestTreeState() =>
      _stub.getLatestTreeState(Empty());

  Stream<SubtreeRoot> getSubtreeRoots(GetSubtreeRootsArg arg) =>
      _stub.getSubtreeRoots(arg);

  Future<void> close() => _channel.shutdown();
}
