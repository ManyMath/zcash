import 'dart:math';

import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

// Arbitrary multiple of 144 past NU6.3 mainnet activation (3428143).
const boundary = 3428496;

TreeState treeStateAt(
  int height, {
  String? orchard = '0102',
  String? ironwood = '0304',
}) => TreeState.fromJson({
  'hash': 'ab' * 32,
  'height': height,
  'time': 0,
  'sapling': {
    'commitments': {'finalState': '00'},
  },
  if (orchard != null)
    'orchard': {
      'commitments': {'finalState': orchard},
    },
  if (ironwood != null)
    'ironwood': {
      'commitments': {'finalState': ironwood},
    },
});

void main() {
  group('Zip318BoundaryAnchors.at', () {
    test('reads both pools from a single fetch at the boundary', () {
      var calls = 0;
      return Zip318BoundaryAnchors.at(
        boundaryHeight: boundary,
        fetch: (h) async {
          calls++;
          expect(h, boundary);
          return treeStateAt(h);
        },
      ).then((anchors) {
        expect(calls, 1);
        expect(anchors.boundaryHeight, boundary);
        expect(anchors.orchardTreeHex, '0102');
        expect(anchors.ironwoodTreeHex, '0304');
        expect(anchors.ironwoodTreeIsEmpty, isFalse);
      });
    });

    test(
      'accepts an empty Ironwood tree as the real pre-first-output state',
      () {
        return Zip318BoundaryAnchors.at(
          boundaryHeight: boundary,
          fetch: (h) async => treeStateAt(h, ironwood: ''),
        ).then((anchors) {
          expect(anchors.ironwoodTreeIsEmpty, isTrue);
          expect(anchors.ironwoodTreeHex, '');
        });
      },
    );

    test('refuses a non-boundary height before it asks the server', () async {
      var called = false;
      await expectLater(
        Zip318BoundaryAnchors.at(
          boundaryHeight: boundary + 1,
          fetch: (h) async {
            called = true;
            return treeStateAt(h);
          },
        ),
        throwsA(
          isA<Zip318AnchorException>().having(
            (e) => e.anchorRefusal,
            'anchorRefusal',
            Zip318AnchorRefusal.wrongHeight,
          ),
        ),
      );
      expect(called, isFalse);
    });

    test('refuses an answer from a height other than the one asked', () {
      return expectLater(
        Zip318BoundaryAnchors.at(
          boundaryHeight: boundary,
          fetch: (h) async => treeStateAt(h + 3),
        ),
        throwsA(
          isA<Zip318AnchorException>().having(
            (e) => e.anchorRefusal,
            'anchorRefusal',
            Zip318AnchorRefusal.wrongHeight,
          ),
        ),
      );
    });

    test('refuses a response with no Ironwood tree', () {
      return expectLater(
        Zip318BoundaryAnchors.at(
          boundaryHeight: boundary,
          fetch: (h) async => treeStateAt(h, ironwood: null),
        ),
        throwsA(
          isA<Zip318AnchorException>().having(
            (e) => e.anchorRefusal,
            'anchorRefusal',
            Zip318AnchorRefusal.ironwoodTreeUnavailable,
          ),
        ),
      );
    });

    test('refuses a response with no Orchard tree', () {
      return expectLater(
        Zip318BoundaryAnchors.at(
          boundaryHeight: boundary,
          fetch: (h) async => treeStateAt(h, orchard: null),
        ),
        throwsA(
          isA<Zip318AnchorException>().having(
            (e) => e.anchorRefusal,
            'anchorRefusal',
            Zip318AnchorRefusal.orchardTreeUnavailable,
          ),
        ),
      );
    });
  });

  group('Zip318BoundaryAnchors.draw', () {
    test('draws a boundary height rather than taking the tip', () async {
      var requested = -1;
      final anchors = await Zip318BoundaryAnchors.draw(
        activationHeight: 3428143,
        fundingNoteHeight: 3428200,
        observedTipHeight: 3428600,
        rng: Random(7),
        fetch: (h) async {
          requested = h;
          return treeStateAt(h);
        },
      );
      expect(anchors.boundaryHeight % 144, 0);
      expect(anchors.boundaryHeight, lessThanOrEqualTo(3428600));
      expect(anchors.boundaryHeight, requested);
      expect(anchors.boundaryHeight, isNot(3428600));
    });

    test('is deterministic under an injected Random', () async {
      Future<int> drawWith(int seed) async => (await Zip318BoundaryAnchors.draw(
        activationHeight: 3428143,
        fundingNoteHeight: 3428200,
        observedTipHeight: 3428600,
        rng: Random(seed),
        fetch: (h) async => treeStateAt(h),
      )).boundaryHeight;
      expect(await drawWith(11), await drawWith(11));
    });

    test('waits rather than falling back when no boundary is available', () {
      return expectLater(
        Zip318BoundaryAnchors.draw(
          activationHeight: 3428143,
          fundingNoteHeight: 3428599,
          observedTipHeight: 3428600,
          rng: Random(3),
          fetch: (h) async => treeStateAt(h),
        ),
        throwsA(isA<ZcashModelException>()),
      );
    });
  });
}
