@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';
import 'package:zcash_flutter/zcash_flutter.dart';

const _ffiSeed =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'
    '202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f';

const _secretUfvk = 'uviewtest-secret-that-must-not-leak';

bool get _libAvailable =>
    (Platform.environment['ZCASH_FFI_LIB'] ?? '').isNotEmpty;

void main() {
  group('scan model parsing', () {
    test(
      'encodes multiple CompactBlock entries with per-block height metadata',
      () {
        final firstBlock = CompactBlock()
          ..height = Int64(42)
          ..protoVersion = 1;
        final secondBlock = CompactBlock()
          ..height = Int64(43)
          ..protoVersion = 2;
        final inputs = [
          CompactBlockScanInput.fromBytes(
            firstBlock.writeToBuffer(),
            height: 42,
          ),
          CompactBlockScanInput.fromBytes(
            secondBlock.writeToBuffer(),
            height: 43,
          ),
        ];

        final payload =
            jsonDecode(encodeCompactBlocksForScan(inputs))
                as Map<String, dynamic>;
        final blocks = payload['blocks'] as List<dynamic>;

        expect(blocks, hasLength(2));
        expect(
          blocks,
          everyElement(
            isA<Map<String, dynamic>>()
                .having(
                  (block) => block.keys,
                  'keys',
                  unorderedEquals(['data', 'height']),
                )
                .having((block) => block['data'], 'data', isA<String>()),
          ),
        );
        expect(blocks[0], {
          'height': 42,
          'data': base64Encode(firstBlock.writeToBuffer()),
        });
        expect(blocks[1], {
          'height': 43,
          'data': base64Encode(secondBlock.writeToBuffer()),
        });
      },
    );

    test('versioned envelope emits version, network, and range', () {
      final block = CompactBlock()
        ..height = Int64(50)
        ..protoVersion = 1;
      final payload =
          jsonDecode(
                encodeVersionedCompactBlocksForScan(
                  blocks: [
                    CompactBlockScanInput.fromBytes(
                      block.writeToBuffer(),
                      height: 50,
                    ),
                  ],
                  network: 'regtest',
                  range: const CompactBlockScanRange(start: 50, end: 60),
                ),
              )
              as Map<String, dynamic>;

      expect(payload['scan_input_version'], ScanInputEnvelope.version);
      expect(payload['network'], 'regtest');
      expect(payload['range'], {'start': 50, 'end': 60});
      expect((payload['blocks'] as List<dynamic>), hasLength(1));
    });

    test('versioned envelope omits optional fields when absent', () {
      final payload =
          jsonDecode(encodeVersionedCompactBlocksForScan(blocks: const []))
              as Map<String, dynamic>;
      expect(payload['scan_input_version'], 1);
      expect(payload.containsKey('network'), isFalse);
      expect(payload.containsKey('range'), isFalse);
      expect(payload['blocks'], isEmpty);
    });

    test('CompactBlockScanRange rejects inverted ranges', () {
      expect(
        () => CompactBlockScanRange(start: 10, end: 5),
        throwsA(isA<AssertionError>()),
      );
    });

    test('parses discovered notes and totals', () {
      final result = ZcashScanResult.fromRawJson(
        jsonEncode({
          'scanned_blocks': 2,
          'discovered_notes': 1,
          'total_value': 70000,
          'notes': [
            {
              'height': 123,
              'tx': 'abcd',
              'output': 0,
              'value': 70000,
              'pool': 'sapling',
            },
          ],
        }),
      );

      expect(result.scannedBlocks, 2);
      expect(result.discoveredNotes, 1);
      expect(result.totalValue, 70000);
      expect(result.notes.single.height, 123);
      expect(result.notes.single.tx, 'abcd');
      expect(result.notes.single.output, 0);
      expect(result.notes.single.value, 70000);
      expect(result.notes.single.pool, 'sapling');
      expect(result.notes.single.nullifier, isNull);
      expect(result.notes.single.commitmentPosition, isNull);
      expect(result.notes.single.isChange, isNull);
    });

    test('parses spend-observation metadata on discovered notes', () {
      final result = ZcashScanResult.fromRawJson(
        jsonEncode({
          'scanned_blocks': 1,
          'discovered_notes': 1,
          'total_value': 70000,
          'notes': [
            {
              'height': 123,
              'tx': 'abcd',
              'output': 0,
              'value': 70000,
              'pool': 'sapling',
              'nullifier': 'aa' * 32,
              'commitment_position': 7,
              'is_change': true,
            },
          ],
        }),
      );

      final note = result.notes.single;
      expect(note.nullifier, 'aa' * 32);
      expect(note.commitmentPosition, 7);
      expect(note.isChange, isTrue);
    });

    test('accepts notes whose nullifier is explicitly null', () {
      final result = ZcashScanResult.fromRawJson(
        jsonEncode({
          'scanned_blocks': 1,
          'discovered_notes': 1,
          'total_value': 1,
          'notes': [
            {
              'height': 1,
              'tx': 'abcd',
              'output': 0,
              'value': 1,
              'pool': 'sapling',
              'nullifier': null,
              'commitment_position': 0,
              'is_change': false,
            },
          ],
        }),
      );

      final note = result.notes.single;
      expect(note.nullifier, isNull);
      expect(note.commitmentPosition, 0);
      expect(note.isChange, isFalse);
    });

    test('rejects malformed nullifier metadata without echoing it', () {
      const badNullifier = 'zz-not-hex-$_secretUfvk';
      expect(
        () => ZcashScanResult.fromRawJson(
          jsonEncode({
            'scanned_blocks': 1,
            'discovered_notes': 1,
            'total_value': 1,
            'notes': [
              {
                'height': 1,
                'tx': 'abcd',
                'output': 0,
                'value': 1,
                'pool': 'sapling',
                'nullifier': badNullifier,
              },
            ],
          }),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('malformed hex field "nullifier"'),
              isNot(contains(badNullifier)),
              isNot(contains(_secretUfvk)),
            ),
          ),
        ),
      );
    });

    test('rejects non-string nullifier metadata', () {
      expect(
        () => ZcashScanResult.fromRawJson(
          jsonEncode({
            'scanned_blocks': 1,
            'discovered_notes': 1,
            'total_value': 1,
            'notes': [
              {
                'height': 1,
                'tx': 'abcd',
                'output': 0,
                'value': 1,
                'pool': 'sapling',
                'nullifier': 1234,
              },
            ],
          }),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('invalid hex field "nullifier"'),
          ),
        ),
      );
    });

    test('rejects non-Sapling note pools without echoing pool contents', () {
      for (final pool in ['orchard', 'transparent', _secretUfvk]) {
        expect(
          () => ZcashScanResult.fromRawJson(
            jsonEncode({
              'scanned_blocks': 1,
              'discovered_notes': 1,
              'total_value': 1,
              'notes': [
                {
                  'height': 123,
                  'tx': 'abcd',
                  'output': 0,
                  'value': 1,
                  'pool': pool,
                },
              ],
            }),
            redactSensitive: [_secretUfvk],
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('unsupported scanner note pool'),
                contains('expected "sapling"'),
                isNot(contains(pool)),
                isNot(contains(_secretUfvk)),
              ),
            ),
          ),
          reason: 'pool=$pool must fail closed without leaking values',
        );
      }
    });

    test('rejects discovered notes missing a pool', () {
      expect(
        () => ZcashScanResult.fromRawJson(
          jsonEncode({
            'scanned_blocks': 1,
            'discovered_notes': 1,
            'total_value': 1,
            'notes': [
              {'height': 123, 'tx': 'abcd', 'output': 0, 'value': 1},
            ],
          }),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('missing non-empty string field "pool"'),
          ),
        ),
      );
    });

    test('parses larger Sapling note results in memory', () {
      final notes = List.generate(
        100,
        (index) => {
          'height': 1000 + index,
          'tx': 'tx$index',
          'output': index,
          'value': 10,
          'pool': 'sapling',
        },
      );

      final result = ZcashScanResult.fromRawJson(
        jsonEncode({
          'scanned_blocks': 10,
          'discovered_notes': notes.length,
          'total_value': 1000,
          'notes': notes,
        }),
      );

      expect(result.notes, hasLength(notes.length));
      expect(result.notes.first.pool, 'sapling');
      expect(result.notes.last.height, 1099);
      expect(result.totalValue, 1000);
    });

    test('parses zero-note scans', () {
      final result = ZcashScanResult.fromRawJson(
        '{"scanned_blocks":0,"discovered_notes":0,"total_value":0,"notes":[]}',
      );

      expect(result.scannedBlocks, 0);
      expect(result.discoveredNotes, 0);
      expect(result.totalValue, 0);
      expect(result.notes, isEmpty);
    });

    test('parses scan progress diagnostics', () {
      final result = ZcashScanResult.fromRawJson(
        jsonEncode({
          'scanned_blocks': 2,
          'discovered_notes': 1,
          'total_value': 70000,
          'notes': [
            {
              'height': 101,
              'tx': 'abcd',
              'output': 0,
              'value': 70000,
              'pool': 'sapling',
            },
          ],
          'scanned_height_range': {'start': 100, 'end': 101},
          'ordered_blocks': 2,
          'diagnostics': [
            {'block_index': 0, 'height': 100, 'category': 'empty', 'notes': 0},
            {
              'block_index': 1,
              'height': 101,
              'category': 'notes_found',
              'notes': 1,
            },
          ],
        }),
      );

      expect(result.orderedBlocks, 2);
      expect(result.scannedHeightRange?.start, 100);
      expect(result.scannedHeightRange?.end, 101);
      expect(result.diagnostics, hasLength(2));
      expect(result.diagnostics.first.blockIndex, 0);
      expect(result.diagnostics.first.height, 100);
      expect(result.diagnostics.first.category, 'empty');
      expect(result.diagnostics.first.notes, 0);
      expect(result.diagnostics.last.category, 'notes_found');
      expect(result.diagnostics.last.notes, 1);
      expect(result.orchardActions, isNull);
      expect(result.diagnostics.first.orchardActions, isNull);
      expect(result.diagnostics.first.orchardCommitmentTreeSize, isNull);
    });

    test('parses parsed-only Orchard scan diagnostics', () {
      final result = ZcashScanResult.fromRawJson(
        jsonEncode({
          'scanned_blocks': 2,
          'discovered_notes': 1,
          'total_value': 9000,
          'notes': [
            {
              'height': 2,
              'tx': 'abcd',
              'output': 0,
              'value': 9000,
              'pool': 'sapling',
            },
          ],
          'ordered_blocks': 2,
          'orchard_actions': 3,
          'diagnostics': [
            {
              'block_index': 0,
              'height': 1,
              'category': 'empty',
              'notes': 0,
              'orchard_actions': 0,
              'orchard_commitment_tree_size': 0,
            },
            {
              'block_index': 1,
              'height': 2,
              'category': 'notes_found',
              'notes': 1,
              'orchard_actions': 3,
              'orchard_commitment_tree_size': 5,
            },
          ],
        }),
      );

      expect(result.orchardActions, 3);
      expect(result.discoveredNotes, 1);
      expect(result.notes.single.pool, 'sapling');
      expect(result.diagnostics.first.orchardActions, 0);
      expect(result.diagnostics.first.orchardCommitmentTreeSize, 0);
      expect(result.diagnostics.last.orchardActions, 3);
      expect(result.diagnostics.last.orchardCommitmentTreeSize, 5);
    });

    test('accepts Orchard diagnostics with null commitment tree size', () {
      final result = ZcashScanResult.fromRawJson(
        jsonEncode({
          'scanned_blocks': 1,
          'discovered_notes': 0,
          'total_value': 0,
          'notes': [],
          'orchard_actions': 0,
          'diagnostics': [
            {
              'block_index': 0,
              'height': 1,
              'category': 'empty',
              'notes': 0,
              'orchard_actions': 0,
              'orchard_commitment_tree_size': null,
            },
          ],
        }),
      );

      expect(result.diagnostics.single.orchardActions, 0);
      expect(result.diagnostics.single.orchardCommitmentTreeSize, isNull);
    });

    test(
      'parses zero-note scans with null height range and no diagnostics',
      () {
        final result = ZcashScanResult.fromRawJson(
          jsonEncode({
            'scanned_blocks': 0,
            'discovered_notes': 0,
            'total_value': 0,
            'notes': [],
            'scanned_height_range': null,
            'ordered_blocks': 0,
            'diagnostics': [],
          }),
        );

        expect(result.scannedHeightRange, isNull);
        expect(result.orderedBlocks, 0);
        expect(result.diagnostics, isEmpty);
      },
    );

    test('tolerates legacy summaries without diagnostics fields', () {
      final result = ZcashScanResult.fromRawJson(
        '{"scanned_blocks":1,"discovered_notes":0,"total_value":0,"notes":[]}',
      );

      expect(result.scannedHeightRange, isNull);
      expect(result.orderedBlocks, isNull);
      expect(result.diagnostics, isEmpty);
    });

    test('rejects malformed diagnostics entries by field name', () {
      expect(
        () => ZcashScanResult.fromRawJson(
          jsonEncode({
            'scanned_blocks': 1,
            'discovered_notes': 0,
            'total_value': 0,
            'notes': [],
            'diagnostics': [
              {'block_index': 0, 'height': 100, 'category': 'empty'},
            ],
          }),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('missing integer field "notes"'),
          ),
        ),
      );
    });

    test('converts scanner JSON errors to sanitized StateError', () {
      expect(
        () => ZcashScanResult.fromRawJson(
          jsonEncode({
            'error': 'invalid UFVK $_secretUfvk',
            'category': 'invalid_ufvk',
            'block_index': 3,
            'height': 99,
          }),
          redactSensitive: [_secretUfvk],
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('invalid_ufvk'),
              contains('block_index=3'),
              contains('height=99'),
              isNot(contains(_secretUfvk)),
              contains('<redacted>'),
            ),
          ),
        ),
      );
    });

    test('names malformed and missing fields without dumping payloads', () {
      expect(
        () => ZcashScanResult.fromRawJson('not-json'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('malformed JSON'), isNot(contains('not-json'))),
          ),
        ),
      );
      expect(
        () => ZcashScanResult.fromRawJson('{"scanned_blocks":0}'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('missing integer field "discovered_notes"'),
          ),
        ),
      );
      expect(
        () => ZcashScanResult.fromRawJson(
          '{"scanned_blocks":0,"discovered_notes":0,"total_value":0,"notes":"bad"}',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('missing list field "notes"'),
          ),
        ),
      );
    });
  });

  group(
    'DynamicLibrary scan wrapper',
    skip: _libAvailable ? false : 'ZCASH_FFI_LIB not set',
    () {
      test('empty block list returns zero-note summary', () {
        final ufvkJson =
            jsonDecode(
                  ZcashFfiBindings.instance.seedToAccountUfvk(
                    _ffiSeed,
                    'regtest',
                    0,
                  ),
                )
                as Map<String, dynamic>;
        final ufvk = ufvkJson['ufvk'] as String;

        final result = scanCompactBlocks(
          ufvk: ufvk,
          network: 'regtest',
          blocks: const [],
        );

        expect(result.scannedBlocks, 0);
        expect(result.discoveredNotes, 0);
        expect(result.totalValue, 0);
        expect(result.notes, isEmpty);
        expect(result.scannedHeightRange, isNull);
        expect(result.orderedBlocks, 0);
        expect(result.diagnostics, isEmpty);
        expect(result.saplingAnchor, isNull);
      });

      test('witness export request fails closed in the default build', () {
        final ufvkJson =
            jsonDecode(
                  ZcashFfiBindings.instance.seedToAccountUfvk(
                    _ffiSeed,
                    'regtest',
                    0,
                  ),
                )
                as Map<String, dynamic>;
        final ufvk = ufvkJson['ufvk'] as String;

        expect(
          () => scanCompactBlocks(
            ufvk: ufvk,
            network: 'regtest',
            blocks: const [],
            includeSaplingWitnesses: true,
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('witness_export_unavailable'),
            ),
          ),
        );
      });

      test('unsupported network and malformed UFVK errors are sanitized', () {
        expect(
          () => scanCompactBlocks(
            ufvk: _secretUfvk,
            network: 'not-a-network',
            blocks: const [],
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('unsupported_network'),
                isNot(contains(_secretUfvk)),
              ),
            ),
          ),
        );
        expect(
          () => scanCompactBlocks(
            ufvk: _secretUfvk,
            network: 'regtest',
            blocks: const [],
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains('invalid_ufvk'), isNot(contains(_secretUfvk))),
            ),
          ),
        );
      });

      test('rejects blocks whose height falls outside the declared range', () {
        final ufvkJson =
            jsonDecode(
                  ZcashFfiBindings.instance.seedToAccountUfvk(
                    _ffiSeed,
                    'regtest',
                    0,
                  ),
                )
                as Map<String, dynamic>;
        final ufvk = ufvkJson['ufvk'] as String;

        expect(
          () => scanCompactBlocks(
            ufvk: ufvk,
            network: 'regtest',
            range: const CompactBlockScanRange(start: 0, end: 10),
            blocks: [
              CompactBlockScanInput.fromBytes(
                Uint8List.fromList([1, 2, 3]),
                height: 77,
              ),
            ],
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains('height_out_of_range'), contains('height=77')),
            ),
          ),
        );
      });

      test('invalid compact block bytes include safe block context', () {
        final ufvkJson =
            jsonDecode(
                  ZcashFfiBindings.instance.seedToAccountUfvk(
                    _ffiSeed,
                    'regtest',
                    0,
                  ),
                )
                as Map<String, dynamic>;
        final ufvk = ufvkJson['ufvk'] as String;

        expect(
          () => scanCompactBlocks(
            ufvk: ufvk,
            network: 'regtest',
            blocks: [
              CompactBlockScanInput.fromBytes(
                Uint8List.fromList([1, 2, 3]),
                height: 77,
              ),
            ],
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains('invalid_protobuf'), contains('height=77')),
            ),
          ),
        );
      });

      test('reports a watched nullifier spent, in its own pool only', () {
        final ufvkJson =
            jsonDecode(
                  ZcashFfiBindings.instance.seedToAccountUfvk(
                    _ffiSeed,
                    'regtest',
                    0,
                  ),
                )
                as Map<String, dynamic>;
        final ufvk = ufvkJson['ufvk'] as String;

        final nullifier = List<int>.filled(32, 0x11);
        final nullifierHex = '11' * 32;
        final txid = List<int>.filled(32, 0xab);
        final block = CompactBlock()
          ..height = Int64(1)
          ..hash = List<int>.filled(32, 0x01)
          ..prevHash = List<int>.filled(32, 0x00)
          ..chainMetadata = (ChainMetadata()..ironwoodCommitmentTreeSize = 1)
          ..vtx.add(
            CompactTx()
              ..index = Int64(0)
              ..txid = txid
              ..ironwoodActions.add(
                CompactOrchardAction()
                  ..nullifier = nullifier
                  ..cmx = List<int>.filled(32, 0)
                  ..ephemeralKey = List<int>.filled(32, 0)
                  ..ciphertext = List<int>.filled(52, 0),
              ),
          );
        final blocks = [
          CompactBlockScanInput.fromBytes(block.writeToBuffer(), height: 1),
        ];

        final observed = scanCompactBlocks(
          ufvk: ufvk,
          network: 'regtest',
          blocks: blocks,
          watchedNullifiers: ZcashWatchedNullifiers(ironwood: [nullifierHex]),
        );

        expect(observed.spends, hasLength(1));
        expect(observed.spends.single.pool, 'ironwood');
        expect(observed.spends.single.nullifier, nullifierHex);
        expect(observed.spends.single.height, 1);
        expect(observed.spends.single.index, 0);
        expect(observed.spends.single.tx, 'ab' * 32);
        expect(observed.spends.single.noteIndex, isNull);

        final crossed = scanCompactBlocks(
          ufvk: ufvk,
          network: 'regtest',
          blocks: blocks,
          watchedNullifiers: ZcashWatchedNullifiers(orchard: [nullifierHex]),
        );
        expect(crossed.spends, isEmpty);

        final unwatched = scanCompactBlocks(
          ufvk: ufvk,
          network: 'regtest',
          blocks: blocks,
        );
        expect(unwatched.spends, isEmpty);
      });
    },
  );
}
