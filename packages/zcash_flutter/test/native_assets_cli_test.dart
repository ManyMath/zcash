@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zcash_ffi/zcash_ffi.dart'
    show
        CapabilityStatus,
        CompactBlockScanInput,
        NativeCapability,
        NativeCapabilitySnapshot,
        ZcashAddressNetwork,
        ZcashAddressPool,
        ZcashAddressReceiverType,
        ZcashKeyType,
        ZcashKeyValidationReason;
import 'package:zcash_ffi/src/ffi/zcash_native_assets.dart';

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
  group('native-assets FFI wrapper', () {
    test(
      'dart run zcash_tool derive prints stable native-assets labels without ZCASH_FFI_LIB',
      () async {
        final environment = Map<String, String>.of(Platform.environment)
          ..remove('ZCASH_FFI_LIB');
        final packageDir = _packageDirectory();
        final result = await Process.run(
          Platform.resolvedExecutable,
          ['run', 'zcash_tool', 'derive'],
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

    test(
      'dart run zcash_tool capabilities prints native version and capability '
      'statuses without secrets',
      () async {
        final environment = Map<String, String>.of(Platform.environment)
          ..remove('ZCASH_FFI_LIB');
        final packageDir = _packageDirectory();
        final result = await Process.run(
          Platform.resolvedExecutable,
          ['run', 'zcash_tool', 'capabilities'],
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
      },
    );

    test(
      'dart run zcash_tool capabilities --json is parseable and seed-free',
      () async {
        final environment = Map<String, String>.of(Platform.environment)
          ..remove('ZCASH_FFI_LIB');
        final packageDir = _packageDirectory();
        final result = await Process.run(
          Platform.resolvedExecutable,
          ['run', 'zcash_tool', 'capabilities', '--json'],
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
      'dart run zcash_tool rejects unknown commands with exit code 2',
      () async {
        final environment = Map<String, String>.of(Platform.environment)
          ..remove('ZCASH_FFI_LIB');
        final packageDir = _packageDirectory();
        final result = await Process.run(
          Platform.resolvedExecutable,
          ['run', 'zcash_tool', 'not-a-command'],
          environment: environment,
          includeParentEnvironment: false,
          workingDirectory: packageDir.path,
        );

        expect(result.exitCode, 2);
        expect(result.stderr as String, contains('unknown command'));
      },
    );

    test('dart run zcash_tool address decodes a valid address', () async {
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
      'dart run zcash_tool address --json emits parseable metadata',
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

    test('dart run zcash_tool address rejects a wrong-network address '
        'without echoing it', () async {
      final address = _regtestTransparentAddress;
      final result = await _runTool(['address', address, '--network', 'main']);

      expect(result.exitCode, 1);
      final stderr = result.stderr as String;
      expect(stderr, contains('address'));
      expect(stderr, isNot(contains(address)));
    });

    test('dart run zcash_tool address rejects malformed input without '
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
      'dart run zcash_tool derive accepts a supplied seed without echoing it',
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
      'dart run zcash_tool derive supplied seed differs from the default',
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
      'dart run zcash_tool derive rejects a malformed seed without echoing it',
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
      'dart run zcash_tool scan summarizes an empty-blocks fixture',
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

    test('dart run zcash_tool scan --json emits a parseable summary', () async {
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

    test('dart run zcash_tool scan rejects a malformed JSON file without '
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
      'dart run zcash_tool scan reports a missing file with exit code 1',
      () async {
        final result = await _runTool([
          'scan',
          '/nonexistent/zcash_tool_scan_input.json',
        ]);

        expect(result.exitCode, 1);
        expect(result.stderr as String, contains('not found'));
      },
    );

    test('version is semver through native assets', () {
      expect(zcashNativeVersion(), matches(RegExp(r'^\d+\.\d+\.\d+')));
    });

    test('native capabilities match the documented package matrix', () {
      final capabilities = zcashNativeCapabilities();

      expect(
        capabilities.statuses,
        NativeCapabilitySnapshot.documented.statuses,
      );
      expect(
        capabilities.statusFor(NativeCapability.saplingScan),
        CapabilityStatus.supported,
      );
      expect(
        capabilities.statusFor(NativeCapability.orchardNoteDiscovery),
        CapabilityStatus.unsupported,
      );
    });

    test('derives deterministic regtest UFVK and address components', () {
      final ufvk = zcashNativeSeedToAccountUfvk(
        seedHex: _seed,
        network: 'regtest',
      );
      final accountMetadata = zcashNativeSeedToAccountMetadata(
        seedHex: _seed,
        network: 'regtest',
      );
      expect(accountMetadata.network, ZcashAddressNetwork.regtest);
      expect(accountMetadata.accountIndex, 0);
      expect(accountMetadata.ufvk, equals(ufvk));
      expect(accountMetadata.transparentAccountXpub, startsWith('tpub'));
      expect(accountMetadata.hasOrchard, isTrue);
      expect(accountMetadata.hasSapling, isTrue);
      expect(accountMetadata.hasTransparent, isTrue);

      final viewingKeys = zcashNativeSeedToViewingKeys(
        seedHex: _seed,
        network: 'regtest',
      );
      expect(viewingKeys.network, ZcashAddressNetwork.regtest);
      expect(viewingKeys.accountIndex, 0);
      expect(viewingKeys.transparent.externalIvk, hasLength(130));
      expect(viewingKeys.transparent.internalIvk, hasLength(130));
      expect(viewingKeys.transparent.defaultExternalAddress, startsWith('tm'));
      _expectOptionalPrefix(
        viewingKeys.sapling.defaultAddress,
        'zregtestsapling',
      );
      expect(viewingKeys.hasOrchard, isTrue);
      expect(viewingKeys.toJson().toString(), isNot(contains(_seed)));

      final repeated = zcashNativeSeedToAccountUfvk(
        seedHex: _seed,
        network: 'test',
      );
      expect(ufvk, equals(repeated));
      expect(ufvk, startsWith('uviewtest'));

      final address = zcashNativeUfvkToAddress(ufvk: ufvk, network: 'regtest');
      final diversifierSearch = zcashNativeUfvkToDiversifierSearch(
        ufvk: ufvk,
        network: 'regtest',
        diversifierIndex: 1,
      );
      final repeatedAddress = zcashNativeUfvkToAddress(
        ufvk: ufvk,
        network: 'test',
      );
      expect(diversifierSearch.requestedIndex, 1);
      expect(diversifierSearch.nextValidIndex, greaterThanOrEqualTo(1));
      expect(diversifierSearch.receiverPresence.sapling, isTrue);
      expect(diversifierSearch.addresses.ua, startsWith('uregtest'));
      expect(diversifierSearch.addressEncoding, 'regtest');
      expect(address.addressEncoding, 'regtest');
      expect(repeatedAddress.addressEncoding, 'testnet');
      expect(address.ua, isNot(equals(repeatedAddress.ua)));
      expect(address.ua, startsWith('uregtest'));
      expect(repeatedAddress.ua, startsWith('utest'));
      _expectOptionalPrefix(address.sapling, 'zregtestsapling');
      _expectOptionalPrefix(repeatedAddress.sapling, 'ztestsapling');
      _expectOptionalPrefix(address.orchard, 'uregtest');
      _expectOptionalPrefix(address.transparent, 'tm');
      expect(address.transparent, equals(repeatedAddress.transparent));
      expect(
        [
          address.sapling,
          address.orchard,
          address.transparent,
        ].whereType<String>(),
        isNotEmpty,
      );

      final xpub = zcashNativeSeedToTransparentXpub(
        seedHex: _seed,
        network: 'regtest',
      );
      final transparentAddress = zcashNativeTransparentAddress(
        xpub: xpub,
        network: 'regtest',
      );
      expect(xpub, startsWith('tpub'));
      expect(transparentAddress, startsWith('tm'));
      final transparentMetadata = zcashNativeDecodeAddress(
        address: transparentAddress,
        network: 'regtest',
      );
      expect(transparentMetadata.network, ZcashAddressNetwork.regtest);
      expect(transparentMetadata.receiverType, ZcashAddressReceiverType.p2pkh);
      expect(transparentMetadata.pool, ZcashAddressPool.transparent);
      expect(transparentMetadata.receivers.transparent, isTrue);

      final saplingSpendingKey = zcashNativeSeedToSaplingSpendingKey(
        seedHex: _seed,
        network: 'regtest',
      );
      final testnetSaplingSpendingKey = zcashNativeSeedToSaplingSpendingKey(
        seedHex: _seed,
        network: 'test',
      );
      expect(saplingSpendingKey, startsWith('secret-extended-key-regtest'));
      expect(testnetSaplingSpendingKey, startsWith('secret-extended-key-test'));
      expect(saplingSpendingKey, isNot(equals(testnetSaplingSpendingKey)));
      expect(saplingSpendingKey, isNot(contains(_seed)));

      final ufvkValidation = zcashNativeValidateKey(
        key: ufvk,
        network: 'regtest',
        keyType: ZcashKeyType.ufvk,
      );
      expect(ufvkValidation.valid, isTrue);
      expect(ufvkValidation.network, ZcashAddressNetwork.regtest);
      expect(ufvkValidation.components!.sapling, isTrue);

      final regtestSkValidation = zcashNativeValidateKey(
        key: saplingSpendingKey,
        network: 'regtest',
        keyType: ZcashKeyType.saplingExtendedSpendingKey,
      );
      expect(regtestSkValidation.valid, isTrue);
      expect(regtestSkValidation.toJson().toString(), isNot(contains(_seed)));

      final wrongNetworkSk = zcashNativeValidateKey(
        key: saplingSpendingKey,
        network: 'test',
        keyType: ZcashKeyType.saplingExtendedSpendingKey,
      );
      expect(wrongNetworkSk.valid, isFalse);
      expect(wrongNetworkSk.reason, ZcashKeyValidationReason.wrongNetwork);

      final xpubValidation = zcashNativeValidateKey(
        key: xpub,
        network: 'regtest',
        keyType: ZcashKeyType.transparentXpub,
      );
      expect(xpubValidation.valid, isTrue);
    });

    test('scanner returns zero-note summary through native assets', () {
      final ufvk = zcashNativeSeedToAccountUfvk(
        seedHex: _seed,
        network: 'regtest',
      );

      final result = zcashNativeScanCompactBlocks(
        ufvk: ufvk,
        network: 'regtest',
        blocks: const [],
      );

      expect(result.scannedBlocks, 0);
      expect(result.discoveredNotes, 0);
      expect(result.notes, isEmpty);
    });

    test('scanner converts native-assets errors consistently', () {
      const secretUfvk = 'uviewtest-secret-that-must-not-leak';
      expect(
        () => zcashNativeScanCompactBlocks(
          ufvk: secretUfvk,
          network: 'not-a-network',
          blocks: const <CompactBlockScanInput>[],
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('unsupported_network'), isNot(contains(secretUfvk))),
          ),
        ),
      );
    });

    test('throws explicit Dart errors for malformed seed and network', () {
      expect(
        () => zcashNativeSeedToAccountUfvk(
          seedHex: 'not-hex',
          network: 'regtest',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('seed is not valid hex'),
          ),
        ),
      );
      expect(
        () => zcashNativeSeedToAccountUfvk(
          seedHex: _seed,
          network: 'not-a-network',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains("network must be 'main', 'test', or 'regtest'"),
          ),
        ),
      );
    });

    test('throws explicit Dart errors for Sapling key invalid inputs', () {
      expect(
        () => zcashNativeSeedToSaplingSpendingKey(
          seedHex: '000102',
          network: 'regtest',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('seed_to_sapling_spending_key failed'),
              contains('seed must be at least 32 bytes'),
              isNot(contains('000102')),
            ),
          ),
        ),
      );
      expect(
        () => zcashNativeSeedToSaplingSpendingKey(
          seedHex: _seed,
          network: 'not-a-network',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains("network must be 'main', 'test', or 'regtest'"),
          ),
        ),
      );
    });
  });
}

File _writeTempScanInput(Map<String, Object?>? content, {String? rawContents}) {
  final dir = Directory.systemTemp.createTempSync('zcash_tool_scan');
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
    ['run', 'zcash_tool', ...commandArgs],
    environment: environment,
    includeParentEnvironment: false,
    workingDirectory: _packageDirectory().path,
  );
}

void _expectOptionalPrefix(String? value, String prefix) {
  if (value == null) {
    return;
  }
  expect(value, startsWith(prefix));
}

Directory _packageDirectory() {
  final current = Directory.current;
  if (_isZcashFfiPackage(current)) {
    return current;
  }
  final monorepoNested = Directory('${current.path}/packages/zcash_ffi');
  if (_isZcashFfiPackage(monorepoNested)) {
    return monorepoNested;
  }
  return current;
}

bool _isZcashFfiPackage(Directory directory) {
  final pubspec = File('${directory.path}/pubspec.yaml');
  if (!pubspec.existsSync()) {
    return false;
  }
  return pubspec.readAsStringSync().contains(
    RegExp(r'^name:\s*zcash_ffi\s*$', multiLine: true),
  );
}
