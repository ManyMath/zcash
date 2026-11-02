@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';

const _seedHex =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'
    '202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f';
const _malformedUfvk = 'not-a-real-uviewtest-wallet-input';

void main() {
  group('Unified Address receiver semantics through Dart native-assets', () {
    test('derive deterministic receiver matrix from the fixed seed', () async {
      final matrix = await _runProbe('matrix');
      final regtest = _networkResult(matrix, 'regtest');
      final testnet = _networkResult(matrix, 'test');
      final repeatedRegtest = _nestedStringMap(regtest, 'repeated');

      expect(regtest['ufvkMatches'], isTrue);
      expect(testnet['ufvkMatches'], isTrue);
      expect(regtest['ufvkPrefix'], 'uviewtest');
      expect(testnet['ufvkPrefix'], 'uviewtest');

      expect(regtest['ua'], repeatedRegtest['ua']);
      expect(regtest['sapling'], repeatedRegtest['sapling']);
      expect(regtest['orchard'], repeatedRegtest['orchard']);
      expect(regtest['transparent'], repeatedRegtest['transparent']);

      expect(regtest['addressEncoding'], 'regtest');
      expect(regtest['ua'], startsWith('uregtest'));
      expect(regtest['sapling'], startsWith('zregtestsapling'));
      expect(regtest['orchard'], startsWith('uregtest'));
      expect(regtest['orchard'], isNot(equals(regtest['ua'])));
      expect(regtest['transparent'], startsWith('tm'));

      expect(testnet['addressEncoding'], 'testnet');
      expect(testnet['sapling'], startsWith('ztestsapling'));
      expect(testnet['sapling'], isNot(equals(regtest['sapling'])));
      expect(testnet['ua'], startsWith('utest'));
      expect(testnet['orchard'], startsWith('utest'));

      expect(testnet['ua'], isNot(equals(regtest['ua'])));
      expect(testnet['orchard'], isNot(equals(regtest['orchard'])));
      expect(testnet['transparent'], equals(regtest['transparent']));
      expect(testnet['transparent'], startsWith('tm'));
    });

    test(
      'rejects malformed UFVK and unsupported network without secret echo',
      () async {
        final errors = await _runProbe('errors');
        final malformed = errors['malformedUfvkError'] as String;
        final unsupported = errors['unsupportedNetworkError'] as String;

        expect(malformed, contains('ufvk_to_address failed'));
        expect(
          unsupported,
          contains("network must be 'main', 'test', or 'regtest'"),
        );
        expect(errors['containsSeed'], isFalse);
        expect(errors['containsMalformedUfvk'], isFalse);
        expect(errors['containsDerivedUfvk'], isFalse);
        expect(malformed, isNot(contains(_seedHex)));
        expect(malformed, isNot(contains(_malformedUfvk)));
        expect(unsupported, isNot(contains(_seedHex)));
        expect(unsupported, isNot(contains(_malformedUfvk)));
      },
    );
  });
}

Map<String, Object?> _networkResult(
  Map<String, Object?> matrix,
  String network,
) {
  final value = matrix[network];
  if (value is Map<String, Object?>) {
    return value;
  }
  throw StateError('probe result missing $network receiver object');
}

Map<String, Object?> _nestedStringMap(Map<String, Object?> parent, String key) {
  final value = parent[key];
  if (value is Map<String, Object?>) {
    return value;
  }
  throw StateError('probe result missing $key receiver object');
}

Future<Map<String, Object?>> _runProbe(String mode) async {
  final packageDir = _packageDirectory();
  final environment = Map<String, String>.of(Platform.environment)
    ..remove('ZCASH_FFI_LIB');
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['run', 'test/fixtures/unified_address_probe.dart', mode],
    environment: environment,
    includeParentEnvironment: false,
    workingDirectory: packageDir.path,
  );

  expect(
    result.exitCode,
    0,
    reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
  );
  final stdout = result.stdout as String;
  final jsonStart = stdout.indexOf('{');
  if (jsonStart < 0) {
    throw StateError('probe did not emit JSON stdout: $stdout');
  }
  final decoded = jsonDecode(stdout.substring(jsonStart));
  if (decoded is Map<String, Object?>) {
    return decoded;
  }
  throw StateError('probe returned non-object JSON: ${result.stdout}');
}

Directory _packageDirectory() {
  final current = Directory.current;
  if (_isZcashFfiPackage(current)) {
    return current;
  }
  final monorepoNested = Directory(
    path.join(current.path, 'packages', 'zcash_flutter'),
  );
  if (_isZcashFfiPackage(monorepoNested)) {
    return monorepoNested;
  }
  throw StateError('Could not locate zcash_flutter package directory');
}

bool _isZcashFfiPackage(Directory directory) {
  final pubspec = File(path.join(directory.path, 'pubspec.yaml'));
  if (!pubspec.existsSync()) {
    return false;
  }
  return pubspec.readAsStringSync().contains(
    RegExp(r'^name:\s*zcash_flutter\s*$', multiLine: true),
  );
}
