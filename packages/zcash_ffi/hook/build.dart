import 'dart:io';

import 'package:build_tool/src/artifacts_provider.dart';
import 'package:build_tool/src/builder.dart';
import 'package:build_tool/src/cargo.dart';
import 'package:build_tool/src/crate_hash.dart';
import 'package:build_tool/src/logging.dart';
import 'package:build_tool/src/options.dart';
import 'package:build_tool/src/target.dart';
import 'package:build_tool/src/util.dart';
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:path/path.dart' as path;

import 'android_build.dart';
import 'ios_build.dart';

const _assetName = 'src/ffi/zcash_native_assets.dart';

const zcashFfiManifestDirEnvVar = 'ZCASH_FFI_MANIFEST_DIR';

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

void main(List<String> args) async {
  await build(args, (input, output) async {
    final os = input.config.code.targetOS.toString();
    final arch = input.config.code.targetArchitecture.toString();
    final isAndroid = input.config.code.targetOS == OS.android;
    final isIOS = input.config.code.targetOS == OS.iOS;
    final target = isAndroid || isIOS ? null : Target.forCodeAssets(os, arch);

    final manifestDir = resolveZcashFfiManifestDir(
      packageRoot: input.packageRoot.toFilePath(),
    );
    final crateInfo = CrateInfo.load(manifestDir);
    final fileName = input.config.code.targetOS.dylibFileName(
      crateInfo.libraryName,
    );

    for (final file in CrateHash.enumerateFiles(manifestDir)) {
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

    final configStr =
        Platform.environment['CARGOKIT_CONFIGURATION'] ?? 'release';
    final configuration = BuildEnvironment.parseBuildConfiguration(configStr);

    final verbose = Platform.environment['CARGOKIT_VERBOSE'] == '1';
    if (verbose) {
      initLogging();
      enableVerboseLogging();
    }

    final userOptions = CargokitUserOptions(
      usePrecompiledBinaries:
          CargokitUserOptions.defaultUsePrecompiledBinaries(),
      verboseLogging: verbose,
      useLocalPrecompiledBinaries: false,
      cacheLocalBuilds: false,
    );

    final targetTempDir = path.join(
      input.outputDirectoryShared.toFilePath(),
      'zcash_ffi_rust_build',
    );
    Directory(targetTempDir).createSync(recursive: true);

    if (isAndroid) {
      final library = await buildAndroidLibrary(
        manifestDir: manifestDir,
        targetDir: targetTempDir,
        architecture: arch,
        ndkApi: input.config.code.android.targetNdkApi,
        cCompiler: input.config.code.cCompiler?.compiler,
        release: configuration != BuildConfiguration.debug,
      );
      output.assets.code.add(
        CodeAsset(
          package: input.packageName,
          name: _assetName,
          linkMode: DynamicLoadingBundled(),
          file: Uri.file(library),
        ),
      );
      return;
    }

    if (isIOS) {
      final library = await buildIOSLibrary(
        manifestDir: manifestDir,
        targetDir: targetTempDir,
        architecture: arch,
        simulator: input.config.code.iOS.targetSdk == IOSSdk.iPhoneSimulator,
        deploymentTarget: input.config.code.iOS.targetVersion,
        release: configuration != BuildConfiguration.debug,
      );
      output.assets.code.add(
        CodeAsset(
          package: input.packageName,
          name: _assetName,
          linkMode: DynamicLoadingBundled(),
          file: Uri.file(library),
        ),
      );
      return;
    }

    final environment = BuildEnvironment.fromBuildInput(
      configuration: configuration,
      manifestDir: manifestDir,
      targetTempDir: targetTempDir,
    );

    try {
      final provider = ArtifactProvider(
        environment: environment,
        userOptions: userOptions,
      );
      final artifactMap = await provider.getArtifacts([target!]);
      final artifacts = artifactMap[target] ?? [];
      final dylib = artifacts.firstWhere(
        (artifact) => artifact.finalFileName == fileName,
        orElse: () => throw StateError(
          'Build completed but expected artifact $fileName was not found. '
          'Found: ${artifacts.map((a) => a.finalFileName).join(", ")}',
        ),
      );

      output.assets.code.add(
        CodeAsset(
          package: input.packageName,
          name: _assetName,
          linkMode: DynamicLoadingBundled(),
          file: Uri.file(dylib.path),
        ),
      );
    } on RustupNotFoundException {
      throw StateError(
        'Rust toolchain not found. Install rustup from https://rustup.rs '
        'and ensure rustup is available on PATH.',
      );
    }
  });
}
