import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:path/path.dart' as path;

import 'package:zcash_flutter/src/hook/android_build.dart';
import 'package:zcash_flutter/src/hook/host_build.dart';
import 'package:zcash_flutter/src/hook/ios_build.dart';

const _assetName = 'src/ffi/zcash_native_assets.dart';
const _libraryName = 'zcash_ffi';

const zcashFfiManifestDirEnvVar = 'ZCASH_FFI_MANIFEST_DIR';

/// `release` (the default) or `debug`.
const zcashFfiCargoProfileEnvVar = 'ZCASH_FFI_CARGO_PROFILE';

String resolveZcashFfiManifestDir({
  required String packageRoot,
  Map<String, String>? environment,
}) {
  final selectedEnvironment = environment ?? Platform.environment;
  final override = selectedEnvironment[zcashFfiManifestDirEnvVar];

  if (override == null) {
    return validateZcashFfiManifestDir(
      path.join(packageRoot, 'native', 'zcash-ffi'),
    );
  }

  final trimmedOverride = override.trim();
  if (trimmedOverride.isEmpty) {
    throw StateError(
      'Invalid zcash-ffi manifest directory: $zcashFfiManifestDirEnvVar '
      'is empty; selected path is empty and Cargo.toml cannot be found. '
      'Set $zcashFfiManifestDirEnvVar to the zcash-ffi crate directory or '
      'unset it to use the default native/zcash-ffi crate.',
    );
  }

  final selectedPath = path.isAbsolute(trimmedOverride)
      ? trimmedOverride
      : path.join(packageRoot, trimmedOverride);
  return validateZcashFfiManifestDir(selectedPath);
}

String validateZcashFfiManifestDir(String manifestDir) {
  final selectedPath = path.normalize(manifestDir);
  final cargoToml = path.join(selectedPath, 'Cargo.toml');
  if (!File(cargoToml).existsSync()) {
    throw StateError(
      'Invalid zcash-ffi manifest directory: $zcashFfiManifestDirEnvVar '
      'selected "$selectedPath", but missing Cargo.toml at "$cargoToml". '
      'Set $zcashFfiManifestDirEnvVar to the zcash-ffi crate directory or '
      'unset it to use the default native/zcash-ffi crate.',
    );
  }
  return selectedPath;
}

/// Whether to pass `--release` to cargo, from [zcashFfiCargoProfileEnvVar].
bool releaseProfile({Map<String, String>? environment}) {
  final value =
      (environment ?? Platform.environment)[zcashFfiCargoProfileEnvVar]
          ?.trim()
          .toLowerCase();
  return switch (value) {
    null || '' || 'release' => true,
    'debug' => false,
    _ => throw StateError(
      'Invalid $zcashFfiCargoProfileEnvVar "$value": expected release or '
      'debug.',
    ),
  };
}

/// The crate files a rebuild depends on: everything under the manifest
/// directory except cargo's `target` output and dot directories.
List<File> crateFiles(String manifestDir) {
  final files = <File>[];
  void walk(Directory directory) {
    for (final entity in directory.listSync(followLinks: false)) {
      final name = path.basename(entity.path);
      if (name.startsWith('.')) continue;
      if (entity is File) {
        files.add(entity);
      } else if (entity is Directory && name != 'target') {
        walk(entity);
      }
    }
  }

  walk(Directory(manifestDir));
  files.sort((a, b) => a.path.compareTo(b.path));
  return files;
}

void main(List<String> args) async {
  await build(args, (input, output) async {
    final targetOS = input.config.code.targetOS;
    final arch = input.config.code.targetArchitecture.toString();

    final manifestDir = resolveZcashFfiManifestDir(
      packageRoot: input.packageRoot.toFilePath(),
    );
    final fileName = targetOS.dylibFileName(_libraryName);

    for (final file in crateFiles(manifestDir)) {
      output.dependencies.add(Uri.file(file.path));
    }

    if (!input.config.buildCodeAssets) {
      output.assets.code.add(
        CodeAsset(
          package: input.packageName,
          name: _assetName,
          linkMode: DynamicLoadingBundled(),
        ),
      );
      return;
    }

    final release = releaseProfile();
    final targetTempDir = path.join(
      input.outputDirectoryShared.toFilePath(),
      'zcash_ffi_rust_build',
    );
    Directory(targetTempDir).createSync(recursive: true);

    final String library;
    try {
      if (targetOS == OS.android) {
        library = await buildAndroidLibrary(
          manifestDir: manifestDir,
          targetDir: targetTempDir,
          architecture: arch,
          ndkApi: input.config.code.android.targetNdkApi,
          cCompiler: input.config.code.cCompiler?.compiler,
          release: release,
        );
      } else if (targetOS == OS.iOS) {
        library = await buildIOSLibrary(
          manifestDir: manifestDir,
          targetDir: targetTempDir,
          architecture: arch,
          simulator: input.config.code.iOS.targetSdk == IOSSdk.iPhoneSimulator,
          deploymentTarget: input.config.code.iOS.targetVersion,
          release: release,
        );
      } else {
        library = await buildHostLibrary(
          manifestDir: manifestDir,
          targetDir: targetTempDir,
          rustTriple: hostRustTriple(targetOS.toString(), arch),
          libraryFileName: fileName,
          release: release,
        );
      }
    } on ProcessException catch (e) {
      throw StateError(
        'Could not run ${e.executable}: ${e.message}. Install rustup from '
        'https://rustup.rs and make sure cargo, rustc and rustup are on PATH.',
      );
    }

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: _assetName,
        linkMode: DynamicLoadingBundled(),
        file: Uri.file(library),
      ),
    );
  });
}
