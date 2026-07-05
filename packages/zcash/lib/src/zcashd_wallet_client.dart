import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models/spend.dart';
import 'zebra_client.dart';

/// zcashd `z_getaddressforaccount` receiver type strings.
abstract final class ZcashdReceiverType {
  static const String p2pkh = 'p2pkh';
  static const String sapling = 'sapling';
  static const String orchard = 'orchard';

  static const List<String> unifiedAddressReceivers = <String>[
    p2pkh,
    sapling,
    orchard,
  ];

  static const Set<String> supported = <String>{p2pkh, sapling, orchard};
}

class ZcashdWalletException implements Exception {
  final String message;
  final String? method;
  final String? operationId;
  final Object? cause;

  const ZcashdWalletException(
    this.message, {
    this.method,
    this.operationId,
    this.cause,
  });

  @override
  String toString() {
    final parts = <String>['ZcashdWalletException: $message'];
    if (method != null) parts.add('method=$method');
    if (operationId != null) parts.add('opid=$operationId');
    if (cause != null) parts.add('cause=$cause');
    return parts.join(' ');
  }
}

class ZcashdWalletClient {
  static const int defaultFeeZatoshis = 10000;
  static const int defaultShieldCoinbaseLimit = 50;
  static const String defaultNetwork = 'regtest';
  static const Set<String> _safetyBoundedWalletMethods = {
    'z_importkey',
    'z_sendmany',
    'z_shieldcoinbase',
    'z_getoperationstatus',
    'z_getoperationresult',
  };

  final Uri _endpoint;
  final http.Client _http;
  final String? _authHeader;
  final Duration timeout;
  final Duration pollInterval;
  final String network;
  final bool unsafeAllowNonLocalOrNonRegtestWalletRpc;
  int _id = 0;

  ZcashdWalletClient({
    String host = 'localhost',
    int port = 8232,
    String? username,
    String? password,
    this.timeout = const Duration(seconds: 30),
    this.pollInterval = const Duration(seconds: 1),
    this.network = defaultNetwork,
    this.unsafeAllowNonLocalOrNonRegtestWalletRpc = false,
    http.Client? client,
  }) : _endpoint = Uri.http('$host:$port', '/'),
       _authHeader = (username != null && password != null)
           ? 'Basic ${base64Encode(utf8.encode('$username:$password'))}'
           : null,
       _http = client ?? http.Client();

  void close() => _http.close();

  void _checkWalletRpcSafety(String method) {
    if (!_safetyBoundedWalletMethods.contains(method) ||
        unsafeAllowNonLocalOrNonRegtestWalletRpc) {
      return;
    }

    final reasons = <String>[];
    if (!_isLoopbackHost(_endpoint.host)) {
      reasons.add('endpoint is not loopback');
    }
    if (!_isRegtestNetwork(network)) {
      reasons.add('network is not regtest');
    }
    if (reasons.isEmpty) return;

    throw ZcashdWalletException(
      'Refusing wallet RPC outside localhost/regtest safety boundary: '
      '${reasons.join(', ')}; endpoint=${_redactedEndpoint(_endpoint)}, '
      'network=${_redactedNetwork(network)}. '
      'Pass unsafeAllowNonLocalOrNonRegtestWalletRpc: true only for reviewed '
      'non-local/non-regtest wallet RPC use.',
      method: method,
    );
  }

  Future<dynamic> _call(String method, [List<dynamic>? params]) async {
    _checkWalletRpcSafety(method);

    final headers = <String, String>{'Content-Type': 'application/json'};
    if (_authHeader != null) headers['Authorization'] = _authHeader;

    final body = jsonEncode({
      'jsonrpc': '2.0',
      'method': method,
      'params': params ?? [],
      'id': ++_id,
    });

    late http.Response response;
    try {
      response = await _http
          .post(_endpoint, headers: headers, body: body)
          .timeout(timeout);
    } on TimeoutException catch (error) {
      throw ZcashdWalletException(
        'RPC method timed out after $timeout',
        method: method,
        cause: error,
      );
    } on Object catch (error) {
      throw ZcashdWalletException(
        'RPC transport failed',
        method: method,
        cause: error,
      );
    }

    final Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(response.body) as Map<String, dynamic>;
    } on Object catch (error) {
      throw ZcashdWalletException(
        'RPC response was not valid JSON object',
        method: method,
        cause: error,
      );
    }

