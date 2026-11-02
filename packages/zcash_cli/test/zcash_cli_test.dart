@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

const _seed =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'
    '202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f';

// Hard-coded so the parent isolate never loads the FFI while `dart run`
// relinks it.
const _regtestTransparentAddress = 'tmNuoMzZxTiBkEbHVNwUsr3a1iELSeNZkRA';

const _regtestUfvk =
    'uviewtest15kkncs9ud8zy07ddcyqt9u6lmme700q9e92yg7elsyzvrfs5ssdgmvgkydlasuzv'
    '3kurftr78jh8qgj8fp98u6d2swkyca7ht4qy54hl23alte6ut2xprhp3qdmtk2n6sl2cwkuknf'
    '3z8n53l7s37p3ajranx8j80nxwe2rd0eyl9qalw3fz37ukgauwmpk5kuustuhpju62hw9ehnl9'
    'kkx9selsvrjj6kga3y5pqrhg9qgfwa6gsnlxtcsksqmjwzvzpmvpmmztd5pg0kwjuuaacsejnh'
    'uc4nl43acnaeglxhxthyqrf92etu00jmhzl2zl7rkrdl66jwvtstal8yhxff5fdpscd9mh0vfn'
    '590ztcek04vx5r9pf7kd7chk3qjhuccm2fm0c2hpfvuyhmavwwserl79pnya7kcydjr4da844l'
    'w44sl3tjgn2q5cvm57yq7u9r69hhwkgfamykt6390tjrt64zwgya30lgu9cfscfspa7hqp';

