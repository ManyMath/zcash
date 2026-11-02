library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:zcash_flutter/zcash_flutter.dart';

import 'docker_image_policy.dart';

const _kReadinessTimeout = 60;

/// m/44'/1'/0'/0/0 of the test seed.
const kRegtestMinerAddress = 'tmNuoMzZxTiBkEbHVNwUsr3a1iELSeNZkRA';

const kIronwoodProofMinerAddress = 'tmYjAZFpvdDXTaJrq2WikAntitBNJJo9VSo';

/// ZIP 229 adds no Ironwood address encoding, so it serves both pools.
const kIronwoodProofUnifiedAddress =
    'uregtest1t5ljufrslrjkts4ku72pj7cer8qtck0yzv58jna7pg7ygjm2taexqnvcl8eg28ac6'
    'verjfdnsx3p028x2pykav0q2vvp0hu3nk3z72vh2adxjgvp34y47zc2efx98pqvqsp9k30j7cq'
    '9vwx09g9ukzfqxzzcm6sm5qt7l0md4t66uj4fxntqk7mlgy4az57rkk6xwu0ag53g5j2h9rz';

const kIronwoodProofMinerSecretKeyHex =
    '1111111111111111111111111111111111111111111111111111111111111111';

class ZebraHarness {
  final Process _process;
  final ZebraClient client;
  final String zebraVersion;
  final Directory _tmpDir;

  final int rpcPort;

  final int p2pPort;

  ZebraHarness._({
    required Process process,
    required this.client,
    required this.zebraVersion,
    required Directory tmpDir,
    required this.rpcPort,
    required this.p2pPort,
    required this.nu63ActivationHeight,
  }) : _process = process,
       _tmpDir = tmpDir;

  /// ZIP 258: no value may enter Orchard once NU6.3 is active.
  final int? nu63ActivationHeight;

  bool get isStagedNu63Chain => nu63ActivationHeight != null;

  static Future<ZebraHarness> start({
    String? peerAddress,
    int? nu63ActivationHeight,
    String minerAddress = kRegtestMinerAddress,
  }) async {
    final bin = Platform.environment['ZEBRA_BIN'];
    final usesDocker = bin == null || bin.isEmpty;
    final image = usesDocker
        ? requireDigestPinnedDockerImage(
            image: Platform.environment['ZEBRA_DOCKER_IMAGE'],
            imageEnvName: 'ZEBRA_DOCKER_IMAGE',
            binaryEnvName: 'ZEBRA_BIN',
            serviceName: 'Zebra',
          )
        : null;

    final rpcPort = await _freePort();
    final p2pPort = await _freePort();
    final tmpDir = await Directory.systemTemp.createTemp('zebra-regtest-');
    await Process.run('chmod', ['755', tmpDir.path]);
    if (nu63ActivationHeight != null && nu63ActivationHeight < 2) {
      throw ArgumentError.value(
        nu63ActivationHeight,
        'nu63ActivationHeight',
        'a staged chain activates NU6.3 above genesis; at height 1 the chain '
            'has always been activated and no Orchard note can exist on it',
      );
    }
    await _writeConfig(
      tmpDir.path,
      rpcPort,
      p2pPort,
      peerAddress,
      nu63ActivationHeight,
      minerAddress,
    );

    late Process process;
    final childEnv = _childEnvironment();
    if (!usesDocker) {
      process = await Process.start(
        bin,
        ['--config', '${tmpDir.path}/zebrad.toml', 'start'],
        environment: childEnv,
        includeParentEnvironment: false,
      );
    } else {
      process = await Process.start(
        'docker',
        [
          'run',
          '--rm',
          '--network=host',
          '-v',
          '${tmpDir.path}:/cfg',
          image!,
          'zebrad',
          '--config',
          '/cfg/zebrad.toml',
          'start',
        ],
        environment: childEnv,
        includeParentEnvironment: false,
      );
    }

    process.stdout.listen((_) {});
    final stderrTail = <String>[];
    process.stderr.listen((chunk) {
      stderrTail.add(String.fromCharCodes(chunk));
      if (stderrTail.length > 40) stderrTail.removeAt(0);
    });

    final zebraClient = ZebraClient(port: rpcPort);
    await _awaitReady(
      zebraClient,
      process,
      () => stderrTail.join(),
      nu63ActivationHeight,
    );

    final info = await zebraClient.getInfo();
    final ver = _extractVersion(info.build);

    return ZebraHarness._(
      process: process,
      client: zebraClient,
      zebraVersion: ver,
      tmpDir: tmpDir,
      rpcPort: rpcPort,
      p2pPort: p2pPort,
      nu63ActivationHeight: nu63ActivationHeight,
    );
  }

  bool meetsMinVersion(String min) => _cmpVersion(zebraVersion, min) >= 0;

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
      prevBlockHash: BlockAssembler.reverseHash(_hex(tpl.previousBlockHash)),
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

  // zebrad reads ZEBRA_* variables as config and rejects unknown fields.
  static Map<String, String> _childEnvironment() {
    return {
      for (final entry in Platform.environment.entries)
        if (!entry.key.startsWith('ZEBRA_')) entry.key: entry.value,
    };
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
    int? nu63ActivationHeight,
    String minerAddress,
  ) async {
    final initialPeers = peerAddress == null ? '' : '"$peerAddress"';
    final targetSize = peerAddress == null ? 0 : 1;
    // Dotted upgrade names must be quoted; bare NU6.3 is a TOML dotted key.
    final stagedUpgrades = nu63ActivationHeight == null
        ? ''
        : '"NU6.1" = 1\n"NU6.2" = 1\n"NU6.3" = $nu63ActivationHeight\n';
    final src =
        '''
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
$stagedUpgrades
[rpc]
listen_addr = "127.0.0.1:$rpcPort"
enable_cookie_auth = false

[state]
ephemeral = true

[mining]
miner_address = "$minerAddress"
''';
    final f = File('$dir/zebrad.toml');
    await f.writeAsString(src);
    await Process.run('chmod', ['644', f.path]);
  }

  static Future<void> _awaitReady(
    ZebraClient client,
    Process process,
    String Function() stderrTail,
    int? nu63ActivationHeight,
  ) async {
    var exited = false;
    unawaited(process.exitCode.then((_) => exited = true));
    final deadline = DateTime.now().add(
      const Duration(seconds: _kReadinessTimeout),
    );
    while (DateTime.now().isBefore(deadline)) {
      try {
        await client.getInfo().timeout(const Duration(seconds: 3));
        return;
      } catch (_) {
        if (exited) {
          throw StateError(_startupFailure(stderrTail(), nu63ActivationHeight));
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    throw TimeoutException('zebrad not ready after ${_kReadinessTimeout}s');
  }

  static String _startupFailure(String stderr, int? nu63ActivationHeight) {
    final staged = nu63ActivationHeight != null;
    final hint = staged
        ? '\nThis config stages NU6.3 at height $nu63ActivationHeight. A '
              'pre-Ironwood zebrad rejects an activation-heights table naming '
              'NU6.3; set ZEBRA_BIN to an Ironwood-aware build.'
        : '';
    return 'zebrad exited before becoming ready.$hint\n${stderr.trim()}';
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
  final r = await Process.run('cargo', [
    'install',
    'zebrad',
    '--version',
    version,
    '--locked',
    '--root',
    root,
  ]);
  if (r.exitCode != 0) {
    throw Exception('cargo install zebrad@$version failed:\n${r.stderr}');
  }
  await File('$root/bin/zebrad').copy(targetPath);
  return targetPath;
}