    if (decoded['error'] != null) {
      final err = decoded['error'] as Map<String, dynamic>;
      throw ZebraRpcException(
        (err['code'] as num).toInt(),
        err['message'] as String,
      );
    }

    if (!decoded.containsKey('result')) {
      throw ZcashdWalletException(
        'RPC response missing result',
        method: method,
      );
    }

    return decoded['result'];
  }

  T _parse<T>(String method, T Function() parse) {
    try {
      return parse();
    } on ZcashModelException catch (error) {
      throw ZcashdWalletException(
        'Failed to parse $method response: ${error.message}',
        method: method,
        cause: error,
      );
    } on TypeError catch (error) {
      throw ZcashdWalletException(
        'Failed to parse $method response',
        method: method,
        cause: error,
      );
    }
  }

  Future<List<String>> generate(int blockCount) async {
    if (blockCount <= 0) {
      throw const ZcashdWalletException(
        'generate block count must be positive',
        method: 'generate',
      );
    }
    final result = await _call('generate', [blockCount]);
    return _parse(
      'generate',
      () => (result as List).map((value) => value as String).toList(),
    );
  }

  Future<int> zGetNewAccount() async {
    final result = await _call('z_getnewaccount');
    return _parse('z_getnewaccount', () {
      if (result is num) return result.toInt();
      if (result is Map) {
        final account = result['account'];
        if (account is num) return account.toInt();
      }
      throw ZcashModelException(
        'z_getnewaccount result missing numeric account',
      );
    });
  }

  Future<String> zGetAddressForAccount(
    int account, {
    List<String>? receiverTypes,
  }) async {
    final params = <dynamic>[account];
    if (receiverTypes != null) {
      params.add(_validatedReceiverTypes(receiverTypes));
    }
    final result = await _call('z_getaddressforaccount', params);
    return _parse('z_getaddressforaccount', () {
      if (result is String) return result;
      if (result is Map) {
        final address = result['address'];
        if (address is String && address.isNotEmpty) return address;
      }
      throw ZcashModelException(
        'z_getaddressforaccount result missing address',
      );
    });
  }

  Future<ZImportKeyResult> zImportKey(
    String zkey, {
    String rescan = 'no',
    int? startHeight,
  }) async {
    if (zkey.isEmpty) {
      throw const ZcashdWalletException(
        'z_importkey key cannot be empty',
        method: 'z_importkey',
      );
    }

    final params = <dynamic>[zkey, rescan];
    if (startHeight != null) params.add(startHeight);

    final result = await _callZImportKey(zkey, params);
    return _parse('z_importkey', () => ZImportKeyResult.fromRpcResult(result));
  }

  Future<dynamic> _callZImportKey(String zkey, List<dynamic> params) async {
    try {
      return await _call('z_importkey', params);
    } on ZebraRpcException catch (error) {
      final redactedMessage = _redactSensitive(error.message, [zkey]);
      throw ZcashdWalletException(
        'z_importkey rejected key prefix=${_redactedKeyPrefix(zkey)}: '
        'code=${error.code}, message=$redactedMessage',
        method: 'z_importkey',
        cause: ZebraRpcException(error.code, redactedMessage),
      );
    }
  }

  Future<String> zSendMany(
    String fromAddress,
    List<ZSendRecipient> recipients, {
    int? minConf,
    int? feeZatoshis,
    PrivacyPolicy? privacyPolicy,
  }) async {
    if (recipients.isEmpty) {
      throw const ZcashdWalletException(
        'z_sendmany recipients cannot be empty',
      );
    }
    final params = <dynamic>[
      fromAddress,
      recipients.map((recipient) => recipient.toJson()).toList(),
    ];
    if (minConf != null || feeZatoshis != null || privacyPolicy != null) {
      params.add(minConf ?? 1);
    }
    if (feeZatoshis != null || privacyPolicy != null) {
      params.add(zatoshisToZecJsonValue(feeZatoshis ?? defaultFeeZatoshis));
    }
    if (privacyPolicy != null) params.add(privacyPolicy.rpcValue);

    final result = await _call('z_sendmany', params);
    return _parse('z_sendmany', () => result as String);
  }

  Future<ShieldCoinbaseResult> zShieldCoinbase(
    String fromAddress,
    String toAddress, {
    int? feeZatoshis,
    int? limit,
    PrivacyPolicy? privacyPolicy,
  }) async {
    final params = <dynamic>[fromAddress, toAddress];
    if (feeZatoshis != null || limit != null || privacyPolicy != null) {
      params.add(zatoshisToZecJsonValue(feeZatoshis ?? defaultFeeZatoshis));
    }
    if (limit != null || privacyPolicy != null) {
      params.add(limit ?? defaultShieldCoinbaseLimit);
    }
    if (privacyPolicy != null) params.add(privacyPolicy.rpcValue);

    final result = await _call('z_shieldcoinbase', params);
    return _parse(
      'z_shieldcoinbase',
      () => ShieldCoinbaseResult.fromJson(result as Map<String, dynamic>),
    );
  }

  Future<List<ZcashOperationStatus>> zGetOperationStatus(
    List<String> operationIds,
  ) async {
    final result = await _call('z_getoperationstatus', [operationIds]);
    return _parse(
      'z_getoperationstatus',
      () => (result as List)
          .map(
            (value) => ZcashOperationStatus.fromJson(
              Map<String, dynamic>.from(value as Map),
            ),
          )
          .toList(),
    );
  }

  Future<List<ZcashOperationStatus>> zGetOperationResult(
    List<String> operationIds,
  ) async {
    final result = await _call('z_getoperationresult', [operationIds]);
    return _parse(
      'z_getoperationresult',
      () => (result as List)
          .map(
            (value) => ZcashOperationStatus.fromJson(
              Map<String, dynamic>.from(value as Map),
            ),
          )
          .toList(),
    );
  }

  Future<ZcashOperationStatus> waitForOperation(
    String operationId, {
    Duration? timeout,
    Duration? pollInterval,
  }) async {
    final effectiveTimeout = timeout ?? this.timeout;
    final effectivePollInterval = pollInterval ?? this.pollInterval;
    final deadline = DateTime.now().add(effectiveTimeout);
    ZcashOperationStatus? lastMatchingStatus;
    _OperationPollDiagnostics lastDiagnostics =
        const _OperationPollDiagnostics.empty();

    while (DateTime.now().isBefore(deadline)) {
      final pollResult = await _pollOperationStatus(operationId);
      lastDiagnostics = pollResult.diagnostics;
      final matchingStatus = pollResult.matchingStatus;
      if (matchingStatus != null) {
        lastMatchingStatus = matchingStatus;
        if (matchingStatus.isSuccess) return matchingStatus;
        if (matchingStatus.isFailed) {
          throw ZcashdWalletException(
            'Operation failed with status ${matchingStatus.status}'
            '${matchingStatus.errorMessage != null ? ': ${matchingStatus.errorMessage}' : ''}. '
            'Last matching status: ${matchingStatus.safeSummary}',
            method: 'z_getoperationstatus',
            operationId: operationId,
          );
        }
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) break;
      final delay = effectivePollInterval < remaining
          ? effectivePollInterval
          : remaining;
      await Future<void>.delayed(delay);
    }

    throw ZcashdWalletException(
      'Timed out waiting for operation. Last matching status: '
      '${lastMatchingStatus?.safeSummary ?? 'none'}. '
      '${lastDiagnostics.safeSummary}',
      method: 'z_getoperationstatus',
      operationId: operationId,
    );
  }

  Future<_OperationPollResult> _pollOperationStatus(String operationId) async {
    final result = await _call('z_getoperationstatus', [
      [operationId],
    ]);
    try {
      final rawStatuses = result as List;
      var totalStatuses = 0;
      var malformedStatuses = 0;
      var nonMatchingStatuses = 0;
      ZcashOperationStatus? matchingStatus;

      for (final rawStatus in rawStatuses) {
        totalStatuses += 1;
        if (rawStatus is! Map) {
          malformedStatuses += 1;
          continue;
        }

        final statusJson = Map<String, dynamic>.from(rawStatus);
        final statusOperationId = statusJson['id'];
        if (statusOperationId is! String || statusOperationId.isEmpty) {
          malformedStatuses += 1;
          continue;
        }
        if (statusOperationId != operationId) {
          nonMatchingStatuses += 1;
          continue;
        }

        matchingStatus = ZcashOperationStatus.fromJson(statusJson);
      }

      return _OperationPollResult(
        matchingStatus: matchingStatus,
        diagnostics: _OperationPollDiagnostics(
          totalStatuses: totalStatuses,
          nonMatchingStatuses: nonMatchingStatuses,
          malformedStatuses: malformedStatuses,
        ),
      );
    } on ZcashModelException catch (error) {
      throw ZcashdWalletException(
        'Failed to parse matching operation status: ${error.message}',
        method: 'z_getoperationstatus',
        operationId: operationId,
        cause: error,
      );
    } on TypeError catch (error) {
      throw ZcashdWalletException(
        'Failed to parse operation status poll response',
        method: 'z_getoperationstatus',
        operationId: operationId,
        cause: error,
      );
    }
  }

  Future<int> getBalance({
    String account = '*',
    int? minConf,
    bool? includeWatchOnly,
  }) async {
    final params = <dynamic>[account];
    if (minConf != null || includeWatchOnly != null) params.add(minConf ?? 1);
    if (includeWatchOnly != null) params.add(includeWatchOnly);
    final result = await _call('getbalance', params);
    return _parse(
      'getbalance',
      () => zecJsonValueToZatoshis(result, field: 'getbalance'),
    );
  }

  Future<ZcashTotalBalance> zGetTotalBalance({
    int? minConf,
    bool? includeWatchOnly,
  }) async {
    final params = <dynamic>[];
    if (minConf != null || includeWatchOnly != null) params.add(minConf ?? 1);
    if (includeWatchOnly != null) params.add(includeWatchOnly);
    final result = await _call('z_gettotalbalance', params);
    return _parse(
      'z_gettotalbalance',
      () => ZcashTotalBalance.fromJson(result as Map<String, dynamic>),
    );
  }

  Future<dynamic> getRawMempool({bool verbose = false}) async {
    return _call('getrawmempool', [verbose]);
  }

  Future<dynamic> getBlock(String hashOrHeight, {int verbosity = 1}) async {
    return _call('getblock', [hashOrHeight, verbosity]);
  }

  Future<dynamic> getRawTransaction(String txid, {int verbosity = 0}) async {
    return _call('getrawtransaction', [txid, verbosity]);
  }
}

