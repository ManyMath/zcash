library;

import 'dart:async';
import 'dart:io';
import 'package:zcash/zcash.dart';

const _kDefaultDockerImage = 'zfnd/zebra:latest';
const _kReadinessTimeout = 60;

// m/44'/1'/0'/0/0 of the test seed, hardcoded so startup needs no FFI.
const _kRegtestMinerAddress = 'tmNuoMzZxTiBkEbHVNwUsr3a1iELSeNZkRA';

class ZebraHarness {
  final Process _process;
  final ZebraClient client;
  final String zebraVersion;
  final Directory _tmpDir;

  ZebraHarness._({
    required Process process,
    required this.client,
    required this.zebraVersion,
    required Directory tmpDir,
  })  : _process = process,
        _tmpDir = tmpDir;

  static Future<ZebraHarness> start() async {
    final port = await _freePort();
    final tmpDir = await Directory.systemTemp.createTemp('zebra-regtest-');
    await Process.run('chmod', ['755', tmpDir.path]);
    await _writeConfig(tmpDir.path, port);

    final bin = Platform.environment['ZEBRA_BIN'];
    final image =
        Platform.environment['ZEBRA_DOCKER_IMAGE'] ?? _kDefaultDockerImage;

    late Process process;
    if (bin != null) {
      process = await Process.start(
        bin,
        ['--config', '${tmpDir.path}/zebrad.toml', 'start'],
      );
    } else {
      process = await Process.start('docker', [
        'run', '--rm', '--network=host',
        '-v', '${tmpDir.path}:/cfg',
        image,
        'zebrad', '--config', '/cfg/zebrad.toml', 'start',
      ]);
    }

    process.stdout.listen((_) {});
    process.stderr.listen((_) {});

    final zebraClient = ZebraClient(port: port);
    await _awaitReady(zebraClient);

    final info = await zebraClient.getInfo();
    final ver = _extractVersion(info.build);

    return ZebraHarness._(
      process: process,
      client: zebraClient,
      zebraVersion: ver,
      tmpDir: tmpDir,
    );
  }

  bool meetsMinVersion(String min) => _cmpVersion(zebraVersion, min) >= 0;

  Future<void> shutdown() async {
    _process.kill(ProcessSignal.sigterm);
    await _process.exitCode.timeout(
      const Duration(seconds: 12),
      onTimeout: () {
        _process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    client.close();
    await _tmpDir.delete(recursive: true).catchError((_) {});
  }

  static Future<int> _freePort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    return port;
  }

  static Future<void> _writeConfig(String dir, int port) async {
    final src = '''
[network]
network = "Regtest"
listen_addr = "127.0.0.1:0"
peerset_initial_target_size = 0
initial_mainnet_peers = []
initial_testnet_peers = []

[network.testnet_parameters.activation_heights]
Overwinter = 1
Sapling = 1
Blossom = 1
Heartwood = 1
Canopy = 1
NU5 = 1
NU6 = 1

[rpc]
listen_addr = "127.0.0.1:$port"
enable_cookie_auth = false

[state]
ephemeral = true

[mining]
miner_address = "$_kRegtestMinerAddress"
''';
    final f = File('$dir/zebrad.toml');
    await f.writeAsString(src);
    await Process.run('chmod', ['644', f.path]);
  }

  static Future<void> _awaitReady(ZebraClient client) async {
    final deadline =
        DateTime.now().add(const Duration(seconds: _kReadinessTimeout));
    while (DateTime.now().isBefore(deadline)) {
      try {
        await client.getInfo().timeout(const Duration(seconds: 3));
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    throw TimeoutException('zebrad not ready after ${_kReadinessTimeout}s');
  }

  static String _extractVersion(String build) {
    final m = RegExp(r'(\d+\.\d+\.\d+)').firstMatch(build);
    return m?.group(1) ?? '0.0.0';
  }

  static int _cmpVersion(String a, String b) {
    int p(String v, int i) {
      final pts = v.split('.');
      return i < pts.length ? int.tryParse(pts[i]) ?? 0 : 0;
    }
    for (var i = 0; i < 3; i++) {
      final d = p(a, i) - p(b, i);
      if (d != 0) return d;
    }
    return 0;
  }
}

Future<String> findOrInstallZebrad(String version) async {
  final home = Platform.environment['HOME'] ?? '/root';
  final targetPath = '$home/.cache/zebrad-bins/v$version/zebrad';
  if (await File(targetPath).exists()) return targetPath;
  final root = '$home/.cache/zebrad-bins/v$version';
  await Directory(root).create(recursive: true);
  final r = await Process.run(
    'cargo',
    ['install', 'zebrad', '--version', version, '--locked', '--root', root],
  );
  if (r.exitCode != 0) {
    throw Exception('cargo install zebrad@$version failed:\n${r.stderr}');
  }
  await File('$root/bin/zebrad').copy(targetPath);
  return targetPath;
}
