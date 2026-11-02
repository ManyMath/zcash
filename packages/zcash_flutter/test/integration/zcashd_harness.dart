library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:zcash_flutter/zcash_flutter.dart';

import 'docker_image_policy.dart';

const _kReadinessTimeout = Duration(seconds: 180);
const _kRpcTimeout = Duration(seconds: 5);
const _kLogLimit = 8192;

class ZcashdHarnessException implements Exception {
  final String message;
  final String phase;
  final int rpcPort;
  final String launch;
  final String? daemonVersion;
  final Object? cause;
  final String stdoutTail;
  final String stderrTail;

  const ZcashdHarnessException(
    this.message, {
    required this.phase,
    required this.rpcPort,
    required this.launch,
    this.daemonVersion,
    this.cause,
    this.stdoutTail = '',
    this.stderrTail = '',
  });

  @override
  String toString() {
    final parts = <String>[
      'ZcashdHarnessException: $message',
      'phase=$phase',
      'rpcPort=$rpcPort',
      'launch=$launch',
    ];
    if (daemonVersion != null && daemonVersion!.isNotEmpty) {
      parts.add('daemonVersion=$daemonVersion');
    }
    if (cause != null) parts.add('cause=$cause');
    if (stdoutTail.isNotEmpty) parts.add('stdoutTail=$stdoutTail');
    if (stderrTail.isNotEmpty) parts.add('stderrTail=$stderrTail');
    return _BoundedLog._redact(parts.join('\n'));
  }
}

class ZcashdHarness {
  final Process _process;
  final Directory _tmpDir;
  final _ZcashdRawRpc _rpc;
  final _BoundedLog _stdout;
  final _BoundedLog _stderr;
  final bool _usesDocker;
  final String _dockerImage;
  bool _shutdown = false;

  final ZcashdWalletClient client;
  final int rpcPort;
  final String rpcUser;
  final String rpcPassword;
  final String zcashdVersion;
  final String launch;

  List<String> lastGeneratedBlockHashes = const [];

  ZcashdHarness._({
    required Process process,
    required Directory tmpDir,
    required _ZcashdRawRpc rpc,
    required this.client,
    required this.rpcPort,
    required this.rpcUser,
    required this.rpcPassword,
    required this.zcashdVersion,
    required this.launch,
    required _BoundedLog stdout,
    required _BoundedLog stderr,
    required bool usesDocker,
    required String dockerImage,
  }) : _process = process,
       _tmpDir = tmpDir,
       _rpc = rpc,
       _stdout = stdout,
       _stderr = stderr,
       _usesDocker = usesDocker,
       _dockerImage = dockerImage;

