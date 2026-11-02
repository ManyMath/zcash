import 'dart:io';

import 'package:path/path.dart' as path;

import 'rustup.dart';

({String rustTriple, String clangPrefix}) androidTarget(String architecture) =>
    switch (architecture) {
      'arm64' => (
        rustTriple: 'aarch64-linux-android',
        clangPrefix: 'aarch64-linux-android',
      ),
      'arm' => (
        rustTriple: 'armv7-linux-androideabi',
        clangPrefix: 'armv7a-linux-androideabi',
      ),
      'x64' => (
        rustTriple: 'x86_64-linux-android',
        clangPrefix: 'x86_64-linux-android',
      ),
      'ia32' => (
        rustTriple: 'i686-linux-android',
        clangPrefix: 'i686-linux-android',
      ),
      _ => throw ArgumentError.value(
        architecture,
        'architecture',
        'not an Android architecture zcash-ffi builds for',
      ),
    };

Map<String, String> androidCargoEnvironment({
  required String toolchainBin,
  required String rustTriple,
  required String clangPrefix,
  required int ndkApi,
}) {
  final wrapper = path.join(toolchainBin, '$clangPrefix$ndkApi-clang');
  final triple = rustTriple.replaceAll('-', '_');
  final tripleUpper = triple.toUpperCase();
  return {
    'CARGO_TARGET_${tripleUpper}_LINKER': wrapper,
    'CARGO_TARGET_${tripleUpper}_RUSTFLAGS':
        '-C link-arg=-Wl,-z,max-page-size=16384',
    'CC_$triple': wrapper,
    'CXX_$triple': '$wrapper++',
    'AR_$triple': path.join(toolchainBin, 'llvm-ar'),
    'RANLIB_$triple': path.join(toolchainBin, 'llvm-ranlib'),
  };
}

Future<String> buildAndroidLibrary({
  required String manifestDir,
  required String targetDir,
  required String architecture,
  required int ndkApi,
  required Uri? cCompiler,
  required bool release,
}) async {
  final target = androidTarget(architecture);
  final compiler = cCompiler;
  if (compiler == null) {
    throw StateError(
      'building zcash-ffi for Android needs the NDK toolchain, and the build '
      'hook was not given one (code config has no cCompiler)',
    );
  }
  final toolchainBin = File.fromUri(compiler).parent.path;

  await ensureRustTarget(target.rustTriple);

  final environment = androidCargoEnvironment(
    toolchainBin: toolchainBin,
    rustTriple: target.rustTriple,
    clangPrefix: target.clangPrefix,
    ndkApi: ndkApi,
  );
  final wrapper = path.join(toolchainBin, '${target.clangPrefix}$ndkApi-clang');
  if (!File(wrapper).existsSync()) {
    throw StateError(
      'the NDK has no clang wrapper for ${target.clangPrefix} at API $ndkApi '
      '($wrapper)',
    );
  }

  final result = await Process.run('cargo', [
    'build',
    '--lib',
    if (release) '--release',
    '--target',
    target.rustTriple,
    '--manifest-path',
    path.join(manifestDir, 'Cargo.toml'),
    '--target-dir',
    targetDir,
  ], environment: environment);
  if (result.exitCode != 0) {
    throw StateError(
      'cargo build for ${target.rustTriple} failed (${result.exitCode}):\n'
      '${result.stderr}',
    );
  }

  final library = path.join(
    targetDir,
    target.rustTriple,
    release ? 'release' : 'debug',
    'libzcash_ffi.so',
  );
  if (!File(library).existsSync()) {
    throw StateError('cargo build succeeded but $library does not exist');
  }
  return library;
}
