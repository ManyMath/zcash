library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:zcash_ffi/zcash_ffi.dart';

const _kDefaultDockerImage = 'zfnd/zebra:latest';
const _kReadinessTimeout = 60;

/// Receives every regtest coinbase. m/44'/1'/0'/0/0 of the test seed,
/// hardcoded so startup needs no FFI.
const kRegtestMinerAddress = 'tmNuoMzZxTiBkEbHVNwUsr3a1iELSeNZkRA';

class ZebraHarness {
  final Process _process;
  final ZebraClient client;
  final String zebraVersion;
  final Directory _tmpDir;

  final int p2pPort;

  ZebraHarness._({
    required Process process,
    required this.client,
    required this.zebraVersion,
    required Directory tmpDir,
    required this.p2pPort,
  })  : _process = process,
        _tmpDir = tmpDir;

  static Future<ZebraHarness> start({String? peerAddress}) async {
    final rpcPort = await _freePort();
    final p2pPort = await _freePort();
    final tmpDir = await Directory.systemTemp.createTemp('zebra-regtest-');
    await Process.run('chmod', ['755', tmpDir.path]);
    await _writeConfig(tmpDir.path, rpcPort, p2pPort, peerAddress);

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

    final zebraClient = ZebraClient(port: rpcPort);
    await _awaitReady(zebraClient);

    final info = await zebraClient.getInfo();
    final ver = _extractVersion(info.build);

    return ZebraHarness._(
      process: process,
      client: zebraClient,
      zebraVersion: ver,
      tmpDir: tmpDir,
      p2pPort: p2pPort,
    );
  }

  bool meetsMinVersion(String min) => _cmpVersion(zebraVersion, min) >= 0;

  /// Zebra 4 returns null from submitblock before the chain advances.
  Future<List<String>> mineBlocks(int count) async {
    final hashes = <String>[];
    for (var i = 0; i < count; i++) {
      hashes.add(await _mineOne());
    }
    return hashes;
  }

  Future<String> _mineOne() async {
    final tpl = await client.getBlockTemplate();
    final coinbase = tpl.coinbaseTxn;
    if (coinbase == null) {
      throw StateError('block template missing coinbasetxn');
    }
    final coinbaseHex = coinbase['data'] as String;
    final coinbaseHash = coinbase['hash'] as String;

    final commitments = tpl.blockCommitmentsHash;
    if (commitments == null) {
      throw StateError('block template missing blockcommitmentshash');
    }

    final time = tpl.curTime ?? tpl.minTime;
    final bitsInt = int.parse(tpl.bits, radix: 16);

    // Zebra's default root only covers an empty template.
    Uint8List merkleRoot;
    if (tpl.transactions.isEmpty && tpl.defaultMerkleRoot != null) {
      merkleRoot = BlockAssembler.reverseHash(_hex(tpl.defaultMerkleRoot!));
    } else {
      final ids = <String>[
        coinbaseHash,
        for (final t in tpl.transactions) t['hash'] as String,
      ];
      merkleRoot = BlockAssembler.computeMerkleRoot(ids);
    }

    final prefix = BlockAssembler.buildHeaderPrefix(
      version: tpl.version,
      prevBlockHash:
          BlockAssembler.reverseHash(_hex(tpl.previousBlockHash)),
      merkleRoot: merkleRoot,
      blockCommitments: BlockAssembler.reverseHash(_hex(commitments)),
      time: time,
      bits: bitsInt,
    );

    final solved = solveEquihash(prefix);
    final header = BlockAssembler.buildHeader(
      headerPrefix: prefix,
      nonce: solved.nonce,
      solution: solved.solution,
    );

    final otherTxs = <String>[
      for (final t in tpl.transactions) t['data'] as String,
    ];
    final blockHex = BlockAssembler.assembleBlockHex(
      header: header,
      coinbaseHex: coinbaseHex,
      otherTxHex: otherTxs,
    );

    final rejection = await client.submitBlock(blockHex);
    if (rejection != null && rejection.isNotEmpty) {
      throw StateError('submitblock rejected: $rejection');
    }
    return _hashEncodeReversed(_sha256dStub(header));
  }

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
    try {
      await _tmpDir.delete(recursive: true);
    } catch (_) {}
  }

  static Future<int> _freePort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    return port;
  }

  static Future<void> _writeConfig(
    String dir,
    int rpcPort,
    int p2pPort,
    String? peerAddress,
  ) async {
    final initialPeers = peerAddress == null ? '' : '"$peerAddress"';
    final targetSize = peerAddress == null ? 0 : 1;
    final src = '''
[network]
network = "Regtest"
listen_addr = "127.0.0.1:$p2pPort"
peerset_initial_target_size = $targetSize
initial_mainnet_peers = []
initial_testnet_peers = [$initialPeers]

[network.testnet_parameters.activation_heights]
Overwinter = 1
Sapling = 1
Blossom = 1
Heartwood = 1
Canopy = 1
NU5 = 1
NU6 = 1

[rpc]
listen_addr = "127.0.0.1:$rpcPort"
enable_cookie_auth = false

[state]
ephemeral = true

[mining]
miner_address = "$kRegtestMinerAddress"
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

Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _hashEncodeReversed(Uint8List internalHash) {
  final reversed = BlockAssembler.reverseHash(internalHash);
  final sb = StringBuffer();
  for (final b in reversed) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

Uint8List _sha256dStub(Uint8List data) {
  final once = sha256.convert(data).bytes;
  final twice = sha256.convert(once).bytes;
  return Uint8List.fromList(twice);
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
