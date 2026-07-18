import 'dart:convert';

import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

void main() {
  _noteVersionValidationTests();
  _spendObservationTests();
  group('ZcashScanResult note pools', () {
    Map<String, Object?> resultWith(List<Map<String, Object?>> notes) => {
      'scanned_blocks': 1,
      'discovered_notes': notes.length,
      'total_value': notes.fold<int>(
        0,
        (sum, note) => sum + (note['value']! as int),
      ),
      'notes': notes,
    };

    final saplingNote = {
      'height': 1,
      'tx': 'ab' * 32,
      'output': 0,
      'value': 12345,
      'pool': 'sapling',
      'nullifier': 'cd' * 32,
      'commitment_position': 7,
      'is_change': false,
    };

    final orchardNote = {
      'height': 1,
      'tx': 'ef' * 32,
      'output': 1,
      'value': 54321,
      'pool': 'orchard',
      'nullifier': '12' * 32,
      'commitment_position': 9,
      'is_change': false,
    };

    test('parses Sapling notes by default', () {
      final result = ZcashScanResult.fromJson(resultWith([saplingNote]));
      expect(result.notes, hasLength(1));
      expect(result.notes.single.pool, 'sapling');
    });

    test('rejects Orchard notes by default (Sapling-only boundary)', () {
      expect(
        () => ZcashScanResult.fromJson(resultWith([orchardNote])),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('unsupported scanner note pool'),
          ),
        ),
      );
    });

    test(
      'accepts Ironwood notes by default, since the default build finds them',
      () {
        final result = ZcashScanResult.fromJson(
          resultWith([
            {...orchardNote, 'pool': 'ironwood'},
          ]),
        );
        expect(result.notes.single.pool, 'ironwood');
      },
    );

    test('an unknown pool is refused without echoing it', () {
      expect(
        () => ZcashScanResult.fromJson(
          resultWith([
            {...orchardNote, 'pool': 'mystery'},
          ]),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('unsupported scanner note pool'),
              isNot(contains('mystery')),
            ),
          ),
        ),
      );
    });

    test('accepts Ironwood notes under the same experimental opt-in', () {
      final result = ZcashScanResult.fromJson(
        resultWith([
          orchardNote,
          {...orchardNote, 'pool': 'ironwood', 'value': 11111},
        ]),
        allowExperimentalOrchardNotes: true,
      );
      expect(result.notes.map((note) => note.pool), ['orchard', 'ironwood']);
      final ironwood = result.notes.firstWhere((n) => n.pool == 'ironwood');
      expect(ironwood.value, 11111);
    });

    test('accepts Orchard notes only with the experimental opt-in', () {
      final result = ZcashScanResult.fromJson(
        resultWith([saplingNote, orchardNote]),
        allowExperimentalOrchardNotes: true,
      );
      expect(result.notes, hasLength(2));
      expect(
        result.notes.map((note) => note.pool),
        containsAll(['sapling', 'orchard']),
      );
      final orchard = result.notes.firstWhere((note) => note.pool == 'orchard');
      expect(orchard.value, 54321);
      expect(orchard.nullifier, '12' * 32);
      expect(orchard.commitmentPosition, 9);
      expect(orchard.isChange, false);
    });

    test('opt-in still rejects unknown pools', () {
      final note = Map<String, Object?>.from(orchardNote)..['pool'] = 'mystery';
      expect(
        () => ZcashScanResult.fromJson(
          resultWith([note]),
          allowExperimentalOrchardNotes: true,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('parses Sapling witness and tip anchor when present (8.3)', () {
      final note = Map<String, Object?>.from(saplingNote)
        ..['witness'] = '0a' * 70;
      final json = resultWith([note])..['sapling_anchor'] = 'be' * 32;
      final result = ZcashScanResult.fromJson(json);
      expect(result.saplingAnchor, 'be' * 32);
      expect(result.notes.single.witness, '0a' * 70);
    });

    test('witness and anchor are null when absent (back-compat)', () {
      final result = ZcashScanResult.fromJson(resultWith([saplingNote]));
      expect(result.saplingAnchor, isNull);
      expect(result.orchardAnchor, isNull);
      expect(result.ironwoodAnchor, isNull);
      expect(result.notes.single.witness, isNull);
    });

    test('carries rho and the note version for Orchard-family notes', () {
      final note = Map<String, Object?>.from(orchardNote)
        ..['witness'] = '0a' * 70
        ..['recipient'] = 'utest1example'
        ..['rseed'] = '2a' * 32
        ..['rho'] = '3b' * 32
        ..['note_version'] = 'v2';
      final result = ZcashScanResult.fromJson(
        resultWith([note]),
        allowExperimentalOrchardNotes: true,
      );
      final parsed = result.notes.single;
      expect(parsed.rho, '3b' * 32);
      expect(parsed.noteVersion, 'v2');
      expect(parsed.rseed, '2a' * 32);
    });

    test('leaves rho and the note version null for a Sapling note', () {
      final note = Map<String, Object?>.from(saplingNote)
        ..['rseed'] = '2a' * 32;
      final parsed = ZcashScanResult.fromJson(resultWith([note])).notes.single;
      expect(parsed.rseed, '2a' * 32);
      expect(parsed.rho, isNull);
      expect(parsed.noteVersion, isNull);
    });

    test('rejects a malformed rho without echoing it', () {
      final note = Map<String, Object?>.from(orchardNote)..['rho'] = 'nothex!';
      expect(
        () => ZcashScanResult.fromJson(
          resultWith([note]),
          allowExperimentalOrchardNotes: true,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            isNot(contains('nothex!')),
          ),
        ),
      );
    });

    test('parses the Orchard and Ironwood anchors separately', () {
      final json = resultWith([saplingNote])
        ..['orchard_anchor'] = 'aa' * 32
        ..['ironwood_anchor'] = 'bb' * 32;
      final result = ZcashScanResult.fromJson(json);
      expect(result.orchardAnchor, 'aa' * 32);
      expect(result.ironwoodAnchor, 'bb' * 32);
      expect(result.orchardAnchor, isNot(result.ironwoodAnchor));
    });

    test('rejects a malformed Orchard anchor without echoing it', () {
      final json = resultWith([saplingNote])..['orchard_anchor'] = 'nothex!';
      expect(
        () => ZcashScanResult.fromJson(json),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            isNot(contains('nothex!')),
          ),
        ),
      );
    });

    test('rejects a malformed witness hex without echoing it', () {
      final note = Map<String, Object?>.from(saplingNote)
        ..['witness'] = 'nothex!';
      expect(
        () => ZcashScanResult.fromJson(resultWith([note])),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(contains('malformed hex'), isNot(contains('nothex'))),
          ),
        ),
      );
    });

    test('parses recipient and rseed when present (8.4b)', () {
      final note = Map<String, Object?>.from(saplingNote)
        ..['recipient'] = 'zregtestsapling1exampleexampleexample'
        ..['rseed'] = '0b' * 32;
      final result = ZcashScanResult.fromJson(resultWith([note]));
      expect(
        result.notes.single.recipient,
        'zregtestsapling1exampleexampleexample',
      );
      expect(result.notes.single.rseed, '0b' * 32);
    });

    test('recipient and rseed are null when absent (back-compat)', () {
      final result = ZcashScanResult.fromJson(resultWith([saplingNote]));
      expect(result.notes.single.recipient, isNull);
      expect(result.notes.single.rseed, isNull);
    });

    test('rejects a malformed rseed hex without echoing it', () {
      final note = Map<String, Object?>.from(saplingNote)
        ..['rseed'] = 'nothex!';
      expect(
        () => ZcashScanResult.fromJson(resultWith([note])),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(contains('malformed hex'), isNot(contains('nothex'))),
          ),
        ),
      );
    });
  });

  group('ScanInputEnvelope witness opt-in', () {
    final block = CompactBlockScanInput(bytes: const [1, 2, 3], height: 1);

    test('omits include_sapling_witnesses by default', () {
      final json =
          jsonDecode(ScanInputEnvelope(blocks: [block]).encode())
              as Map<String, Object?>;
      expect(json.containsKey('include_sapling_witnesses'), isFalse);
    });

    test('emits include_sapling_witnesses when requested', () {
      final json =
          jsonDecode(
                ScanInputEnvelope(
                  includeSaplingWitnesses: true,
                  blocks: [block],
                ).encode(),
              )
              as Map<String, Object?>;
      expect(json['include_sapling_witnesses'], isTrue);
    });

    test('encodeVersionedCompactBlocksForScan threads the flag', () {
      final json =
          jsonDecode(
                encodeVersionedCompactBlocksForScan(
                  blocks: [block],
                  includeSaplingWitnesses: true,
                ),
              )
              as Map<String, Object?>;
      expect(json['include_sapling_witnesses'], isTrue);
    });

    test('omits prior_sapling_frontier by default', () {
      final json =
          jsonDecode(ScanInputEnvelope(blocks: [block]).encode())
              as Map<String, Object?>;
      expect(json.containsKey('prior_sapling_frontier'), isFalse);
    });

    test('emits prior_sapling_frontier when supplied (8.4)', () {
      final json =
          jsonDecode(
                ScanInputEnvelope(
                  includeSaplingWitnesses: true,
                  priorSaplingFrontier: '00abcd',
                  blocks: [block],
                ).encode(),
              )
              as Map<String, Object?>;
      expect(json['prior_sapling_frontier'], '00abcd');
    });

    test('encodeVersionedCompactBlocksForScan threads the frontier', () {
      final json =
          jsonDecode(
                encodeVersionedCompactBlocksForScan(
                  blocks: [block],
                  includeSaplingWitnesses: true,
                  priorSaplingFrontier: 'deadbeef',
                ),
              )
              as Map<String, Object?>;
      expect(json['prior_sapling_frontier'], 'deadbeef');
    });

    test('omits the Orchard-family witness fields by default', () {
      final json =
          jsonDecode(ScanInputEnvelope(blocks: [block]).encode())
              as Map<String, Object?>;
      expect(json.containsKey('include_orchard_witnesses'), isFalse);
      expect(json.containsKey('prior_orchard_frontier'), isFalse);
      expect(json.containsKey('prior_ironwood_frontier'), isFalse);
    });

    test('emits a separate prior frontier for each Orchard-family pool', () {
      final json =
          jsonDecode(
                encodeVersionedCompactBlocksForScan(
                  blocks: [block],
                  includeOrchardWitnesses: true,
                  priorOrchardFrontier: '00aa',
                  priorIronwoodFrontier: '00bb',
                ),
              )
              as Map<String, Object?>;
      expect(json['include_orchard_witnesses'], isTrue);
      expect(json['prior_orchard_frontier'], '00aa');
      expect(json['prior_ironwood_frontier'], '00bb');
    });
  });
}

