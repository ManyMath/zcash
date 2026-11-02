library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:zcash_flutter/zcash_flutter.dart';

import 'docker_image_policy.dart';

const _kReadinessTimeout = Duration(seconds: 120);
const _kPollInterval = Duration(milliseconds: 500);
const _kLogLimit = 8192;

String lightwalletdLaunchPrerequisiteMessage() =>
    'failed to start lightwalletd; set LIGHTWALLETD_BIN to a local binary '
    'or LIGHTWALLETD_DOCKER_IMAGE to a digest-pinned Docker image';

class LightwalletdBackend {
  final String type;
  final String host;
  final int rpcPort;
  final String rpcUser;
  final String rpcPassword;

  const LightwalletdBackend._({
    required this.type,
    required this.host,
    required this.rpcPort,
    required this.rpcUser,
    required this.rpcPassword,
  });

  factory LightwalletdBackend.zebra({
    required int rpcPort,
    String host = '127.0.0.1',
  }) {
    return LightwalletdBackend._(
      type: 'zebra',
      host: host,
      rpcPort: rpcPort,
      rpcUser: 'zebra_${_randomToken(6)}',
      rpcPassword: _randomToken(18),
    );
  }

  factory LightwalletdBackend.zcashd({
    required int rpcPort,
    required String rpcUser,
    required String rpcPassword,
    String host = '127.0.0.1',
  }) {
    return LightwalletdBackend._(
      type: 'zcashd',
      host: host,
      rpcPort: rpcPort,
      rpcUser: rpcUser,
      rpcPassword: rpcPassword,
    );
  }
}

class LightwalletdHarnessException implements Exception {
  final String message;
  final String phase;
  final String launch;
  final String backendType;
  final int backendRpcPort;
  final int grpcPort;
  final int? httpPort;
  final Object? cause;
  final int? backendHeight;
  final int? lightwalletdHeight;
  final String? compactBlockRange;
  final List<int> streamedCompactBlockHeights;
  final String stdoutTail;
  final String stderrTail;

  const LightwalletdHarnessException(
    this.message, {
    required this.phase,
    required this.launch,
    required this.backendType,
    required this.backendRpcPort,
    required this.grpcPort,
    this.httpPort,
    this.cause,
    this.backendHeight,
    this.lightwalletdHeight,
    this.compactBlockRange,
    this.streamedCompactBlockHeights = const [],
    this.stdoutTail = '',
    this.stderrTail = '',
  });

  @override
  String toString() {
    final parts = <String>[
      'LightwalletdHarnessException: $message',
      'phase=$phase',
      'launch=$launch',
      'backendType=$backendType',
      'backendRpcPort=$backendRpcPort',
      'grpcPort=$grpcPort',
    ];
    if (httpPort != null) parts.add('httpPort=$httpPort');
    if (backendHeight != null) parts.add('backendHeight=$backendHeight');
    if (lightwalletdHeight != null) {
      parts.add('lightwalletdHeight=$lightwalletdHeight');
    }
    if (compactBlockRange != null) {
      parts.add('compactBlockRange=$compactBlockRange');
    }
    if (streamedCompactBlockHeights.isNotEmpty) {
      parts.add('streamedCompactBlockHeights=$streamedCompactBlockHeights');
    }
    if (cause != null) parts.add('cause=$cause');
    if (stdoutTail.isNotEmpty) parts.add('stdoutTail=$stdoutTail');
    if (stderrTail.isNotEmpty) parts.add('stderrTail=$stderrTail');
    return LightwalletdHarness.redactForDiagnostics(parts.join('\n'));
  }
}

class LightwalletdSyncSnapshot {
  final int requestedHeight;
  final int backendHeight;
  final int lightwalletdHeight;

  const LightwalletdSyncSnapshot({
    required this.requestedHeight,
    required this.backendHeight,
    required this.lightwalletdHeight,
  });
}

class LightwalletdHarness {
  final Process _process;
  final Directory _tmpDir;
  final _BoundedLog _stdout;
  final _BoundedLog _stderr;
  final LightwalletdBackend backend;
  bool _shutdown = false;
  String _phase = 'runtime';
  int? _lastBackendHeight;
  int? _lastLightwalletdHeight;
  String? _lastCompactBlockRange;
  final List<int> _streamedCompactBlockHeights = <int>[];

  final LightwalletdClient client;
  final int grpcPort;
  final int httpPort;
  final String launch;

  LightwalletdHarness._({
    required Process process,
    required Directory tmpDir,
    required _BoundedLog stdout,
    required _BoundedLog stderr,
    required this.backend,
    required this.client,
    required this.grpcPort,
    required this.httpPort,
    required this.launch,
  }) : _process = process,
       _tmpDir = tmpDir,
       _stdout = stdout,
       _stderr = stderr;

