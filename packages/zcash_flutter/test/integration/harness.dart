library;

import 'dart:async';
import 'dart:collection';
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

typedef ZebraProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> arguments,
      Map<String, String> environment,
    );

enum ZebraUpgrade {
  overwinter('Overwinter'),
  sapling('Sapling'),
  blossom('Blossom'),
  heartwood('Heartwood'),
  canopy('Canopy'),
  nu5('NU5'),
  nu6('NU6'),
  nu61('NU6.1'),
  nu62('NU6.2'),
  nu63('NU6.3'),
  nu7('NU7');

  const ZebraUpgrade(this.configName);

  final String configName;
}

/// One immutable consensus schedule shared by the node and native builders.
final class ZebraConsensusSchedule {
  ZebraConsensusSchedule._(this._nu63ActivationHeight);

  static final standard = ZebraConsensusSchedule._(null);

  factory ZebraConsensusSchedule.stagedNu63({required int activationHeight}) {
    if (activationHeight < 2) {
      throw ArgumentError.value(
        activationHeight,
        'activationHeight',
        'a staged chain activates NU6.3 above genesis; at height 1 the chain '
            'has always been activated and no Orchard note can exist on it',
      );
    }
    return ZebraConsensusSchedule._(activationHeight);
  }

  final int? _nu63ActivationHeight;

  late final Map<ZebraUpgrade, int> activationHeights = UnmodifiableMapView({
    ZebraUpgrade.overwinter: 1,
    ZebraUpgrade.sapling: 1,
    ZebraUpgrade.blossom: 1,
    ZebraUpgrade.heartwood: 1,
    ZebraUpgrade.canopy: 1,
    ZebraUpgrade.nu5: 1,
    ZebraUpgrade.nu6: 1,
    if (_nu63ActivationHeight != null) ...{
      ZebraUpgrade.nu61: 1,
      ZebraUpgrade.nu62: 1,
      ZebraUpgrade.nu63: _nu63ActivationHeight,
    },
  });

  int? activationHeight(ZebraUpgrade upgrade) => activationHeights[upgrade];

  /// Pass this exact value to native regtest builders for this node.
  int? get nativeRegtestNu63ActivationHeight => _nu63ActivationHeight;

  bool get stagesNu63 => _nu63ActivationHeight != null;

  void validateReportedActivationHeights(Map<String, int> reported) {
    for (final entry in activationHeights.entries) {
      final name = entry.key.configName;
      final actual = reported[name];
      if (actual != entry.value) {
        throw StateError(
          'zebrad reported $name activation height $actual, but the node and '
          'native regtest schedule requires ${entry.value}',
        );
      }
    }
  }

  String toZebraToml() => activationHeights.entries
      .map((entry) => '${_tomlName(entry.key)} = ${entry.value}')
      .join('\n');

  static String _tomlName(ZebraUpgrade upgrade) =>
      upgrade.configName.contains('.')
      ? '"${upgrade.configName}"'
      : upgrade.configName;
}

final class ZebraStartupException implements Exception {
  ZebraStartupException._({
    required this.schedule,
    required this.stderr,
    required this.unsupportedUpgrade,
    required List<String> supportedUpgradeNames,
  }) : supportedUpgradeNames = List.unmodifiable(supportedUpgradeNames);

  factory ZebraStartupException.fromStderr({
    required ZebraConsensusSchedule schedule,
    required String stderr,
  }) {
    final unsupportedMatch = RegExp(
      r'''unknown (?:variant|field)\s+[`'\"]([^`'\"]+)[`'\"],?\s+expected one of\s+([^\r\n]+)''',
      caseSensitive: false,
    ).firstMatch(stderr);
    final supported = <String>[];
    if (unsupportedMatch != null) {
      final inventory = unsupportedMatch
          .group(2)!
          .split(RegExp(r'\s+for key\s+', caseSensitive: false))
          .first;
      supported.addAll(
        RegExp(
          r'''[`'\"]([^`'\"]+)[`'\"]''',
        ).allMatches(inventory).map((match) => match.group(1)!),
      );
    }
    return ZebraStartupException._(
      schedule: schedule,
      stderr: stderr.trim(),
      unsupportedUpgrade: unsupportedMatch?.group(1),
      supportedUpgradeNames: supported,
    );
  }

  final ZebraConsensusSchedule schedule;
  final String stderr;
  final String? unsupportedUpgrade;
  final List<String> supportedUpgradeNames;

  @override
  String toString() {
    final unsupported = unsupportedUpgrade;
    if (unsupported == null) {
      return 'ZebraStartupException: zebrad exited before becoming ready. '
          '$stderr';
    }
    final requested = schedule.activationHeights.keys
        .map((upgrade) => upgrade.configName)
        .join(', ');
    return 'ZebraStartupException: zebrad rejected requested upgrade '
        '$unsupported. Requested schedule: $requested. Supported upgrades '
        'reported by this binary: ${supportedUpgradeNames.join(', ')}. '
        'NU6.3 and NU7 are distinct consensus upgrades; the harness will not '
        'substitute one for the other, and node/native parameters must match.';
  }
}

