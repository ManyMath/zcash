import 'dart:io';

import 'package:path/path.dart' as path;

import '../production_native_profile.dart';
import 'rustup.dart';

String iosRustTriple(String architecture, {required bool simulator}) =>
    switch ((architecture, simulator)) {
      ('arm64', false) => 'aarch64-apple-ios',
      ('arm64', true) => 'aarch64-apple-ios-sim',
      ('x64', true) => 'x86_64-apple-ios',
      _ => throw ArgumentError.value(
        architecture,
        'architecture',
        'not an iOS ${simulator ? 'simulator' : 'device'} architecture '
            'zcash-ffi builds for',
      ),
    };

Map<String, String> iosCargoEnvironment({
  required String rustTriple,
  required int deploymentTarget,
}) {
  final tripleUpper = rustTriple.replaceAll('-', '_').toUpperCase();
  return {
    'IPHONEOS_DEPLOYMENT_TARGET': '$deploymentTarget.0',
    // rust-objcopy's strip leaves a mis-aligned LINKEDIT string table that
    // dyld (simulator included) refuses to load.
    'CARGO_PROFILE_RELEASE_STRIP': 'none',
    'CARGO_TARGET_${tripleUpper}_RUSTFLAGS':
        '-C link-arg=-Wl,-install_name,@rpath/libzcash_ffi.dylib',
  };
}

List<String> iosCargoBuildArguments({
  required String manifestDir,
  required String targetDir,
  required String rustTriple,
  required bool release,
}) => [
  'build',
  '--lib',
  ...productionWalletNativeFeatureProfile.cargoArguments,
  if (release) '--release',
  '--target',
  rustTriple,
  '--manifest-path',
  path.join(manifestDir, 'Cargo.toml'),
  '--target-dir',
  targetDir,
];

Future<String> buildIOSLibrary({
  required String manifestDir,
  required String targetDir,
  required String architecture,
  required bool simulator,
  required int deploymentTarget,
  required bool release,
}) async {
  final triple = iosRustTriple(architecture, simulator: simulator);

  await ensureRustTarget(triple);

  final result = await Process.run(
    'cargo',
    iosCargoBuildArguments(
      manifestDir: manifestDir,
      targetDir: targetDir,
      rustTriple: triple,
      release: release,
    ),
    environment: iosCargoEnvironment(
      rustTriple: triple,
      deploymentTarget: deploymentTarget,
    ),
  );
  if (result.exitCode != 0) {
    throw StateError(
      'cargo build for $triple failed (${result.exitCode}):\n'
      '${result.stderr}',
    );
  }

  final library = path.join(
    targetDir,
    triple,
    release ? 'release' : 'debug',
    'libzcash_ffi.dylib',
  );
  if (!File(library).existsSync()) {
    throw StateError('cargo build succeeded but $library does not exist');
  }
  return library;
}