  static Future<LightwalletdHarness> start({
    required LightwalletdBackend backend,
    Duration readinessTimeout = _kReadinessTimeout,
  }) async {
    var phase = 'validate-launch';
    final bin = Platform.environment['LIGHTWALLETD_BIN'];
    final usesDocker = bin == null || bin.isEmpty;
    final dockerImage = usesDocker
        ? requireDigestPinnedDockerImage(
            image: Platform.environment['LIGHTWALLETD_DOCKER_IMAGE'],
            imageEnvName: 'LIGHTWALLETD_DOCKER_IMAGE',
            binaryEnvName: 'LIGHTWALLETD_BIN',
            serviceName: 'lightwalletd',
          )
        : '';
    final launch = usesDocker ? 'docker image $dockerImage' : 'bin $bin';

    phase = 'allocate-ports';
    final grpcPort = await _freePort();
    final httpPort = await _freePort();
    phase = 'create-tempdir';
    final tmpDir = await Directory.systemTemp.createTemp('lightwalletd-');
    final dataDir = Directory('${tmpDir.path}/db');
    await dataDir.create(recursive: true);
    await Process.run('chmod', ['777', tmpDir.path]);
    await Process.run('chmod', ['777', dataDir.path]);

    phase = 'write-config';
    final confPath = '${tmpDir.path}/zcash.conf';
    await _writeZcashConf(confPath, backend);

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
          '${tmpDir.path}:/cfg',
          dockerImage,
          ..._lightwalletdArgs(
            confPath: '/cfg/zcash.conf',
            dataDir: '/cfg/db',
            grpcPort: grpcPort,
            httpPort: httpPort,
          ),
        ]);
      } else {
        process = await Process.start(
          bin,
          _lightwalletdArgs(
            confPath: confPath,
            dataDir: dataDir.path,
            grpcPort: grpcPort,
            httpPort: httpPort,
          ),
        );
      }
    } on Object catch (error) {
      await _cleanupTempDir(tmpDir, usesDocker, dockerImage);
      throw LightwalletdHarnessException(
        lightwalletdLaunchPrerequisiteMessage(),
        phase: phase,
        launch: launch,
        backendType: backend.type,
        backendRpcPort: backend.rpcPort,
        grpcPort: grpcPort,
        httpPort: httpPort,
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

    final client = LightwalletdClient(
      host: '127.0.0.1',
      port: grpcPort,
      useTls: false,
    );
    final harness = LightwalletdHarness._(
      process: process,
      tmpDir: tmpDir,
      stdout: stdoutLog,
      stderr: stderrLog,
      backend: backend,
      client: client,
      grpcPort: grpcPort,
      httpPort: httpPort,
      launch: launch,
    );

    try {
      phase = 'readiness:getinfo';
      harness._phase = phase;
      await harness._awaitReady(readinessTimeout, () => exited, () => exitCode);
      return harness;
    } on Object catch (error) {
      await harness.shutdown();
      if (error is LightwalletdHarnessException) rethrow;
      throw harness._exception(
        'lightwalletd did not become ready',
        phase: phase,
        cause: error,
      );
    }
  }

  Future<LightwalletdSyncSnapshot> waitForSyncHeight(
    int targetHeight, {
    required Future<int> Function() readBackendHeight,
    Duration timeout = const Duration(seconds: 90),
  }) async {
    _phase = 'sync:height>=$targetHeight';
    final deadline = DateTime.now().add(timeout);
    Object? lastError;
    while (DateTime.now().isBefore(deadline)) {
      try {
        final backendHeight = await readBackendHeight().timeout(
          const Duration(seconds: 3),
        );
        final latest = await client.getLatestBlock().timeout(
          const Duration(seconds: 3),
        );
        final lightwalletdHeight = latest.height.toInt();
        _lastBackendHeight = backendHeight;
        _lastLightwalletdHeight = lightwalletdHeight;
        if (backendHeight >= targetHeight &&
            lightwalletdHeight >= targetHeight) {
          return LightwalletdSyncSnapshot(
            requestedHeight: targetHeight,
            backendHeight: backendHeight,
            lightwalletdHeight: lightwalletdHeight,
          );
        }
      } on Object catch (error) {
        lastError = error;
      }
      await Future<void>.delayed(_kPollInterval);
    }
    throw _exception(
      'lightwalletd sync timed out',
      phase: _phase,
      cause: TimeoutException(
        'targetHeight=$targetHeight lastError=$lastError',
      ),
    );
  }

  Stream<CompactBlock> fetchCompactBlockRange(BlockRange range) async* {
    final rangeLabel = _rangeLabel(range);
    _phase = 'compact-block-range:$rangeLabel';
    _lastCompactBlockRange = rangeLabel;
    _streamedCompactBlockHeights.clear();
    try {
      await for (final block in client.getBlockRange(range)) {
        final height = block.height.toInt();
        _streamedCompactBlockHeights.add(height);
        yield block;
      }
    } on Object catch (error) {
      throw _exception(
        'compact block range fetch failed',
        phase: _phase,
        cause: error,
      );
    }
  }

  Future<void> shutdown() async {
    if (_shutdown) return;
    _shutdown = true;
    await client.close();
    var stopped = await _waitForExit(_process, const Duration(seconds: 5));
    if (!stopped) {
      _process.kill(ProcessSignal.sigterm);
      stopped = await _waitForExit(_process, const Duration(seconds: 10));
    }
    if (!stopped) {
      _process.kill(ProcessSignal.sigkill);
      await _waitForExit(_process, const Duration(seconds: 5));
    }
    await _cleanupTempDir(
      _tmpDir,
      launch.startsWith('docker image '),
      launch.replaceFirst('docker image ', ''),
    );
  }

  String diagnosticSummary({String phase = 'runtime'}) =>
      _exception('diagnostic snapshot', phase: phase).toString();

  LightwalletdHarnessException _exception(
    String message, {
    required String phase,
    Object? cause,
  }) {
    return LightwalletdHarnessException(
      message,
      phase: phase,
      launch: launch,
      backendType: backend.type,
      backendRpcPort: backend.rpcPort,
      grpcPort: grpcPort,
      httpPort: httpPort,
      cause: cause,
      backendHeight: _lastBackendHeight,
      lightwalletdHeight: _lastLightwalletdHeight,
      compactBlockRange: _lastCompactBlockRange,
      streamedCompactBlockHeights: List.unmodifiable(
        _streamedCompactBlockHeights,
      ),
      stdoutTail: _stdout.tail,
      stderrTail: _stderr.tail,
    );
  }

  Future<void> _awaitReady(
    Duration timeout,
    bool Function() hasExited,
    int? Function() exitCode,
  ) async {
    final deadline = DateTime.now().add(timeout);
    Object? lastError;
    while (DateTime.now().isBefore(deadline)) {
      if (hasExited()) {
        throw _exception(
          'lightwalletd exited before readiness; check LIGHTWALLETD_BIN or '
          'LIGHTWALLETD_DOCKER_IMAGE and verify the backend RPC is reachable',
          phase: _phase,
          cause: StateError('exitCode=${exitCode()}'),
        );
      }
      try {
        final info = await client.getInfo().timeout(const Duration(seconds: 3));
        _lastLightwalletdHeight = info.blockHeight.toInt();
        return;
      } on Object catch (error) {
        lastError = error;
        await Future<void>.delayed(_kPollInterval);
      }
    }
    throw _exception(
      'lightwalletd not ready after ${timeout.inSeconds}s',
      phase: _phase,
      cause: lastError,
    );
  }

  static Future<void> _writeZcashConf(
    String path,
    LightwalletdBackend backend,
  ) async {
    final src =
        '''
regtest=1
rpcconnect=${backend.host}
rpcport=${backend.rpcPort}
rpcuser=${backend.rpcUser}
rpcpassword=${backend.rpcPassword}
''';
    final file = File(path);
    await file.writeAsString(src);
    await Process.run('chmod', ['644', file.path]);
  }

  static Future<int> _freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  static String redactForDiagnostics(String input) => _BoundedLog.redact(input);
}

