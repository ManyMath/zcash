@TestOn('vm')
library;

import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../hook/build.dart' as build_hook;

void main() {
  group('pub.dev publishability', () {
    test('does not opt out of publishing', () {
      final pubspec = _readPackageFile('pubspec.yaml');

      expect(
        pubspec,
        isNot(contains(RegExp(r'^publish_to:', multiLine: true))),
      );
    });

    test('depends only on hosted packages', () {
      final pubspec = _readPackageFile('pubspec.yaml');

      expect(pubspec, isNot(contains(RegExp(r'^\s+git:', multiLine: true))));
      expect(
        pubspec,
        isNot(contains(RegExp(r'^\s+path:\s*(\.{0,2}/|$)', multiLine: true))),
      );
      expect(
        pubspec,
        isNot(contains(RegExp(r'^dependency_overrides:', multiLine: true))),
      );
    });

    test('does not ignore the crate the hook builds', () {
      final gitignoreRules = _readPackageFile('.gitignore')
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty && !line.startsWith('#'));

      expect(gitignoreRules, isNot(contains(startsWith('native'))));
    });
  });

  group('zcash-ffi manifest path contract', () {
    test(
      'uses the default embedded zcash-ffi crate when no override is set',
      () {
        final packageRoot = _packageDirectory().path;

        final selected = build_hook.resolveZcashFfiManifestDir(
          packageRoot: packageRoot,
          environment: const {},
        );

        expect(
          selected,
          path.normalize(path.join(packageRoot, 'native', 'zcash-ffi')),
        );
        expect(File(path.join(selected, 'Cargo.toml')).existsSync(), isTrue);
      },
    );

    test('accepts absolute and package-root-relative override paths', () {
      final temp = Directory.systemTemp.createTempSync(
        'zcash_ffi_manifest_test_',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      final crate = Directory(path.join(temp.path, 'crate'))..createSync();
      File(
        path.join(crate.path, 'Cargo.toml'),
      ).writeAsStringSync('[package]\nname = "fixture"\n');
      final packageRoot = _packageDirectory().path;
      final relativeCrate = path.relative(crate.path, from: packageRoot);

      final absolute = build_hook.resolveZcashFfiManifestDir(
        packageRoot: packageRoot,
        environment: {build_hook.zcashFfiManifestDirEnvVar: crate.path},
      );
      final relative = build_hook.resolveZcashFfiManifestDir(
        packageRoot: packageRoot,
        environment: {build_hook.zcashFfiManifestDirEnvVar: relativeCrate},
      );

      expect(absolute, path.normalize(crate.path));
      expect(relative, path.normalize(crate.path));
    });

    test('rejects empty override values before cargo runs', () {
      expect(
        () => build_hook.resolveZcashFfiManifestDir(
          packageRoot: _packageDirectory().path,
          environment: const {build_hook.zcashFfiManifestDirEnvVar: '   '},
        ),
        throwsA(_actionableManifestError(contains('is empty'))),
      );
    });

    test('rejects nonexistent override paths before cargo runs', () {
      final packageRoot = _packageDirectory().path;
      final missingPath = path.join(packageRoot, 'does-not-exist');

      expect(
        () => build_hook.resolveZcashFfiManifestDir(
          packageRoot: packageRoot,
          environment: {build_hook.zcashFfiManifestDirEnvVar: 'does-not-exist'},
        ),
        throwsA(
          _actionableManifestError(
            allOf(contains(missingPath), contains('Cargo.toml')),
          ),
        ),
      );
    });

    test('rejects directories missing Cargo.toml before cargo runs', () {
      final temp = Directory.systemTemp.createTempSync(
        'zcash_ffi_manifest_test_',
      );
      addTearDown(() => temp.deleteSync(recursive: true));

      expect(
        () => build_hook.validateZcashFfiManifestDir(temp.path),
        throwsA(
          _actionableManifestError(
            allOf(contains(temp.path), contains('Cargo.toml')),
          ),
        ),
      );
    });
  });
}

Matcher _actionableManifestError(Matcher messageMatcher) {
  return isA<StateError>()
      .having(
        (e) => e.message,
        'message',
        contains(build_hook.zcashFfiManifestDirEnvVar),
      )
      .having((e) => e.message, 'message', messageMatcher);
}

String _readPackageFile(String relativePath) {
  return File(
    path.join(_packageDirectory().path, relativePath),
  ).readAsStringSync();
}

Directory _packageDirectory() {
  final current = Directory.current;
  if (_isZcashFfiPackage(current)) {
    return current;
  }
  final monorepoNested = Directory(
    path.join(current.path, 'packages', 'zcash_ffi'),
  );
  if (_isZcashFfiPackage(monorepoNested)) {
    return monorepoNested;
  }
  fail('Unable to locate zcash_ffi package directory from ${current.path}');
}

bool _isZcashFfiPackage(Directory directory) {
  final pubspec = File(path.join(directory.path, 'pubspec.yaml'));
  if (!pubspec.existsSync()) {
    return false;
  }
  return pubspec.readAsStringSync().contains(
    RegExp(r'^name:\s*zcash_ffi\s*$', multiLine: true),
  );
}
