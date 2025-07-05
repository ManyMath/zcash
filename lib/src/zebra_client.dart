import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models/blockchain_info.dart';
import 'models/block.dart';
import 'models/transaction.dart';
import 'models/address.dart';
import 'models/tree_state.dart';
import 'models/block_header.dart';
import 'models/subsidy.dart';
import 'models/network.dart';
import 'models/validation.dart';

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
  final String? _authHeader;
  final Duration timeout;
  int _id = 0;

  ZebraClient({
    String host = 'localhost',
    int port = 8232,
    String? username,
    String? password,
    this.timeout = const Duration(seconds: 30),
    http.Client? client,
  })  : _endpoint = Uri.http('$host:$port', '/'),
        _authHeader = (username != null && password != null)
            ? 'Basic ${base64Encode(utf8.encode('$username:$password'))}'
            : null,
        _http = client ?? http.Client();

  void close() => _http.close();

  Future<dynamic> _call(String method, [List<dynamic>? params]) async {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (_authHeader != null) headers['Authorization'] = _authHeader;

    final body = jsonEncode({
      'jsonrpc': '2.0',
      'method': method,
      'params': params ?? [],
      'id': ++_id,
    });

    final response = await _http
        .post(_endpoint, headers: headers, body: body)
        .timeout(timeout);

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

  Future<void> invalidateBlock(String hash) async {
    await _call('invalidateblock', [hash]);
  }

  // command: 'add' | 'remove' | 'onetry'.
  Future<void> addNode(String node, String command) async {
    await _call('addnode', [node, command]);
  }

  Future<AddressValidation> validateAddress(String address) async {
    final result = await _call('validateaddress', [address]);
    return AddressValidation.fromJson(result as Map<String, dynamic>);
  }

  Future<AddressValidation> zValidateAddress(String address) async {
    final result = await _call('z_validateaddress', [address]);
    return AddressValidation.fromJson(result as Map<String, dynamic>);
  }

  Future<void> reconsiderBlock(String hash) async {
    await _call('reconsiderblock', [hash]);
  }

  // Regtest only.
  Future<void> stop() async {
    await _call('stop');
  }

  Future<BlockHeader> getBlockHeader(String hashOrHeight) async {
    final result = await _call('getblockheader', [hashOrHeight, true]);
    return BlockHeader.fromJson(result as Map<String, dynamic>);
  }

  Future<BlockSubsidy> getBlockSubsidy({int? height}) async {
    final params = height != null ? [height] : <dynamic>[];
    final result = await _call('getblocksubsidy', params);
    return BlockSubsidy.fromJson(result as Map<String, dynamic>);
  }

  Future<List<PeerInfo>> getPeerInfo() async {
    final result = await _call('getpeerinfo');
    return (result as List)
        .map((e) => PeerInfo.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<NetworkInfo> getNetworkInfo() async {
    final result = await _call('getnetworkinfo');
    return NetworkInfo.fromJson(result as Map<String, dynamic>);
  }

  Future<double> getDifficulty() async {
    return (await _call('getdifficulty') as num).toDouble();
  }

  Future<BlockInfoFull> getBlockFull(String hashOrHeight) async {
    final result = await _call('getblock', [hashOrHeight, 2]);
    return BlockInfoFull.fromJson(result as Map<String, dynamic>);
  }
}
