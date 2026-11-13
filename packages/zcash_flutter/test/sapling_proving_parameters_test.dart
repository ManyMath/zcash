import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:zcash_flutter/zcash_flutter.dart';

class _MemorySource implements SaplingParameterSource {
  _MemorySource(this.bytesByName);

  final Map<String, List<int>> bytesByName;
  int opens = 0;

  @override
  Stream<List<int>> open(SaplingParameterArtifact artifact) {
    opens++;
    final bytes = bytesByName[artifact.fileName];
    if (bytes == null) {
      throw StateError('fixture missing ${artifact.fileName}');
    }
    return Stream.value(bytes);
  }
}

class _InterruptedSource implements SaplingParameterSource {
  _InterruptedSource(this.bytesByName);

  final Map<String, List<int>> bytesByName;

  @override
  Stream<List<int>> open(SaplingParameterArtifact artifact) async* {
    final bytes = bytesByName[artifact.fileName]!;
    yield bytes.sublist(0, bytes.length ~/ 2);
    throw StateError('fixture interruption');
  }
}

class _GatedSource implements SaplingParameterSource {
  _GatedSource(this.bytesByName);

  final Map<String, List<int>> bytesByName;
  final Completer<void> outputStarted = Completer<void>();
  final Completer<void> releaseOutput = Completer<void>();
  int opens = 0;

  @override
  Stream<List<int>> open(SaplingParameterArtifact artifact) async* {
    opens++;
    if (artifact.fileName == 'sapling-output.params') {
      outputStarted.complete();
      await releaseOutput.future;
    }
    yield bytesByName[artifact.fileName]!;
  }
}

class _StalledSource implements SaplingParameterSource {
  @override
  Stream<List<int>> open(SaplingParameterArtifact artifact) async* {
    await Completer<void>().future;
  }
}

class _SlowSource implements SaplingParameterSource {
  @override
  Stream<List<int>> open(SaplingParameterArtifact artifact) async* {
    for (var i = 0; i < artifact.expectedBytes; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 8));
      yield [i];
    }
  }
}

String _hash(List<int> bytes) => sha256.convert(bytes).toString();

