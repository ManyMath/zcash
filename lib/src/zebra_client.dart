import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models/blockchain_info.dart';

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
}