class ZebraHarness {
  final Process _process;
  final ZebraClient client;
  final String zebraVersion;
  final Directory _tmpDir;
  Future<void>? _shutdownFuture;

  final int rpcPort;

  final int p2pPort;

  ZebraHarness._({
    required Process process,
    required this.client,
    required this.zebraVersion,
    required Directory tmpDir,
    required this.rpcPort,
    required this.p2pPort,
    required this.schedule,
  }) : _process = process,
       _tmpDir = tmpDir;

  final ZebraConsensusSchedule schedule;

  /// ZIP 258: no value may enter Orchard once NU6.3 is active.
  int? get nu63ActivationHeight => schedule.nativeRegtestNu63ActivationHeight;

  bool get isStagedNu63Chain => nu63ActivationHeight != null;

  static Future<ZebraHarness> start({
    String? peerAddress,
    ZebraConsensusSchedule? schedule,
    String minerAddress = kRegtestMinerAddress,
    String? zebraBinary,
    ZebraProcessStarter? processStarter,
  }) async {
    final consensus = schedule ?? ZebraConsensusSchedule.standard;
    final bin = zebraBinary ?? Platform.environment['ZEBRA_BIN'];
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
    Process? process;
    ZebraClient? ownedClient;
    try {
      await Process.run('chmod', ['755', tmpDir.path]);
      await _writeConfig(
        tmpDir.path,
        rpcPort,
        p2pPort,
        peerAddress,
        consensus,
        minerAddress,
      );

      final executable = usesDocker ? 'docker' : bin;
      final arguments = usesDocker
          ? [
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
            ]
          : ['--config', '${tmpDir.path}/zebrad.toml', 'start'];
      final childEnv = _childEnvironment();
      final startProcess = processStarter ?? _startProcess;
      process = await startProcess(executable, arguments, childEnv);

      process.stdout.listen((_) {});
      final stderrTail = <String>[];
      process.stderr.listen((chunk) {
        stderrTail.add(String.fromCharCodes(chunk));
        if (stderrTail.length > 40) stderrTail.removeAt(0);
      });

      final zebraClient = ZebraClient(port: rpcPort);
      ownedClient = zebraClient;
      await _awaitReady(
        zebraClient,
        process,
        () => stderrTail.join(),
        consensus,
      );

      final info = await zebraClient.getInfo();
      final ver = _extractVersion(info.build);
      final chain = await zebraClient.getBlockchainInfo();
      consensus.validateReportedActivationHeights({
        for (final upgrade in chain.upgrades.values)
          upgrade.name: upgrade.activationHeight,
      });

      return ZebraHarness._(
        process: process,
        client: zebraClient,
        zebraVersion: ver,
        tmpDir: tmpDir,
        rpcPort: rpcPort,
        p2pPort: p2pPort,
        schedule: consensus,
      );
    } catch (_) {
      await _cleanup(process: process, client: ownedClient, tmpDir: tmpDir);
      rethrow;
    }
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

  Future<void> shutdown() => _shutdownFuture ??= _cleanup(
    process: _process,
    client: client,
    tmpDir: _tmpDir,
  );

  static Future<Process> _startProcess(
    String executable,
    List<String> arguments,
    Map<String, String> environment,
  ) => Process.start(
    executable,
    arguments,
    environment: environment,
    includeParentEnvironment: false,
  );

  static Future<void> _cleanup({
    required Process? process,
    required ZebraClient? client,
    required Directory tmpDir,
  }) async {
    if (process != null) {
      process.kill(ProcessSignal.sigterm);
      await process.exitCode.timeout(
        const Duration(seconds: 12),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    }
    client?.close();
    try {
      if (await tmpDir.exists()) {
        await tmpDir.delete(recursive: true);
      }
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
    ZebraConsensusSchedule schedule,
    String minerAddress,
  ) async {
    final initialPeers = peerAddress == null ? '' : '"$peerAddress"';
    final targetSize = peerAddress == null ? 0 : 1;
    // Dotted upgrade names must be quoted; bare NU6.3 is a TOML dotted key.
    final activationHeights = schedule.toZebraToml();
    final src =
        '''
[network]
network = "Regtest"
listen_addr = "127.0.0.1:$p2pPort"
peerset_initial_target_size = $targetSize
initial_mainnet_peers = []
initial_testnet_peers = [$initialPeers]

[network.testnet_parameters.activation_heights]
$activationHeights
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
    ZebraConsensusSchedule schedule,
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
          throw ZebraStartupException.fromStderr(
            schedule: schedule,
            stderr: stderrTail(),
          );
        }
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
