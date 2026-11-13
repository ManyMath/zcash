import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// One immutable Sapling proving-parameter artifact.
final class SaplingParameterArtifact {
  const SaplingParameterArtifact({
    required this.fileName,
    required this.expectedBytes,
    required this.sha256Hex,
  });

  final String fileName;
  final int expectedBytes;
  final String sha256Hex;
}

/// A versioned, cryptographically bound pair of Sapling parameters.
final class SaplingParameterManifest {
  const SaplingParameterManifest({
    required this.version,
    required this.spend,
    required this.output,
  });

  final String version;
  final SaplingParameterArtifact spend;
  final SaplingParameterArtifact output;
}

/// The official Sapling MPC parameter names, lengths, and SHA-256 digests.
///
/// The digests are published by the Zcash project's `zcutil/fetch-params.sh`
/// at the v5.6.0 tag. Exact lengths are also enforced to bound acquisition.
const officialSaplingParameterManifestV1 = SaplingParameterManifest(
  version: 'sapling-mpc-v1',
  spend: SaplingParameterArtifact(
    fileName: 'sapling-spend.params',
    expectedBytes: 47958396,
    sha256Hex:
        '8e48ffd23abb3a5fd9c5589204f32d9c31285a04b78096ba40a79b75677efc13',
  ),
  output: SaplingParameterArtifact(
    fileName: 'sapling-output.params',
    expectedBytes: 3592860,
    sha256Hex:
        '2f0ebbcbb9bb0bcffe95a397e7eba89c29eb4dde6191c339db88570e3f3fb0e4',
  ),
);

/// An injectable byte source for proving parameters.
///
/// Applications can implement this with their existing HTTP stack. The cache
/// owns verification and publishing; a source is never trusted by itself.
/// This package deliberately provides no default network source until the
/// application establishes both its distribution URL and artifact licensing
/// policy. Transport and redistribution remain application decisions.
abstract interface class SaplingParameterSource {
  Stream<List<int>> open(SaplingParameterArtifact artifact);
}

/// Copies a pre-provisioned local pair without following symbolic links.
final class FileSaplingParameterSource implements SaplingParameterSource {
  const FileSaplingParameterSource({
    required this.manifest,
    required this.spendFile,
    required this.outputFile,
  });

  final SaplingParameterManifest manifest;
  final File spendFile;
  final File outputFile;

  @override
  Stream<List<int>> open(SaplingParameterArtifact artifact) async* {
    final file = switch (artifact.fileName) {
      final name when name == manifest.spend.fileName => spendFile,
      final name when name == manifest.output.fileName => outputFile,
      _ => throw const SaplingParameterException(
        SaplingParameterFailure.invalidManifest,
        'the requested Sapling parameter is not in the local source pair',
      ),
    };
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.file) {
      throw const SaplingParameterException(
        SaplingParameterFailure.untrustedCacheEntry,
        'a local Sapling parameter source is not a regular file',
      );
    }
    yield* file.openRead();
  }
}

/// Explicit, verified parameter paths passed to native transaction builders.
final class SaplingProvingParameters {
  const SaplingProvingParameters._({
    required this.version,
    required this.spendParamsPath,
    required this.outputParamsPath,
  });

  final String version;
  final String spendParamsPath;
  final String outputParamsPath;
}

enum SaplingParameterFailure {
  unavailable,
  invalidManifest,
  untrustedCacheEntry,
  wrongSize,
  wrongHash,
  sourceInterrupted,
  requestTimedOut,
  totalTimedOut,
  publishFailed,
  storageFailure,
}

/// A path-redacting failure from parameter acquisition or verification.
final class SaplingParameterException implements Exception {
  const SaplingParameterException(this.failure, this.message);

  final SaplingParameterFailure failure;
  final String message;

  @override
  String toString() => 'SaplingParameterException: $message';
}

/// Installs and resolves a versioned, verified pair of Sapling parameters.
final class SaplingProvingParameterCache {
  SaplingProvingParameterCache({
    required this.cacheRoot,
    this.manifest = officialSaplingParameterManifestV1,
    this.requestTimeout = const Duration(seconds: 30),
    this.totalTimeout = const Duration(minutes: 10),
  });

  final Directory cacheRoot;
  final SaplingParameterManifest manifest;
  final Duration requestTimeout;
  final Duration totalTimeout;

  static final Map<
    String,
    ({String manifestIdentity, Future<SaplingProvingParameters> operation})
  >
  _inFlight = {};

  Future<SaplingProvingParameters> resolve({SaplingParameterSource? source}) {
    _validateManifest();
    final target = _targetDirectory();
    final key = p.absolute(target.path);
    final manifestIdentity = _manifestIdentity();
    final active = _inFlight[key];
    if (active != null) {
      if (active.manifestIdentity != manifestIdentity) {
        return Future.error(
          const SaplingParameterException(
            SaplingParameterFailure.invalidManifest,
            'a different Sapling parameter pair is already being installed '
            'for this cache version',
          ),
        );
      }
      return active.operation;
    }
    final acquisition = _resolveSanitized(target, source);
    late final Future<SaplingProvingParameters> operation;
    operation = acquisition.whenComplete(() {
      if (identical(_inFlight[key]?.operation, operation)) {
        _inFlight.remove(key);
      }
    });
    _inFlight[key] = (manifestIdentity: manifestIdentity, operation: operation);
    return operation;
  }

