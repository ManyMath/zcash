import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models/blockchain_info.dart';
import 'models/block.dart';
import 'models/transaction.dart';
import 'models/address.dart';
import 'models/tree_state.dart';

class ZebraRpcException implements Exception {
  final int code;
  final String message;

  const ZebraRpcException(this.code, this.message);

  @override
  String toString() => 'ZebraRpcException($code): $message';
}

class ZebraClient {
  final Uri _endpoint;
  final http.Client _http;
  int _id = 0;

  ZebraClient({String host = 'localhost', int port = 8232, http.Client? client})
      : _endpoint = Uri.http('$host:$port', '/'),
        _http = client ?? http.Client();

  void close() => _http.close();

  Future<dynamic> _call(String method, [List<dynamic>? params]) async {
    final body = jsonEncode({
      'jsonrpc': '2.0',
      'method': method,
      'params': params ?? [],
      'id': ++_id,
    });

    final response = await _http.post(
      _endpoint,
      headers: const {'Content-Type': 'application/json'},
      body: body,
    );

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;

    if (decoded['error'] != null) {
      final err = decoded['error'] as Map<String, dynamic>;
      throw ZebraRpcException(
        (err['code'] as num).toInt(),
        err['message'] as String,
      );
    }

    return decoded['result'];
  }

  Future<NodeInfo> getInfo() async {
    final result = await _call('getinfo');
    return NodeInfo.fromJson(result as Map<String, dynamic>);
  }

  Future<BlockchainInfo> getBlockchainInfo() async {
    final result = await _call('getblockchaininfo');
    return BlockchainInfo.fromJson(result as Map<String, dynamic>);
  }

  Future<String> getBestBlockHash() async {
    return await _call('getbestblockhash') as String;
  }

  Future<BlockHeightAndHash> getBestBlockHeightAndHash() async {
    final result = await _call('getbestblockheightandhash');
    return BlockHeightAndHash.fromJson(result as Map<String, dynamic>);
  }

  Future<String> getRawBlock(String hashOrHeight) async {
    return await _call('getblock', [hashOrHeight, 0]) as String;
  }

  Future<BlockInfo> getBlock(String hashOrHeight) async {
    final result = await _call('getblock', [hashOrHeight, 1]);
    return BlockInfo.fromJson(result as Map<String, dynamic>);
  }

  Future<String> getRawTransaction(String txid) async {
    return await _call('getrawtransaction', [txid, 0]) as String;
  }

  Future<TransactionInfo> getTransaction(String txid) async {
    final result = await _call('getrawtransaction', [txid, 1]);
    return TransactionInfo.fromJson(result as Map<String, dynamic>);
  }

  Future<String> sendRawTransaction(String txHex) async {
    return await _call('sendrawtransaction', [txHex]) as String;
  }

  Future<List<String>> getRawMempool() async {
    final result = await _call('getrawmempool');
    return (result as List).cast<String>();
  }

  Future<AddressBalance> getAddressBalance(List<String> addresses) async {
    final result =
        await _call('getaddressbalance', [{'addresses': addresses}]);
    return AddressBalance.fromJson(result as Map<String, dynamic>);
  }

  Future<List<String>> getAddressTxIds(
    List<String> addresses, {
    int? startHeight,
    int? endHeight,
  }) async {
    final params = <String, dynamic>{'addresses': addresses};
    if (startHeight != null) params['start'] = startHeight;
    if (endHeight != null) params['end'] = endHeight;
    final result = await _call('getaddresstxids', [params]);
    return (result as List).cast<String>();
  }

  Future<List<AddressUtxo>> getAddressUtxos(List<String> addresses) async {
    final result =
        await _call('getaddressutxos', [{'addresses': addresses}]);
    return (result as List)
        .map((e) => AddressUtxo.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<TreeState> getTreeState(String hashOrHeight) async {
    final result = await _call('z_gettreestate', [hashOrHeight]);
    return TreeState.fromJson(result as Map<String, dynamic>);
  }

  Future<SubtreeList> getSubtreesByIndex(
    String pool,
    int startIndex, {
    int? limit,
  }) async {
    final result = await _call('z_getsubtreesbyindex', [
      pool,
      startIndex,
      if (limit != null) limit,
    ]);
    return SubtreeList.fromJson(result as Map<String, dynamic>);
  }
}
