@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

Directory _resolveLibDir() {
  final candidates = <String>['lib', 'packages/zcash/lib'];
  for (final c in candidates) {
    final d = Directory(c);
    if (d.existsSync()) return d;
  }
  fail(
    'could not locate the zcash package lib/ directory from '
    '${Directory.current.path}',
  );
}

File _resolvePubspec() {
  final candidates = <String>['pubspec.yaml', 'packages/zcash/pubspec.yaml'];
  for (final c in candidates) {
    final f = File(c);
    if (f.existsSync()) return f;
  }
  fail(
    'could not locate the zcash package pubspec.yaml from '
    '${Directory.current.path}',
  );
}

void main() {
  group('pure Dart boundary', () {
    final forbiddenImportPatterns = <RegExp>[
      RegExp(r'''import\s+['"]dart:ffi['"]'''),
      RegExp(r'''import\s+['"]dart:cli['"]'''),
      RegExp(r'''import\s+['"]package:ffi/'''),
      RegExp(r'''import\s+['"]package:native_assets'''),
      RegExp(r'''import\s+['"]package:cargokit'''),
    ];

    test('no lib/ source imports a native dependency', () {
      final libDir = _resolveLibDir();
      final offenders = <String>[];

      for (final entity in libDir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final contents = entity.readAsStringSync();
        for (final pattern in forbiddenImportPatterns) {
          if (pattern.hasMatch(contents)) {
            offenders.add('${entity.path}: matched ${pattern.pattern}');
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            'the pure zcash package must not import native code. '
            'Move native-backed behavior to zcash_ffi. Offenders:\n'
            '${offenders.join('\n')}',
      );
    });

    test('pubspec declares no native dependency', () {
      final pubspec = _resolvePubspec().readAsStringSync();
      final body = pubspec
          .split('\n')
          .map((line) {
            final hash = line.indexOf('#');
            return hash >= 0 ? line.substring(0, hash) : line;
          })
          .join('\n');

      for (final dep in const <String>[
        'ffi:',
        'cargokit',
        'native_assets_cli',
        'native_assets_builder',
        'native_toolchain_c',
      ]) {
        expect(
          body.contains(dep),
          isFalse,
          reason: 'the pure zcash pubspec must not depend on "$dep"',
        );
      }
    });
  });

  group('public API smoke test', () {
    test('core model types are exported and resolvable', () {
      final types = <Type>[
        ZcashAddressMetadata,
        ZcashAddressReceiverPresence,
        ZcashKeyType,
        ZcashKeyValidation,
        ZcashScanResult,
        ZcashScannedNote,
        ZcashScanBlockDiagnostic,
        ZcashObservedSpend,
        ZcashWatchedNullifiers,
        IronwoodNoteSet,
        TrackedIronwoodNote,
        IronwoodInputSelection,
        IronwoodFeeQuote,
        IronwoodSendPlan,
        IronwoodPreparedSend,
        IronwoodBroadcastReceipt,
        NativeCapability,
        CapabilityStatus,
        ZcashTransactionSummary,
        ZcashTransactionId,
        ProposalRequest,
        ProposalRecipient,
        TransparentBuildResult,
        SaplingBuildResult,
        SaplingFeeQuote,
        SaplingNoteSet,
        TrackedSaplingNote,
        SaplingInputSelection,
        SaplingSendPlan,
        SaplingPreparedSend,
        SaplingBroadcastReceipt,
        OrchardNoteSet,
        TrackedOrchardNote,
        ZcashAccountBalance,
        TransparentCoinSet,
        TrackedTransparentCoin,
        TransparentInputSelection,
        SaplingNoteStore,
        OrchardNoteStore,
        IronwoodNoteStore,
        ZcashNoteMemo,
        ZcashMemoPool,
      ];

      for (final t in types) {
        expect(t, isNotNull);
      }
      expect(
        types.toSet().length,
        types.length,
        reason: 'public type list should have no duplicates',
      );
    });

    test(
      'capability statuses use stable enum names matching native contract',
      () {
        final names = CapabilityStatus.values.map((v) => v.name).toSet();
        expect(
          names,
          containsAll(<String>[
            'supported',
            'unsupported',
            'parsedOnly',
            'experimental',
          ]),
        );
      },
    );
  });
}
