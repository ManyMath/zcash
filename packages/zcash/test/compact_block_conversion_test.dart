import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

void main() {
  group('ZcashCompactBlockConversion', () {
    Map<String, Object?> validJson() => {
      'network': 'regtest',
      'blocks': [
        {
          'height': 102,
          'data': 'AQID',
          'transactions': 2,
          'sapling_outputs': 0,
          'orchard_actions': 2,
          'ironwood_actions': 0,
        },
      ],
      'sapling_commitment_tree_size': 0,
      'orchard_commitment_tree_size': 2,
      'ironwood_commitment_tree_size': 0,
    };

    test('parses a conversion and its cumulative tree sizes', () {
      final result = ZcashCompactBlockConversion.fromJson(validJson());
      expect(result.network, ZcashAddressNetwork.regtest);
      expect(result.blocks, hasLength(1));
      expect(result.blocks.single.height, 102);
      expect(result.blocks.single.orchardActions, 2);
      expect(result.blocks.single.ironwoodActions, 0);
      expect(result.orchardCommitmentTreeSize, 2);
    });

    test('produces scan entries that need no reshaping', () {
      final entries = ZcashCompactBlockConversion.fromJson(
        validJson(),
      ).toScanEntries();
      expect(entries, [
        {'height': 102, 'data': 'AQID'},
      ]);
    });

    test('keeps the two Orchard-family action counts separate', () {
      final result = ZcashCompactBlockConversion.fromJson(
        validJson()
          ..['blocks'] = [
            {
              'height': 200,
              'data': 'AQID',
              'orchard_actions': 2,
              'ironwood_actions': 1,
            },
          ]
          ..['ironwood_commitment_tree_size'] = 1,
      );
      expect(result.blocks.single.orchardActions, 2);
      expect(result.blocks.single.ironwoodActions, 1);
      expect(result.ironwoodCommitmentTreeSize, 1);
    });

    test('rejects a result missing its blocks or tree sizes', () {
      expect(
        () =>
            ZcashCompactBlockConversion.fromJson(validJson()..remove('blocks')),
        throwsA(isA<ZcashModelException>()),
      );
      expect(
        () => ZcashCompactBlockConversion.fromJson(
          validJson()..remove('orchard_commitment_tree_size'),
        ),
        throwsA(isA<ZcashModelException>()),
      );
      expect(
        () => ZcashCompactBlockConversion.fromJson(
          validJson()
            ..['blocks'] = [
              {'height': 1},
            ],
        ),
        throwsA(isA<ZcashModelException>()),
      );
    });
  });
}