SaplingParameterManifest _manifest() {
  final spend = utf8.encode('test spend params');
  final output = utf8.encode('test output params');
  return SaplingParameterManifest(
    version: 'test-v1',
    spend: SaplingParameterArtifact(
      fileName: 'sapling-spend.params',
      expectedBytes: spend.length,
      sha256Hex: _hash(spend),
    ),
    output: SaplingParameterArtifact(
      fileName: 'sapling-output.params',
      expectedBytes: output.length,
      sha256Hex: _hash(output),
    ),
  );
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('zcash-params-test-');
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  test('official manifest pins both upstream artifacts exactly', () {
    expect(officialSaplingParameterManifestV1.version, 'sapling-mpc-v1');
    expect(
      officialSaplingParameterManifestV1.spend.fileName,
      'sapling-spend.params',
    );
    expect(officialSaplingParameterManifestV1.spend.expectedBytes, 47958396);
    expect(
      officialSaplingParameterManifestV1.spend.sha256Hex,
      '8e48ffd23abb3a5fd9c5589204f32d9c31285a04b78096ba40a79b75677efc13',
    );
    expect(
      officialSaplingParameterManifestV1.output.fileName,
      'sapling-output.params',
    );
    expect(officialSaplingParameterManifestV1.output.expectedBytes, 3592860);
    expect(
      officialSaplingParameterManifestV1.output.sha256Hex,
      '2f0ebbcbb9bb0bcffe95a397e7eba89c29eb4dde6191c339db88570e3f3fb0e4',
    );
  });

  test('installs a verified pair once and reuses it offline', () async {
    final manifest = _manifest();
    final spend = utf8.encode('test spend params');
    final output = utf8.encode('test output params');
    final source = _MemorySource({
      manifest.spend.fileName: spend,
      manifest.output.fileName: output,
    });
    final cache = SaplingProvingParameterCache(
      cacheRoot: temp,
      manifest: manifest,
    );

    final installed = await cache.resolve(source: source);
    final offline = await SaplingProvingParameterCache(
      cacheRoot: temp,
      manifest: manifest,
    ).resolve();

    expect(source.opens, 2);
    expect(offline.version, 'test-v1');
    expect(offline.spendParamsPath, installed.spendParamsPath);
    expect(offline.outputParamsPath, installed.outputParamsPath);
    expect(await File(offline.spendParamsPath).readAsBytes(), spend);
    expect(await File(offline.outputParamsPath).readAsBytes(), output);
    expect(
      () => prepareNativeSaplingSend(
        network: ZcashNetwork.regtest,
        scan: const ZcashScanResult(
          scannedBlocks: 0,
          discoveredNotes: 0,
          totalValue: 0,
          notes: [],
        ),
        toAddress: 'zregtestsapling1recipient',
        changeAddress: 'zregtestsapling1change',
        amountZatoshis: 1000,
        targetHeight: 100,
        seedHex: '00' * 32,
        provingParameters: offline,
        allowExperimentalSaplingBuild: true,
      ),
      throwsA(
        isA<SaplingSendException>().having(
          (error) => error.refusal,
          'refusal',
          SaplingSendRefusal.noSaplingAnchor,
        ),
      ),
    );
  });

  test('replaces a corrupt regular cache with a verified pair', () async {
    final manifest = _manifest();
    final spend = utf8.encode('test spend params');
    final output = utf8.encode('test output params');
    final source = _MemorySource({
      manifest.spend.fileName: spend,
      manifest.output.fileName: output,
    });
    final cache = SaplingProvingParameterCache(
      cacheRoot: temp,
      manifest: manifest,
    );
    final installed = await cache.resolve(source: source);
    await File(installed.spendParamsPath).writeAsString('corrupt');

    final repaired = await cache.resolve(source: source);

    expect(source.opens, 4);
    expect(await File(repaired.spendParamsPath).readAsBytes(), spend);
    expect(await File(repaired.outputParamsPath).readAsBytes(), output);
  });

  test(
    'an interrupted source leaves no published pair or staging files',
    () async {
      final manifest = _manifest();
      final source = _InterruptedSource({
        manifest.spend.fileName: utf8.encode('test spend params'),
        manifest.output.fileName: utf8.encode('test output params'),
      });
      final cache = SaplingProvingParameterCache(
        cacheRoot: temp,
        manifest: manifest,
      );

      await expectLater(
        cache.resolve(source: source),
        throwsA(
          isA<SaplingParameterException>().having(
            (error) => error.failure,
            'failure',
            SaplingParameterFailure.sourceInterrupted,
          ),
        ),
      );

      final namespace = Directory('${temp.path}/zcash-sapling-params');
      expect(
        await namespace
            .list()
            .where((entry) => entry.path.contains('.tmp-'))
            .toList(),
        isEmpty,
      );
      expect(
        await Directory('${namespace.path}/${manifest.version}').exists(),
        isFalse,
      );
    },
  );

  test(
    'concurrent callers coalesce and publish only a complete pair',
    () async {
      final manifest = _manifest();
      final source = _GatedSource({
        manifest.spend.fileName: utf8.encode('test spend params'),
        manifest.output.fileName: utf8.encode('test output params'),
      });
      final first = SaplingProvingParameterCache(
        cacheRoot: temp,
        manifest: manifest,
      ).resolve(source: source);
      final second = SaplingProvingParameterCache(
        cacheRoot: temp,
        manifest: manifest,
      ).resolve(source: source);
      await source.outputStarted.future;

      final published = Directory(
        '${temp.path}/zcash-sapling-params/${manifest.version}',
      );
      expect(await published.exists(), isFalse);
      source.releaseOutput.complete();

      final pair = await Future.wait([first, second]);
      expect(source.opens, 2);
      expect(pair[0].spendParamsPath, pair[1].spendParamsPath);
      expect(await published.exists(), isTrue);
    },
  );

  test(
    'rejects wrong size and wrong hash without publishing either file',
    () async {
      final manifest = _manifest();
      final goodSpend = utf8.encode('test spend params');
      final goodOutput = utf8.encode('test output params');
      final cache = SaplingProvingParameterCache(
        cacheRoot: temp,
        manifest: manifest,
      );

      await expectLater(
        cache.resolve(
          source: _MemorySource({
            manifest.spend.fileName: [...goodSpend, 0],
            manifest.output.fileName: goodOutput,
          }),
        ),
        throwsA(
          isA<SaplingParameterException>().having(
            (error) => error.failure,
            'failure',
            SaplingParameterFailure.wrongSize,
          ),
        ),
      );
      await expectLater(
        cache.resolve(
          source: _MemorySource({
            manifest.spend.fileName: [
              goodSpend.first ^ 0xff,
              ...goodSpend.skip(1),
            ],
            manifest.output.fileName: goodOutput,
          }),
        ),
        throwsA(
          isA<SaplingParameterException>().having(
            (error) => error.failure,
            'failure',
            SaplingParameterFailure.wrongHash,
          ),
        ),
      );

      expect(
        await Directory(
          '${temp.path}/zcash-sapling-params/${manifest.version}',
        ).exists(),
        isFalse,
      );
    },
  );

  test('never accepts a symlink as a cached parameter file', () async {
    if (Platform.isWindows) {
      return;
    }
    final manifest = _manifest();
    final target = Directory(
      '${temp.path}/zcash-sapling-params/${manifest.version}',
    );
    await target.create(recursive: true);
    final outside = File('${temp.path}/outside.params');
    await outside.writeAsBytes(utf8.encode('test spend params'));
    await Link(
      '${target.path}/${manifest.spend.fileName}',
    ).create(outside.path);
    await File(
      '${target.path}/${manifest.output.fileName}',
    ).writeAsBytes(utf8.encode('test output params'));

    await expectLater(
      SaplingProvingParameterCache(
        cacheRoot: temp,
        manifest: manifest,
      ).resolve(),
      throwsA(
        isA<SaplingParameterException>().having(
          (error) => error.failure,
          'failure',
          SaplingParameterFailure.untrustedCacheEntry,
        ),
      ),
    );
  });

  test('rejects a symlinked cache root without exposing its target', () async {
    if (Platform.isWindows) {
      return;
    }
    final actual = await Directory('${temp.path}/actual').create();
    final linked = Link('${temp.path}/linked');
    await linked.create(actual.path);

    await expectLater(
      SaplingProvingParameterCache(
        cacheRoot: Directory(linked.path),
        manifest: _manifest(),
      ).resolve(),
      throwsA(
        isA<SaplingParameterException>()
            .having(
              (error) => error.failure,
              'failure',
              SaplingParameterFailure.untrustedCacheEntry,
            )
            .having(
              (error) => error.toString(),
              'diagnostic',
              isNot(contains(actual.path)),
            ),
      ),
    );
  });

  test(
    'installs from a verified local pair and rejects a source symlink',
    () async {
      if (Platform.isWindows) {
        return;
      }
      final manifest = _manifest();
      final sourceDirectory = await Directory('${temp.path}/source').create();
      final spend = File('${sourceDirectory.path}/spend.params');
      final output = File('${sourceDirectory.path}/output.params');
      await spend.writeAsBytes(utf8.encode('test spend params'));
      await output.writeAsBytes(utf8.encode('test output params'));
      final source = FileSaplingParameterSource(
        manifest: manifest,
        spendFile: spend,
        outputFile: output,
      );
      final installed = await SaplingProvingParameterCache(
        cacheRoot: Directory('${temp.path}/good-cache'),
        manifest: manifest,
      ).resolve(source: source);
      expect(
        await File(installed.spendParamsPath).readAsBytes(),
        await spend.readAsBytes(),
      );

      final linkedSpend = Link('${sourceDirectory.path}/linked-spend.params');
      await linkedSpend.create(spend.path);
      final linkedSource = FileSaplingParameterSource(
        manifest: manifest,
        spendFile: File(linkedSpend.path),
        outputFile: output,
      );
      await expectLater(
        SaplingProvingParameterCache(
          cacheRoot: Directory('${temp.path}/linked-cache'),
          manifest: manifest,
        ).resolve(source: linkedSource),
        throwsA(
          isA<SaplingParameterException>().having(
            (error) => error.failure,
            'failure',
            SaplingParameterFailure.untrustedCacheEntry,
          ),
        ),
      );
    },
  );

  test('bounds both stalled requests and total acquisition time', () async {
    final manifest = _manifest();
    await expectLater(
      SaplingProvingParameterCache(
        cacheRoot: Directory('${temp.path}/stalled'),
        manifest: manifest,
        requestTimeout: const Duration(milliseconds: 10),
        totalTimeout: const Duration(seconds: 1),
      ).resolve(source: _StalledSource()),
      throwsA(
        isA<SaplingParameterException>().having(
          (error) => error.failure,
          'failure',
          SaplingParameterFailure.requestTimedOut,
        ),
      ),
    );
    await expectLater(
      SaplingProvingParameterCache(
        cacheRoot: Directory('${temp.path}/slow'),
        manifest: manifest,
        requestTimeout: const Duration(milliseconds: 50),
        totalTimeout: const Duration(milliseconds: 20),
      ).resolve(source: _SlowSource()),
      throwsA(
        isA<SaplingParameterException>().having(
          (error) => error.failure,
          'failure',
          SaplingParameterFailure.totalTimedOut,
        ),
      ),
    );
  });

  test('never coalesces two different pairs under one version', () async {
    final manifest = _manifest();
    final source = _GatedSource({
      manifest.spend.fileName: utf8.encode('test spend params'),
      manifest.output.fileName: utf8.encode('test output params'),
    });
    final first = SaplingProvingParameterCache(
      cacheRoot: temp,
      manifest: manifest,
    ).resolve(source: source);
    await source.outputStarted.future;
    final conflicting = SaplingParameterManifest(
      version: manifest.version,
      spend: SaplingParameterArtifact(
        fileName: manifest.spend.fileName,
        expectedBytes: manifest.spend.expectedBytes,
        sha256Hex: '0' * 64,
      ),
      output: manifest.output,
    );

    final conflictingResolution = SaplingProvingParameterCache(
      cacheRoot: temp,
      manifest: conflicting,
    ).resolve(source: source);
    source.releaseOutput.complete();
    await expectLater(
      conflictingResolution,
      throwsA(
        isA<SaplingParameterException>().having(
          (error) => error.failure,
          'failure',
          SaplingParameterFailure.invalidManifest,
        ),
      ),
    );
    await first;
  });
}