List<String> _validatedReceiverTypes(List<String> receiverTypes) {
  if (receiverTypes.isEmpty) {
    throw const ZcashdWalletException(
      'z_getaddressforaccount receiverTypes cannot be empty',
      method: 'z_getaddressforaccount',
    );
  }

  final unsupported = receiverTypes
      .where((type) => !ZcashdReceiverType.supported.contains(type))
      .toList();
  if (unsupported.isNotEmpty) {
    throw ZcashdWalletException(
      'z_getaddressforaccount unsupported receiver type(s): '
      '${unsupported.map(_safeReceiverTypeLabel).join(', ')}. Supported: '
      '${ZcashdReceiverType.supported.join(', ')}',
      method: 'z_getaddressforaccount',
    );
  }

  return List<String>.unmodifiable(receiverTypes);
}

bool _isLoopbackHost(String host) {
  var normalized = host.trim().toLowerCase();
  if (normalized.endsWith('.')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  if (normalized.startsWith('[') && normalized.endsWith(']')) {
    normalized = normalized.substring(1, normalized.length - 1);
  }

  if (normalized == 'localhost' || normalized == '::1') return true;

  final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)\.(\d+)$').firstMatch(normalized);
  if (match == null) return false;
  final octets = <int>[];
  for (var i = 1; i <= 4; i += 1) {
    final octet = int.tryParse(match.group(i)!);
    if (octet == null || octet < 0 || octet > 255) return false;
    octets.add(octet);
  }
  return octets.first == 127;
}