void main() {
  group('zcash_cli', () {
    test(
      'dart run zcash_cli derive prints stable native-assets labels without ZCASH_FFI_LIB',
      () async {
        final environment = Map<String, String>.of(Platform.environment)
          ..remove('ZCASH_FFI_LIB');
        final packageDir = _packageDirectory();
        final result = await Process.run(
          Platform.resolvedExecutable,
          ['run', 'zcash_cli', 'derive'],
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
        expect(stdout, contains(RegExp(r'zcash_ffi_version: \d+\.\d+\.\d+')));
        expect(stdout, contains('ufvk: uviewtest'));
        expect(stdout, contains('unified_address: uregtest'));
        expect(stdout, contains('sapling: zregtestsapling'));
        expect(stdout, contains('orchard: uregtest'));
        expect(stdout, contains('transparent: tm'));
      },
    );

    test('dart run zcash_cli capabilities prints native version and capability '
        'statuses without secrets', () async {
      final environment = Map<String, String>.of(Platform.environment)
        ..remove('ZCASH_FFI_LIB');
      final packageDir = _packageDirectory();
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'zcash_cli', 'capabilities'],
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
      expect(stdout, contains(RegExp(r'zcash_ffi_version: \d+\.\d+\.\d+')));
      expect(stdout, contains('capability sapling_scan: supported'));
      expect(
        stdout,
        contains('capability orchard_note_discovery: unsupported'),
      );
      expect(
        stdout,
        contains('capability transparent_transaction_build: unsupported'),
      );
      expect(
        stdout,
        contains('capability sapling_transaction_build: unsupported'),
      );
      expect(stdout, isNot(contains(_seed)));
      expect(stdout, isNot(contains('uview')));
      expect(stdout, isNot(contains('secret-extended-key')));
    });

    test(
      'dart run zcash_cli capabilities --json is parseable and seed-free',
      () async {
        final environment = Map<String, String>.of(Platform.environment)
          ..remove('ZCASH_FFI_LIB');
        final packageDir = _packageDirectory();
        final result = await Process.run(
          Platform.resolvedExecutable,
          ['run', 'zcash_cli', 'capabilities', '--json'],
          environment: environment,
          includeParentEnvironment: false,
          workingDirectory: packageDir.path,
        );

        expect(
          result.exitCode,
          0,
          reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
        );
        final out = result.stdout as String;
        final decoded =
            jsonDecode(out.substring(out.indexOf('{'))) as Map<String, Object?>;
        expect(decoded['zcash_ffi_version'], isA<String>());
        final capabilities = decoded['capabilities'] as Map<String, Object?>;
        expect(capabilities['sapling_scan'], 'supported');
        expect(capabilities['orchard_note_discovery'], 'unsupported');
        expect(result.stdout as String, isNot(contains(_seed)));
      },
    );

    test(
      'dart run zcash_cli rejects unknown commands with exit code 2',
      () async {
        final environment = Map<String, String>.of(Platform.environment)
          ..remove('ZCASH_FFI_LIB');
        final packageDir = _packageDirectory();
        final result = await Process.run(
          Platform.resolvedExecutable,
          ['run', 'zcash_cli', 'not-a-command'],
          environment: environment,
          includeParentEnvironment: false,
          workingDirectory: packageDir.path,
        );

        expect(result.exitCode, 2);
        expect(result.stderr as String, contains('unknown command'));
      },
    );

    test('dart run zcash_cli address decodes a valid address', () async {
      final address = _regtestTransparentAddress;
      final result = await _runTool([
        'address',
        address,
        '--network',
        'regtest',
      ]);

      expect(
        result.exitCode,
        0,
        reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      final stdout = result.stdout as String;
      expect(stdout, contains('network: regtest'));
      expect(stdout, contains('pool: transparent'));
      expect(stdout, contains('receiver_type: p2pkh'));
      expect(stdout, contains('receiver_transparent: true'));
      expect(stdout, contains('receiver_sapling: false'));
    });

    test(
      'dart run zcash_cli address --json emits parseable metadata',
      () async {
        final address = _regtestTransparentAddress;
        final result = await _runTool([
          'address',
          address,
          '--network',
          'regtest',
          '--json',
        ]);

        expect(
          result.exitCode,
          0,
          reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
        );
        final out = result.stdout as String;
        final decoded =
            jsonDecode(out.substring(out.indexOf('{'))) as Map<String, Object?>;
        expect(decoded['network'], 'regtest');
        expect(decoded['pool'], 'transparent');
        expect(decoded['receivers'], isA<Map<String, Object?>>());
      },
    );

    test('dart run zcash_cli address rejects a wrong-network address '
        'without echoing it', () async {
      final address = _regtestTransparentAddress;
      final result = await _runTool(['address', address, '--network', 'main']);

      expect(result.exitCode, 1);
      final stderr = result.stderr as String;
      expect(stderr, contains('address'));
      expect(stderr, isNot(contains(address)));
    });

    test('dart run zcash_cli address rejects malformed input without '
        'echoing it', () async {
      const garbage = 'not-an-address-leak-canary';
      final result = await _runTool([
        'address',
        garbage,
        '--network',
        'regtest',
      ]);

      expect(result.exitCode, 1);
      expect(result.stderr as String, isNot(contains(garbage)));
    });

    test(
      'dart run zcash_cli derive accepts a supplied seed without echoing it',
      () async {
        final suppliedSeed = 'ab' * 64;
        final result = await _runTool([
          'derive',
          '--seed',
          suppliedSeed,
          '--network',
          'regtest',
        ]);

        expect(
          result.exitCode,
          0,
          reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
        );
        final stdout = result.stdout as String;
        expect(stdout, contains('network: regtest'));
        expect(stdout, contains('ufvk: uviewtest'));
        expect(stdout, isNot(contains(suppliedSeed)));
      },
    );

    test(
      'dart run zcash_cli derive supplied seed differs from the default',
      () async {
        final suppliedSeed = 'ab' * 64;
        final customResult = await _runTool([
          'derive',
          '--seed',
          suppliedSeed,
          '--network',
          'regtest',
        ]);
        final defaultResult = await _runTool([
          'derive',
          '--network',
          'regtest',
        ]);

        expect(customResult.exitCode, 0);
        expect(defaultResult.exitCode, 0);
        final customUfvk = _ufvkLine(customResult.stdout as String);
        final defaultUfvk = _ufvkLine(defaultResult.stdout as String);
        expect(customUfvk, isNotNull);
        expect(customUfvk, isNot(equals(defaultUfvk)));
      },
    );

    test(
      'dart run zcash_cli derive rejects a malformed seed without echoing it',
      () async {
        const malformedSeed = 'nothexcanaryleak';
        final result = await _runTool([
          'derive',
          '--seed',
          malformedSeed,
          '--network',
          'regtest',
        ]);

        expect(result.exitCode, 1);
        final combined = '${result.stdout}${result.stderr}';
        expect(combined, isNot(contains(malformedSeed)));
      },
    );

    test(
      'dart run zcash_cli scan summarizes an empty-blocks fixture',
      () async {
        final file = _writeTempScanInput({
          'ufvk': _regtestUfvk,
          'network': 'regtest',
          'blocks': const <Object?>[],
        });
        try {
          final result = await _runTool(['scan', file.path]);

          expect(
            result.exitCode,
            0,
            reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
          );
          final stdout = result.stdout as String;
          expect(stdout, contains('network: regtest'));
          expect(stdout, contains('scanned_blocks: 0'));
          expect(stdout, contains('discovered_notes: 0'));
          expect(stdout, contains('total_value: 0'));
          expect(stdout, isNot(contains(_regtestUfvk)));
        } finally {
          file.parent.deleteSync(recursive: true);
        }
      },
    );

    test('dart run zcash_cli scan --json emits a parseable summary', () async {
      final file = _writeTempScanInput({
        'ufvk': _regtestUfvk,
        'blocks': const <Object?>[],
      });
      try {
        final result = await _runTool([
          'scan',
          file.path,
          '--network',
          'regtest',
          '--json',
        ]);

        expect(
          result.exitCode,
          0,
          reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
        );
        final out = result.stdout as String;
        final decoded =
            jsonDecode(out.substring(out.indexOf('{'))) as Map<String, Object?>;
        expect(decoded['scanned_blocks'], 0);
        expect(decoded['discovered_notes'], 0);
        expect(out, isNot(contains(_regtestUfvk)));
      } finally {
        file.parent.deleteSync(recursive: true);
      }
    });

    test('dart run zcash_cli scan rejects a malformed JSON file without '
        'echoing contents', () async {
      const canary = 'scan-file-leak-canary';
      final file = _writeTempScanInput(null, rawContents: '{ not json $canary');
      try {
        final result = await _runTool(['scan', file.path]);

        expect(result.exitCode, 1);
        final combined = '${result.stdout}${result.stderr}';
        expect(combined, isNot(contains(canary)));
      } finally {
        file.parent.deleteSync(recursive: true);
      }
    });

    test(
      'dart run zcash_cli scan reports a missing file with exit code 1',
      () async {
        final result = await _runTool([
          'scan',
          '/nonexistent/zcash_cli_scan_input.json',
        ]);

        expect(result.exitCode, 1);
        expect(result.stderr as String, contains('not found'));
      },
    );
  });
}

File _writeTempScanInput(Map<String, Object?>? content, {String? rawContents}) {
  final dir = Directory.systemTemp.createTempSync('zcash_cli_scan');
  final file = File('${dir.path}/scan_input.json');
  file.writeAsStringSync(rawContents ?? jsonEncode(content));
  return file;
}

String? _ufvkLine(String stdout) {
  for (final line in const LineSplitter().convert(stdout)) {
    if (line.startsWith('ufvk: ')) {
      return line;
    }
  }
  return null;
}

Future<ProcessResult> _runTool(List<String> commandArgs) {
  final environment = Map<String, String>.of(Platform.environment)
    ..remove('ZCASH_FFI_LIB');
  return Process.run(
    Platform.resolvedExecutable,
    ['run', 'zcash_cli', ...commandArgs],
    environment: environment,
    includeParentEnvironment: false,
    workingDirectory: _packageDirectory().path,
  );
}

Directory _packageDirectory() {
  final current = Directory.current;
  if (_isZcashCliPackage(current)) {
    return current;
  }
  final monorepoNested = Directory('${current.path}/packages/zcash_cli');
  if (_isZcashCliPackage(monorepoNested)) {
    return monorepoNested;
  }
  return current;
}

bool _isZcashCliPackage(Directory directory) {
  final pubspec = File('${directory.path}/pubspec.yaml');
  if (!pubspec.existsSync()) {
    return false;
  }
  return pubspec.readAsStringSync().contains(
    RegExp(r'^name:\s*zcash_cli\s*$', multiLine: true),
  );
}