  static Future<ZcashdHarness> start() async {
    var phase = 'validate-launch';
    final bin = Platform.environment['ZCASHD_BIN'];
    final usesDocker = bin == null || bin.isEmpty;
    final dockerImage = usesDocker
        ? requireDigestPinnedDockerImage(
            image: Platform.environment['ZCASHD_DOCKER_IMAGE'],
            imageEnvName: 'ZCASHD_DOCKER_IMAGE',
            binaryEnvName: 'ZCASHD_BIN',
            serviceName: 'zcashd',
          )
        : '';
    final launch = usesDocker ? 'docker image $dockerImage' : 'bin $bin';

    phase = 'allocate-port';
    final rpcPort = await _freePort();
    phase = 'create-tempdir';
    final tmpDir = await Directory.systemTemp.createTemp('zcashd-regtest-');
    final dataDir = Directory('${tmpDir.path}/data');
    await dataDir.create(recursive: true);
    await Process.run('chmod', ['777', tmpDir.path]);
    await Process.run('chmod', ['777', dataDir.path]);

    final rpcUser = 'zcashd_${_randomToken(9)}';
    final rpcPassword = _randomToken(24);
    phase = 'write-config';
    await _writeConfig(tmpDir.path, rpcPort, rpcUser, rpcPassword);

    final stdoutLog = _BoundedLog();
    final stderrLog = _BoundedLog();

    late Process process;
    try {
      phase = 'process-start';
      if (usesDocker) {
        process = await Process.start('docker', [
          'run',
          '--rm',
          '--network=host',
          '-v',
          '${tmpDir.path}:/srv/zcashd/.zcash',
          dockerImage,
        ]);
      } else {
        process = await Process.start(bin, [
          '-conf=${tmpDir.path}/zcash.conf',
          '-datadir=${dataDir.path}',
          '-printtoconsole',
        ]);
      }
    } on Object catch (error) {
      await _cleanupTempDir(tmpDir, usesDocker, dockerImage);
      throw ZcashdHarnessException(
        'failed to start zcashd',
        phase: phase,
        rpcPort: rpcPort,
        launch: launch,
        cause: error,
      );
    }

    process.stdout.transform(utf8.decoder).listen(stdoutLog.add);
    process.stderr.transform(utf8.decoder).listen(stderrLog.add);

    var exited = false;
    int? exitCode;
    unawaited(
      process.exitCode.then((code) {
        exited = true;
        exitCode = code;
      }),
    );

    final rawRpc = _ZcashdRawRpc(
      port: rpcPort,
      username: rpcUser,
      password: rpcPassword,
    );
    final walletClient = ZcashdWalletClient(
      port: rpcPort,
      username: rpcUser,
      password: rpcPassword,
      timeout: _kRpcTimeout,
      pollInterval: const Duration(seconds: 1),
    );

    try {
      phase = 'readiness:getblockchaininfo';
      await _awaitReady(rawRpc, () => exited, () => exitCode);
      phase = 'version:getnetworkinfo';
      final version = await _readDaemonVersion(rawRpc);
      return ZcashdHarness._(
        process: process,
        tmpDir: tmpDir,
        rpc: rawRpc,
        client: walletClient,
        rpcPort: rpcPort,
        rpcUser: rpcUser,
        rpcPassword: rpcPassword,
        zcashdVersion: version,
        launch: launch,
        stdout: stdoutLog,
        stderr: stderrLog,
        usesDocker: usesDocker,
        dockerImage: dockerImage,
      );
    } on Object catch (error) {
      process.kill(ProcessSignal.sigterm);
      await _waitForExit(process, const Duration(seconds: 5));
      walletClient.close();
      rawRpc.close();
      await _cleanupTempDir(tmpDir, usesDocker, dockerImage);
      if (error is ZcashdHarnessException) rethrow;
      throw ZcashdHarnessException(
        'zcashd did not become ready',
        phase: phase,
        rpcPort: rpcPort,
        launch: launch,
        cause: error,
        stdoutTail: stdoutLog.tail,
        stderrTail: stderrLog.tail,
      );
    }
  }

  Future<int> getBlockCount() async {
    final result = await _rpc.call('getblockcount');
    return (result as num).toInt();
  }

  Future<List<String>> mineBlocks(int count) async {
    final hashes = await client.generate(count);
    lastGeneratedBlockHashes = List.unmodifiable(hashes);
    return hashes;
  }

  Future<Map<String, dynamic>> getBlockchainInfo() async {
    final result = await _rpc.call('getblockchaininfo');
    return Map<String, dynamic>.from(result as Map);
  }

  Future<void> shutdown() async {
    if (_shutdown) return;
    _shutdown = true;
    try {
      await _rpc.call('stop').timeout(const Duration(seconds: 5));
    } catch (_) {}

    var stopped = await _waitForExit(_process, const Duration(seconds: 12));
    if (!stopped) {
      _process.kill(ProcessSignal.sigterm);
      stopped = await _waitForExit(_process, const Duration(seconds: 5));
    }
    if (!stopped) {
      _process.kill(ProcessSignal.sigkill);
      await _waitForExit(_process, const Duration(seconds: 5));
    }

    client.close();
    _rpc.close();
    await _cleanupTempDir(_tmpDir, _usesDocker, _dockerImage);
  }

  String diagnosticSummary({String phase = 'runtime'}) {
    return ZcashdHarnessException(
      'diagnostic snapshot',
      phase: phase,
      rpcPort: rpcPort,
      launch: launch,
      daemonVersion: zcashdVersion,
      stdoutTail: _stdout.tail,
      stderrTail: _stderr.tail,
    ).toString();
  }

  static Future<void> _writeConfig(
    String dir,
    int rpcPort,
    String rpcUser,
    String rpcPassword,
  ) async {
    final src =
        '''
regtest=1
server=1
rpcuser=$rpcUser
rpcpassword=$rpcPassword
rpcbind=127.0.0.1
rpcallowip=127.0.0.1
rpcport=$rpcPort
listen=0
txindex=1
experimentalfeatures=1
nuparams=76b809bb:1
lightwalletd=1
i-am-aware-zcashd-will-be-replaced-by-zebrad-and-zallet-in-2025=1
''';
    final f = File('$dir/zcash.conf');
    await f.writeAsString(src);
    await Process.run('chmod', ['644', f.path]);
  }