  Future<SaplingProvingParameters> _resolveSanitized(
    Directory target,
    SaplingParameterSource? source,
  ) async {
    try {
      return await _resolve(target, source);
    } on SaplingParameterException {
      rethrow;
    } catch (_) {
      throw const SaplingParameterException(
        SaplingParameterFailure.storageFailure,
        'Sapling parameter storage failed safely',
      );
    }
  }

  Future<SaplingProvingParameters> _resolve(
    Directory target,
    SaplingParameterSource? source,
  ) async {
    final deadline = DateTime.now().add(totalTimeout);
    final namespace = Directory(p.dirname(target.path));
    await _rejectUntrustedDirectoryIfPresent(cacheRoot);
    await _rejectUntrustedDirectoryIfPresent(namespace);
    final cached = await _verifiedPaths(target);
    if (cached != null) {
      return cached;
    }
    if (source == null) {
      throw const SaplingParameterException(
        SaplingParameterFailure.unavailable,
        'no verified Sapling proving-parameter pair is available offline',
      );
    }

    await _ensureTrustedDirectory(cacheRoot);
    await _ensureTrustedDirectory(namespace);
    final nonce = '$pid-${Random.secure().nextInt(1 << 32)}';
    final staging = Directory(p.join(namespace.path, '.params.tmp-$nonce'));
    await staging.create();
    try {
      await _copyAndVerify(source, manifest.spend, staging, deadline);
      await _copyAndVerify(source, manifest.output, staging, deadline);
      await _publish(staging, target, nonce);
      final installed = await _verifiedPaths(target);
      if (installed == null) {
        throw const SaplingParameterException(
          SaplingParameterFailure.publishFailed,
          'the published Sapling parameter pair could not be verified',
        );
      }
      return installed;
    } finally {
      if (await staging.exists()) {
        await staging.delete(recursive: true);
      }
    }
  }

  Future<void> _copyAndVerify(
    SaplingParameterSource source,
    SaplingParameterArtifact artifact,
    Directory staging,
    DateTime deadline,
  ) async {
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      throw const SaplingParameterException(
        SaplingParameterFailure.totalTimedOut,
        'Sapling parameter acquisition exceeded its total deadline',
      );
    }
    final destination = File(p.join(staging.path, artifact.fileName));
    final sink = destination.openSync(mode: FileMode.writeOnly);
    final completed = Completer<void>();
    StreamSubscription<List<int>>? subscription;
    Timer? inactivityTimer;
    Timer? totalTimer;
    var bytes = 0;
    var stopped = false;

    void stop({Object? error, StackTrace? stackTrace}) {
      if (stopped) {
        return;
      }
      stopped = true;
      inactivityTimer?.cancel();
      totalTimer?.cancel();
      final cancellation = subscription?.cancel();
      if (cancellation != null) {
        unawaited(cancellation.catchError((_) {}));
      }
      Object? completionError = error;
      try {
        sink.closeSync();
      } catch (_) {
        completionError ??= const SaplingParameterException(
          SaplingParameterFailure.storageFailure,
          'Sapling parameter storage failed safely',
        );
      }
      if (completionError == null) {
        completed.complete();
      } else {
        completed.completeError(
          completionError,
          stackTrace ?? StackTrace.current,
        );
      }
    }

    void startInactivityTimer() {
      inactivityTimer?.cancel();
      inactivityTimer = Timer(requestTimeout, () {
        stop(
          error: const SaplingParameterException(
            SaplingParameterFailure.requestTimedOut,
            'a Sapling parameter source stopped making progress',
          ),
        );
      });
    }