bool _isRegtestNetwork(String network) =>
    network.trim().toLowerCase() == 'regtest';

String _redactedEndpoint(Uri endpoint) {
  final host = endpoint.host.contains(':')
      ? '[${endpoint.host}]'
      : endpoint.host;
  final port = endpoint.hasPort ? ':${endpoint.port}' : '';
  final path = endpoint.path.isEmpty ? '/' : endpoint.path;
  return '${endpoint.scheme}://$host$port$path';
}

String _redactedNetwork(String network) {
  final cleaned = network.replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();
  if (cleaned.isEmpty) return '<empty>';
  if (cleaned.length <= 64) return cleaned;
  return '${cleaned.substring(0, 64)}…';
}

String _safeReceiverTypeLabel(String receiverType) {
  final cleaned = receiverType.replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();
  if (cleaned.isEmpty) return '<empty>';
  if (cleaned.length <= 64) return cleaned;
  return '${cleaned.substring(0, 64)}…';
}

extension _ZcashOperationStatusDiagnostics on ZcashOperationStatus {
  String get safeSummary {
    final parts = <String>['status=$status'];
    if (errorMessage != null && errorMessage!.isNotEmpty) {
      parts.add('error=$errorMessage');
    }
    return parts.join(',');
  }
}

class _OperationPollResult {
  final ZcashOperationStatus? matchingStatus;
  final _OperationPollDiagnostics diagnostics;

