import 'dart:io';

import 'package:path/path.dart' as path;

import 'rustup.dart';

/// Maps a code-assets OS and architecture to the Rust target triple for a
/// desktop build.
String hostRustTriple(String os, String architecture) =>
    switch ((os, architecture)) {
      ('linux', 'x64') => 'x86_64-unknown-linux-gnu',
      ('linux', 'arm64') => 'aarch64-unknown-linux-gnu',
      ('linux', 'riscv64') => 'riscv64gc-unknown-linux-gnu',
      ('macos', 'x64') => 'x86_64-apple-darwin',
      ('macos', 'arm64') => 'aarch64-apple-darwin',
      ('windows', 'x64') => 'x86_64-pc-windows-msvc',
      ('windows', 'arm64') => 'aarch64-pc-windows-msvc',
      _ => throw ArgumentError.value(
        '$os/$architecture',
        'target',
        'not a desktop target zcash-ffi builds for',
      ),
    };

/// The triple rustc was built for, from `rustc -vV`.
Future<String> rustcHostTriple() async {
  final result = await Process.run('rustc', ['-vV']);
  if (result.exitCode != 0) {
    throw StateError('rustc -vV failed (${result.exitCode}): ${result.stderr}');
  }
  const prefix = 'host: ';
  final line = (result.stdout as String)
      .split('\n')
      .map((line) => line.trim())
      .firstWhere(
        (line) => line.startsWith(prefix),
        orElse: () =>
            throw StateError('rustc -vV did not report a host triple'),
      );
  return line.substring(prefix.length).trim();
}

/// Where cargo leaves the library for [rustTriple], relative to the target
/// directory. A host build has no triple component.
String hostLibraryPath({
  required String targetDir,
  required String rustTriple,
  required String hostTriple,
  required String libraryFileName,
  required bool release,
}) => path.joinAll([
  targetDir,
  if (rustTriple != hostTriple) rustTriple,
  release ? 'release' : 'debug',
  libraryFileName,
]);

Future<String> buildHostLibrary({
  required String manifestDir,
  required String targetDir,
  required String rustTriple,
  required String libraryFileName,
  required bool release,
}) async {
  final hostTriple = await rustcHostTriple();
  final cross = rustTriple != hostTriple;
  if (cross) {
    await ensureRustTarget(rustTriple);
  }

  final result = await Process.run('cargo', [
    'build',
    '--lib',
    if (release) '--release',
    if (cross) ...['--target', rustTriple],
    '--manifest-path',
    path.join(manifestDir, 'Cargo.toml'),
    '--target-dir',
    targetDir,
  ]);
  if (result.exitCode != 0) {
    throw StateError(
      'cargo build for $rustTriple failed (${result.exitCode}):\n'
      '${result.stderr}',
    );
  }

  final library = hostLibraryPath(
    targetDir: targetDir,
    rustTriple: rustTriple,
    hostTriple: hostTriple,
    libraryFileName: libraryFileName,
    release: release,
  );
  if (!File(library).existsSync()) {
    throw StateError('cargo build succeeded but $library does not exist');
  }
  return library;
}