void _noteVersionValidationTests() {
  group('ZcashScannedNote.noteVersion validation', () {
    Map<String, Object?> orchardNote() => {
      'height': 102,
      'tx': 'ab' * 32,
      'output': 0,
      'value': 1000000,
      'pool': 'orchard',
      'note_version': 'v2',
    };

    test('accepts the two Orchard-family note versions', () {
      for (final version in ['v2', 'v3']) {
        final note = ZcashScannedNote.fromJson(
          orchardNote()..['note_version'] = version,
          allowExperimentalOrchardNotes: true,
        );
        expect(note.noteVersion, version);
      }
    });

    test(
      'reports a malformed note version rather than throwing a TypeError',
      () {
        expect(
          () => ZcashScannedNote.fromJson(
            orchardNote()..['note_version'] = 2,
            allowExperimentalOrchardNotes: true,
          ),
          throwsA(isA<StateError>()),
        );
        final absent = ZcashScannedNote.fromJson(
          orchardNote()..remove('note_version'),
          allowExperimentalOrchardNotes: true,
        );
        expect(absent.noteVersion, isNull);
      },
    );
  });
}

void _spendObservationTests() {
  group('ZcashWatchedNullifiers', () {
    final nullifier = 'ab' * 32;

    test('emits only the pools it was given', () {
      final watched = ZcashWatchedNullifiers(ironwood: [nullifier]);
      expect(watched.toJson(), {
        'ironwood': [nullifier],
      });
      expect(watched.isEmpty, isFalse);
      expect(ZcashWatchedNullifiers().isEmpty, isTrue);
    });

    test('rejects a nullifier that is not 32 bytes of hex', () {
      for (final bad in ['ab' * 31, 'zz' * 32, '']) {
        expect(
          () => ZcashWatchedNullifiers(sapling: [bad]),
          throwsA(isA<ArgumentError>()),
          reason: 'accepted $bad',
        );
      }
    });

    test('forPool refuses a pool the scanner never labels', () {
      expect(
        () => ZcashWatchedNullifiers.forPool('orchid', [nullifier]),
        throwsA(isA<ArgumentError>()),
      );
      expect(ZcashWatchedNullifiers.forPool('ironwood', [nullifier]).ironwood, [
        nullifier,
      ]);
    });

    test('fromScannedNotes files each note under its own pool', () {
      final notes = [
        ZcashScannedNote(
          height: 1,
          tx: 'aa',
          output: 0,
          value: 1,
          pool: 'ironwood',
          nullifier: '11' * 32,
        ),
        ZcashScannedNote(
          height: 1,
          tx: 'bb',
          output: 1,
          value: 2,
          pool: 'orchard',
          nullifier: '22' * 32,
        ),
        const ZcashScannedNote(
          height: 1,
          tx: 'cc',
          output: 2,
          value: 3,
          pool: 'sapling',
        ),
      ];

      final watched = ZcashWatchedNullifiers.fromScannedNotes(notes);

      expect(watched.ironwood, ['11' * 32]);
      expect(watched.orchard, ['22' * 32]);
      expect(watched.sapling, isEmpty);
    });

    test('the envelope omits the field when nothing is watched', () {
      final block = CompactBlockScanInput(bytes: const [1, 2, 3], height: 1);
      final empty =
          jsonDecode(
                ScanInputEnvelope(
                  watchedNullifiers: ZcashWatchedNullifiers(),
                  blocks: [block],
                ).encode(),
              )
              as Map<String, Object?>;
      expect(empty.containsKey('watched_nullifiers'), isFalse);

      final threaded =
          jsonDecode(
                encodeVersionedCompactBlocksForScan(
                  blocks: [block],
                  watchedNullifiers: ZcashWatchedNullifiers(
                    ironwood: [nullifier],
                  ),
                ),
              )
              as Map<String, Object?>;
      expect(threaded['watched_nullifiers'], {
        'ironwood': [nullifier],
      });
    });
  });

  group('ZcashScanResult.spends', () {
    Map<String, Object?> resultWith(List<Map<String, Object?>> spends) => {
      'scanned_blocks': 1,
      'discovered_notes': 0,
      'total_value': 0,
      'notes': <Object?>[],
      'spends': spends,
    };

    final spend = {
      'height': 42,
      'tx': 'ab' * 32,
      'pool': 'ironwood',
      'nullifier': 'cd' * 32,
      'index': 1,
      'note_index': null,
    };

    test('parses an Ironwood spend without the experimental note opt-in', () {
      final result = ZcashScanResult.fromJson(resultWith([spend]));
      expect(result.spends, hasLength(1));
      final observed = result.spends.single;
      expect(observed.pool, 'ironwood');
      expect(observed.height, 42);
      expect(observed.index, 1);
      expect(observed.nullifier, 'cd' * 32);
      expect(observed.noteIndex, isNull);
    });

    test('joins a spend to the note this scan discovered', () {
      final result = ZcashScanResult.fromJson(
        resultWith([
          {...spend, 'note_index': 0},
        ]),
      );
      expect(result.spends.single.noteIndex, 0);
    });

    test('a result without the field reports no spends', () {
      final legacy = resultWith([])..remove('spends');
      expect(ZcashScanResult.fromJson(legacy).spends, isEmpty);
    });

    test('rejects an unknown spend pool without echoing it', () {
      final unknown = {...spend, 'pool': 'orchid'};
      expect(
        () => ZcashScanResult.fromJson(resultWith([unknown])),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('unsupported spend pool'),
              isNot(contains('orchid')),
            ),
          ),
        ),
      );
    });

    test('rejects a malformed nullifier without echoing it', () {
      final malformed = {...spend, 'nullifier': 'zz' * 32};
      expect(
        () => ZcashScanResult.fromJson(resultWith([malformed])),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            isNot(contains('zz')),
          ),
        ),
      );
    });
  });
}