    totalTimer = Timer(remaining, () {
      stop(
        error: const SaplingParameterException(
          SaplingParameterFailure.totalTimedOut,
          'Sapling parameter acquisition exceeded its total deadline',
        ),
      );
    });
    startInactivityTimer();
    try {
      subscription = source
          .open(artifact)
          .listen(
            (chunk) {
              if (stopped) {
                return;
              }
              if (DateTime.now().isAfter(deadline)) {
                stop(
                  error: const SaplingParameterException(
                    SaplingParameterFailure.totalTimedOut,
                    'Sapling parameter acquisition exceeded its total deadline',
                  ),
                );
                return;
              }
              bytes += chunk.length;
              if (bytes > artifact.expectedBytes) {
                stop(
                  error: const SaplingParameterException(
                    SaplingParameterFailure.wrongSize,
                    'a Sapling parameter artifact exceeded its expected size',
                  ),
                );
                return;
              }
              try {
                sink.writeFromSync(chunk);
              } catch (error, stackTrace) {
                stop(error: error, stackTrace: stackTrace);
                return;
              }
              startInactivityTimer();
            },
            onError: (Object error, StackTrace stackTrace) {
              stop(
                error: error is SaplingParameterException
                    ? error
                    : const SaplingParameterException(
                        SaplingParameterFailure.sourceInterrupted,
                        'a Sapling parameter source was interrupted',
                      ),
                stackTrace: stackTrace,
              );
            },
            onDone: stop,
            cancelOnError: true,
          );
      await completed.future;
    } on SaplingParameterException {
      rethrow;
    } catch (_) {
      stop();
      throw const SaplingParameterException(
        SaplingParameterFailure.sourceInterrupted,
        'a Sapling parameter source was interrupted',
      );
    } finally {
      if (!stopped) {
        stop();
      }
    }
    if (bytes != artifact.expectedBytes) {
      throw const SaplingParameterException(
        SaplingParameterFailure.wrongSize,
        'a Sapling parameter artifact did not have its expected size',
      );
    }
    if (await _hash(destination) != artifact.sha256Hex) {
      throw const SaplingParameterException(
        SaplingParameterFailure.wrongHash,
        'a Sapling parameter artifact failed cryptographic verification',
      );
    }
  }

  Future<void> _publish(
    Directory staging,
    Directory target,
    String nonce,
  ) async {
    final type = await FileSystemEntity.type(target.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      await staging.rename(target.path);
      return;
    }
    if (type != FileSystemEntityType.directory) {
      throw const SaplingParameterException(
        SaplingParameterFailure.untrustedCacheEntry,
        'the Sapling parameter cache contains an untrusted entry',
      );
    }
    final quarantine = Directory('${target.path}.old-$nonce');
    await target.rename(quarantine.path);
    try {
      await staging.rename(target.path);
    } catch (_) {
      await quarantine.rename(target.path);
      throw const SaplingParameterException(
        SaplingParameterFailure.publishFailed,
        'the verified Sapling parameter pair could not be published',
      );
    }
    await quarantine.delete(recursive: true);
  }

  Future<SaplingProvingParameters?> _verifiedPaths(Directory directory) async {
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) {
      return null;
    }
    if (type != FileSystemEntityType.directory) {
      throw const SaplingParameterException(
        SaplingParameterFailure.untrustedCacheEntry,
        'the Sapling parameter cache contains an untrusted entry',
      );
    }
    final spend = File(p.join(directory.path, manifest.spend.fileName));
    final output = File(p.join(directory.path, manifest.output.fileName));
    if (!await _validFile(spend, manifest.spend) ||
        !await _validFile(output, manifest.output)) {
      return null;
    }
    return SaplingProvingParameters._(
      version: manifest.version,
      spendParamsPath: spend.path,
      outputParamsPath: output.path,
    );
  }

  Future<bool> _validFile(File file, SaplingParameterArtifact artifact) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return false;
    }
    if (type != FileSystemEntityType.file) {
      throw const SaplingParameterException(
        SaplingParameterFailure.untrustedCacheEntry,
        'the Sapling parameter cache contains an untrusted entry',
      );
    }
    final stat = await file.stat();
    return stat.size == artifact.expectedBytes &&
        await _hash(file) == artifact.sha256Hex;
  }

  Future<String> _hash(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  Future<void> _ensureTrustedDirectory(Directory directory) async {
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) {
      await directory.create(recursive: true);
      return;
    }
    if (type != FileSystemEntityType.directory) {
      throw const SaplingParameterException(
        SaplingParameterFailure.untrustedCacheEntry,
        'the Sapling parameter cache root is not a trusted directory',
      );
    }
  }

  Future<void> _rejectUntrustedDirectoryIfPresent(Directory directory) async {
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      throw const SaplingParameterException(
        SaplingParameterFailure.untrustedCacheEntry,
        'the Sapling parameter cache root is not a trusted directory',
      );
    }
  }

  Directory _targetDirectory() => Directory(
    p.join(cacheRoot.path, 'zcash-sapling-params', manifest.version),
  );

  String _manifestIdentity() =>
      '${manifest.version}:${manifest.spend.fileName}:'
      '${manifest.spend.expectedBytes}:${manifest.spend.sha256Hex}:'
      '${manifest.output.fileName}:${manifest.output.expectedBytes}:'
      '${manifest.output.sha256Hex}';

  void _validateManifest() {
    final artifacts = [manifest.spend, manifest.output];
    final valid =
        requestTimeout > Duration.zero &&
        totalTimeout > Duration.zero &&
        manifest.version.isNotEmpty &&
        p.basename(manifest.version) == manifest.version &&
        artifacts.every(
          (artifact) =>
              artifact.expectedBytes > 0 &&
              p.basename(artifact.fileName) == artifact.fileName &&
              RegExp(r'^[0-9a-f]{64}$').hasMatch(artifact.sha256Hex),
        ) &&
        manifest.spend.fileName != manifest.output.fileName;
    if (!valid) {
      throw const SaplingParameterException(
        SaplingParameterFailure.invalidManifest,
        'the Sapling parameter manifest is invalid',
      );
    }
  }
}
