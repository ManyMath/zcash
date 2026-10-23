import 'dart:math';

import 'tree_state.dart';
import 'zip318_migration.dart';
import 'zip318_transfer_plan.dart';

// ZIP 318 boundary anchors, not the tip: a tip anchor reveals when the
// wallet last synced.

enum Zip318AnchorRefusal {
  wrongHeight,

  ironwoodTreeUnavailable,

  orchardTreeUnavailable,
}

class Zip318AnchorException extends Zip318PlanException {
  Zip318AnchorException(this.anchorRefusal, String message)
    : super(Zip318PlanRefusal.anchorOffBoundary, message);

  final Zip318AnchorRefusal anchorRefusal;
}

class Zip318BoundaryAnchors {
  const Zip318BoundaryAnchors({
    required this.boundaryHeight,
    required this.orchardTreeHex,
    required this.ironwoodTreeHex,
  });

  final int boundaryHeight;

  final String orchardTreeHex;

  final String ironwoodTreeHex;

  bool get ironwoodTreeIsEmpty => ironwoodTreeHex.isEmpty;

  static Future<Zip318BoundaryAnchors> draw({
    required int activationHeight,
    required int fundingNoteHeight,
    required int observedTipHeight,
    required Future<TreeState> Function(int height) fetch,
    required Random rng,
    Zip318Parameters parameters = Zip318Parameters.provisional,
  }) async {
    final boundaryHeight = Zip318AnchorSelection(parameters).drawAnchorHeight(
      activationHeight: activationHeight,
      fundingNoteHeight: fundingNoteHeight,
      observedTipHeight: observedTipHeight,
      rng: rng,
    );
    return at(
      boundaryHeight: boundaryHeight,
      fetch: fetch,
      parameters: parameters,
    );
  }

  static Future<Zip318BoundaryAnchors> at({
    required int boundaryHeight,
    required Future<TreeState> Function(int height) fetch,
    Zip318Parameters parameters = Zip318Parameters.provisional,
  }) async {
    final grid = Zip318AnchorSelection(parameters);
    if (!grid.isBoundary(boundaryHeight)) {
      throw Zip318AnchorException(
        Zip318AnchorRefusal.wrongHeight,
        'height $boundaryHeight is not on the anchor grid '
        '(${grid.gridDescription}); a non-boundary anchor is what '
        "ties a transaction back to its own wallet's sync",
      );
    }
    final state = await fetch(boundaryHeight);
    if (state.height != boundaryHeight) {
      throw Zip318AnchorException(
        Zip318AnchorRefusal.wrongHeight,
        'the tree state came back for height ${state.height} rather than the '
        'requested boundary $boundaryHeight; anchoring at the answer instead '
        'of the question would silently leave the cohort',
      );
    }
    final orchard = state.orchard?.finalState;
    if (orchard == null) {
      throw Zip318AnchorException(
        Zip318AnchorRefusal.orchardTreeUnavailable,
        'the tree state at $boundaryHeight carries no Orchard tree, so an '
        'Orchard spend has nothing to be witnessed against',
      );
    }
    final ironwood = state.ironwood?.finalState;
    if (ironwood == null) {
      throw Zip318AnchorException(
        Zip318AnchorRefusal.ironwoodTreeUnavailable,
        'the tree state at $boundaryHeight carries no Ironwood tree. Before '
        'NU6.3 activation there is none; after it, a server omitting the field '
        'does not understand the pool, and the Orchard tree is not a stand-in '
        'for it',
      );
    }
    return Zip318BoundaryAnchors(
      boundaryHeight: boundaryHeight,
      orchardTreeHex: orchard,
      ironwoodTreeHex: ironwood,
    );
  }
}