  static Future<void> _awaitReady(
    _ZcashdRawRpc rpc,
    bool Function() hasExited,
    int? Function() exitCode,
  ) async {
    final deadline = DateTime.now().add(_kReadinessTimeout);
    Object? lastError;
    while (DateTime.now().isBefore(deadline)) {
      if (hasExited()) {
        throw StateError(
          'zcashd exited before readiness, exitCode=${exitCode()}',
        );
      }
      try {
        final info = await rpc
            .call('getblockchaininfo')
            .timeout(const Duration(seconds: 3));
        final chain = (info as Map)['chain'];
        if (chain is String && chain.toLowerCase() == 'regtest') return;
        throw ZcashdWalletException(
          'getblockchaininfo returned unexpected chain: $chain',
          method: 'getblockchaininfo',
        );
      } on Object catch (error) {
        lastError = error;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    throw TimeoutException(
      'zcashd not ready after ${_kReadinessTimeout.inSeconds}s; '
      'lastError=$lastError',
    );
  }

  static Future<String> _readDaemonVersion(_ZcashdRawRpc rpc) async {
    try {
      final info = await rpc.call('getnetworkinfo');
      final map = Map<String, dynamic>.from(info as Map);
      final subversion = map['subversion'];
      if (subversion is String && subversion.isNotEmpty) return subversion;
      final version = map['version'];
      if (version != null) return version.toString();
    } catch (_) {}
    try {
      final info = await rpc.call('getblockchaininfo');
      final map = Map<String, dynamic>.from(info as Map);
      return 'blocks=${map['blocks']},chain=${map['chain']}';
    } catch (_) {}
    return 'unknown';
  }

  static Future<int> _freePort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    return port;
  }

  static String _randomToken(int bytes) {
    final random = Random.secure();
    final values = List<int>.generate(bytes, (_) => random.nextInt(256));
    return base64Url.encode(values).replaceAll('=', '');
  }
}

class _ZcashdRawRpc {
  final Uri _endpoint;
  final http.Client _http;
  final String _authHeader;
  int _id = 0;

  _ZcashdRawRpc({
    required int port,
    required String username,
    required String password,
    http.Client? client,
  }) : _endpoint = Uri.http('localhost:$port', '/'),
       _authHeader =
           'Basic ${base64Encode(utf8.encode('$username:$password'))}',
       _http = client ?? http.Client();

  void close() => _http.close();

  Future<dynamic> call(String method, [List<dynamic>? params]) async {
    final body = jsonEncode({
      'jsonrpc': '2.0',
      'method': method,
      'params': params ?? [],
      'id': ++_id,
    });

    late http.Response response;
    try {
      response = await _http
          .post(
            _endpoint,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': _authHeader,
            },
            body: body,
          )
          .timeout(_kRpcTimeout);
    } on TimeoutException catch (error) {
      throw ZcashdWalletException(
        'RPC method timed out after $_kRpcTimeout',
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
      final err = Map<String, dynamic>.from(decoded['error'] as Map);
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
}

class _BoundedLog {
  final StringBuffer _buffer = StringBuffer();

  void add(String chunk) {
    _buffer.write(_redact(chunk));
    final current = _buffer.toString();
    if (current.length <= _kLogLimit) return;
    _buffer
      ..clear()
      ..write(current.substring(current.length - _kLogLimit));
  }

  String get tail => _buffer.toString().trim();

  static String _redact(String input) {
    return input
        .replaceAll(RegExp(r'rpcpassword=[^\s]+'), 'rpcpassword=<redacted>')
        .replaceAll(RegExp(r'rpcuser=[^\s]+'), 'rpcuser=<redacted>')
        .replaceAll(
          RegExp(r'Authorization:\s*Basic\s+[^\s]+', caseSensitive: false),
          'Authorization: Basic <redacted>',
        )
        .replaceAll(RegExp(r'([A-Za-z0-9_-]{20,})'), '<redacted-token>');
  }
}

Future<bool> _waitForExit(Process process, Duration timeout) async {
  try {
    await process.exitCode.timeout(timeout);
    return true;
  } on TimeoutException {
    return false;
  }
}

Future<void> _cleanupTempDir(
  Directory tmpDir,
  bool usesDocker,
  String dockerImage,
) async {
  try {
    await Process.run('chmod', ['-R', 'u+rwX', tmpDir.path]);
  } catch (_) {}
  try {
    await tmpDir.delete(recursive: true);
    return;
  } catch (_) {}

  if (usesDocker) {
    try {
      await Process.run('docker', [
        'run',
        '--rm',
        '-v',
        '${tmpDir.path}:/workspace',
        '--entrypoint',
        '/bin/sh',
        dockerImage,
        '-c',
        'chmod -R a+rwX /workspace',
      ]).timeout(const Duration(seconds: 20));
    } catch (_) {}
    try {
      await tmpDir.delete(recursive: true);
    } catch (_) {}
  }
}