List<String> _lightwalletdArgs({
  required String confPath,
  required String dataDir,
  required int grpcPort,
  required int httpPort,
}) {
  return [
    '--no-tls-very-insecure',
    '--zcash-conf-path',
    confPath,
    '--data-dir',
    dataDir,
    '--log-file',
    '/dev/stdout',
    '--grpc-bind-addr',
    '127.0.0.1:$grpcPort',
    '--http-bind-addr',
    '127.0.0.1:$httpPort',
  ];
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

String _randomToken(int bytes) {
  final random = Random.secure();
  final values = List<int>.generate(bytes, (_) => random.nextInt(256));
  return base64Url.encode(values).replaceAll('=', '');
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

class _BoundedLog {
  final StringBuffer _buffer = StringBuffer();

  void add(String chunk) {
    _buffer.write(redact(chunk));
    final current = _buffer.toString();
    if (current.length <= _kLogLimit) return;
    _buffer
      ..clear()
      ..write(current.substring(current.length - _kLogLimit));
  }

  String get tail => _buffer.toString().trim();

  static String redact(String input) {
    return input
        .replaceAll(RegExp(r'rpcpassword=[^\s]+'), 'rpcpassword=<redacted>')
        .replaceAll(RegExp(r'rpcuser=[^\s]+'), 'rpcuser=<redacted>')
        .replaceAll(
          RegExp(r'--rpcpassword\s+[^\s]+'),
          '--rpcpassword <redacted>',
        )
        .replaceAll(RegExp(r'--rpcuser\s+[^\s]+'), '--rpcuser <redacted>')
        .replaceAll(
          RegExp(r'Authorization:\s*Basic\s+[^\s]+', caseSensitive: false),
          'Authorization: Basic <redacted>',
        )
        .replaceAll(RegExp(r'([A-Za-z0-9_-]{20,})'), '<redacted-token>');
  }
}