  const _OperationPollResult({
    required this.matchingStatus,
    required this.diagnostics,
  });
}

class _OperationPollDiagnostics {
  final int totalStatuses;
  final int nonMatchingStatuses;
  final int malformedStatuses;

  const _OperationPollDiagnostics({
    required this.totalStatuses,
    required this.nonMatchingStatuses,
    required this.malformedStatuses,
  });

  const _OperationPollDiagnostics.empty()
    : totalStatuses = 0,
      nonMatchingStatuses = 0,
      malformedStatuses = 0;

  String get safeSummary =>
      'poll observed statuses=$totalStatuses, nonMatching=$nonMatchingStatuses, '
      'malformed=$malformedStatuses';
}

String _redactedKeyPrefix(String zkey) {
  if (zkey.isEmpty) return '<empty>';
  final end = zkey.length < 12 ? zkey.length : 12;
  return '${zkey.substring(0, end)}…(${zkey.length} chars)';
}

String _redactSensitive(String message, Iterable<String> sensitiveValues) {
  var redacted = message;
  for (final value in sensitiveValues) {
    if (value.isEmpty) continue;
    redacted = redacted.replaceAll(value, '<redacted-zkey>');
  }
  return redacted.replaceAll(
    RegExp(r'secret-extended-key-(?:main|test)[0-9a-z]+', caseSensitive: false),
    'secret-extended-key-<redacted>',
  );
}
