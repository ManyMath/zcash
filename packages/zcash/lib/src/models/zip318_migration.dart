import 'dart:math';

import 'consensus.dart';
import 'proposal.dart' show maxMoneyZatoshis;
import 'spend.dart';

// ZIP 318 is a Draft, so every constant here is provisional.

const int _zec = 100000000;

/// ZIP 218: NU7 cuts the target block spacing from 75 to 25 seconds.
const int nu7PowTargetSpacingRatio = 3;

/// Converts ZIP 318 durations, stated in 75-second reference blocks, into
/// block heights on a chain whose spacing drops to 25 seconds at NU7.
class Zip318BlockSpacing {
  const Zip318BlockSpacing([this.nu7ActivationHeight]);

  static const uniform = Zip318BlockSpacing();

  final int? nu7ActivationHeight;

  int blocksPerReferenceBlock(int height) {
    final activation = nu7ActivationHeight;
    return activation != null && height >= activation
        ? nu7PowTargetSpacingRatio
        : 1;
  }

  /// The height `referenceBlocks` reference blocks after `from`; a span
  /// crossing activation keeps its length in time.
  int advance(int from, int referenceBlocks) =>
      _heightAt(_timeOf(from) + referenceBlocks * nu7PowTargetSpacingRatio);

  // Time in post-NU7 block spacings since genesis.
  int _timeOf(int height) {
    final activation = nu7ActivationHeight;
    if (activation == null || height <= activation) {
      return height * nu7PowTargetSpacingRatio;
    }
    return activation * nu7PowTargetSpacingRatio + (height - activation);
  }

  int _heightAt(int time) {
    final activation = nu7ActivationHeight;
    if (activation == null || time <= activation * nu7PowTargetSpacingRatio) {
      return (time + nu7PowTargetSpacingRatio - 1) ~/ nu7PowTargetSpacingRatio;
    }
    return activation + (time - activation * nu7PowTargetSpacingRatio);
  }
}

/// Delays and moduli are in reference blocks; [blockSpacing] scales them
/// from NU7 activation. Use the preset for the wallet's network: a wallet
/// on the wrong grid or expiry is distinguishable from its peers.
class Zip318Parameters {
  static const mainnet = Zip318Parameters(
    nu63ActivationHeight: 3428143,
    nu7ActivationHeight: 3543405,
  );

  static const testnet = Zip318Parameters(
    nu63ActivationHeight: 4134000,
    nu7ActivationHeight: 4465026,
  );

  static const provisional = mainnet;

  /// Regtest has no fixed NU6.3 or NU7 height: pass the node's. Omitting NU7
  /// gives uniform spacing; omitting NU6.3 leaves every anchor and start
  /// bound needing an explicit activation height.
  factory Zip318Parameters.forNetwork(
    ZcashConsensusNetwork network, {
    int? regtestNu63ActivationHeight,
    int? regtestNu7ActivationHeight,
  }) => switch (network) {
    ZcashConsensusNetwork.mainnet => mainnet,
    ZcashConsensusNetwork.testnet => testnet,
    ZcashConsensusNetwork.regtest => Zip318Parameters(
      nu63ActivationHeight: regtestNu63ActivationHeight,
      nu7ActivationHeight: regtestNu7ActivationHeight,
    ),
  };

  const Zip318Parameters({
    this.nu63ActivationHeight,
    this.nu7ActivationHeight,
    this.maxResidualValueZatoshis = _zec ~/ 100,
    this.denomCapZatoshis = 10000 * _zec,
    this.meanDelayBlocks = 66,
    this.maxDelayBlocks = 576,
    this.anchorBoundaryModulus = 144,
    this.anchorAgeCapBoundaries = 4,
    this.expiryModulusBlocks = 34560,
    this.prepMeanDelayBlocks = 16,
    this.prepMaxDelayBlocks = 96,
    this.prepActionsPerTransaction = 16,
    this.prepMiningMarginBlocks = 10,
    this.isProvisional = true,
  });

  /// NU6.3 activates the Ironwood pool; every anchor lies strictly above it.
  /// Null when unknown, as on regtest without a configured height.
  final int? nu63ActivationHeight;

  /// Null on a chain where NU7 never activates.
  final int? nu7ActivationHeight;

  Zip318BlockSpacing get blockSpacing =>
      Zip318BlockSpacing(nu7ActivationHeight);

  final int maxResidualValueZatoshis;

  final int denomCapZatoshis;

  final int meanDelayBlocks;

  final int maxDelayBlocks;

  final int anchorBoundaryModulus;

  /// Age `a` counts boundaries before the most recent observed one, so the
  /// most recent (age 0) is never used.
  final int anchorAgeCapBoundaries;

  final int expiryModulusBlocks;

  final int prepMeanDelayBlocks;

  final int prepMaxDelayBlocks;

  final int prepActionsPerTransaction;

  /// Blocks for the last preparation transaction to mine after its scheduled
  /// height. A mining margin is a block count, not a duration, so NU7 does
  /// not scale it. Not fixed by ZIP 318; 10 follows zcash_pool_migration.
  final int prepMiningMarginBlocks;

  final bool isProvisional;

  /// [explicit] if given, else the NU6.3 height this parameter set carries.
  int nu63ActivationHeightOr(int? explicit) {
    final height = explicit ?? nu63ActivationHeight;
    if (height == null) {
      throw ZcashModelException(
        'the NU6.3 activation height is unknown for this parameter set; pass '
        'activationHeight, or use Zip318Parameters.forNetwork with '
        'regtestNu63ActivationHeight on regtest',
      );
    }
    return height;
  }
}

class Zip318Denominations {
  const Zip318Denominations([this.parameters = Zip318Parameters.provisional]);

  final Zip318Parameters parameters;

  List<int> get canonical {
    final out = <int>[];
    for (var place = parameters.maxResidualValueZatoshis; ; place *= 10) {
      var added = false;
      for (final n in const [1, 2, 5]) {
        final value = n * place;
        if (value > parameters.denomCapZatoshis) continue;
        out.add(value);
        added = true;
      }
      if (!added || place > parameters.denomCapZatoshis) break;
    }
    out.sort();
    return out;
  }

  bool isCanonical(int zatoshis) => canonical.contains(zatoshis);

  Zip318Decomposition decompose(int zatoshis) {
    if (zatoshis < 0) {
      throw ZcashModelException('migratable value must not be negative');
    }
    if (zatoshis > maxMoneyZatoshis) {
      throw ZcashModelException('migratable value exceeds the money supply');
    }
    final residual = zatoshis % parameters.maxResidualValueZatoshis;
    var remaining = zatoshis - residual;
    final parts = <int>[];

    final capParts = remaining ~/ parameters.denomCapZatoshis;
    for (var i = 0; i < capParts; i++) {
      parts.add(parameters.denomCapZatoshis);
    }
    remaining -= capParts * parameters.denomCapZatoshis;

    for (
      var place = parameters.denomCapZatoshis ~/ 10;
      place >= parameters.maxResidualValueZatoshis;
      place ~/= 10
    ) {
      final digit = remaining ~/ place;
      remaining -= digit * place;
      for (final n in _digitParts(digit)) {
        parts.add(n * place);
      }
    }
    assert(remaining == 0, 'digit expansion must consume the whole value');
    return Zip318Decomposition(
      parts: parts,
      residualZatoshis: residual,
      parameters: parameters,
    );
  }

  /// ZIP 318's randomized decomposition, for better balance hiding.
  Zip318Decomposition decomposeRandomized(int zatoshis, Random rng) {
    if (zatoshis < 0) {
      throw ZcashModelException('migratable value must not be negative');
    }
    final residual = zatoshis % parameters.maxResidualValueZatoshis;
    var remaining = zatoshis - residual;
    final parts = <int>[];
    final descending = canonical.reversed.toList(growable: false);
    while (remaining > 0) {
      final candidates = descending
          .where((d) => d <= remaining)
          .toList(growable: false);
      if (candidates.isEmpty) break;
      final largest = candidates.first;
      final place = largest ~/ _leadingDigit(largest, parameters);
      final roll = rng.nextDouble();
      // With {1, 2, 5} available, 1 at 10% and 2 at 25%; with only {1, 2},
      // 1 at 25%. A leading 1, DENOM_CAP included, is its magnitude's only one.
      final chosen = switch (largest ~/ place) {
        5 when roll < 0.10 => place,
        5 when roll < 0.35 => 2 * place,
        2 when roll < 0.25 => place,
        _ => largest,
      };
      parts.add(chosen);
      remaining -= chosen;
    }
    return Zip318Decomposition(
      parts: parts,
      residualZatoshis: residual + remaining,
      parameters: parameters,
    );
  }

  static List<int> _digitParts(int digit) => switch (digit) {
    0 => const [],
    1 => const [1],
    2 => const [2],
    3 => const [2, 1],
    4 => const [2, 2],
    5 => const [5],
    6 => const [5, 1],
    7 => const [5, 2],
    8 => const [5, 2, 1],
    9 => const [5, 2, 2],
    _ => throw ZcashModelException('digit out of range: $digit'),
  };

  static int _leadingDigit(int denomination, Zip318Parameters parameters) {
    var place = parameters.maxResidualValueZatoshis;
    while (place * 10 <= denomination) {
      place *= 10;
    }
    return denomination ~/ place;
  }
}

class Zip318Decomposition {
  const Zip318Decomposition({
    required this.parts,
    required this.residualZatoshis,
    required this.parameters,
  });

  final List<int> parts;

  final int residualZatoshis;

  final Zip318Parameters parameters;

  int get migratedZatoshis => parts.fold(0, (sum, part) => sum + part);

  int get transferCount => parts.length;

  int totalFeeZatoshis(int canonicalFeeZatoshis) =>
      transferCount * canonicalFeeZatoshis;

  List<int> fundingNoteValues(int canonicalFeeZatoshis) => [
    for (final part in parts) part + canonicalFeeZatoshis,
  ];
}

class Zip318AnchorSelection {
  const Zip318AnchorSelection([this.parameters = Zip318Parameters.provisional]);

  final Zip318Parameters parameters;

  // Boundaries are anchorBoundaryModulus reference blocks apart, so the step
  // in blocks triples from NU7 activation.
  int _stepAt(int height) =>
      parameters.anchorBoundaryModulus *
      parameters.blockSpacing.blocksPerReferenceBlock(height);

  bool isBoundary(int height) => height % _stepAt(height) == 0;

  int boundaryAtOrBelow(int height) {
    final activation = parameters.nu7ActivationHeight;
    final candidate = height - height % _stepAt(height);
    if (activation == null || height < activation || candidate >= activation) {
      return candidate;
    }
    // No boundary in [activation, height]: take the last one before it.
    final lastBefore = activation - 1;
    return lastBefore - lastBefore % _stepAt(lastBefore);
  }

  int? boundaryBefore(int height) =>
      height > 0 ? boundaryAtOrBelow(height - 1) : null;

  int boundaryAtOrAbove(int height) {
    final activation = parameters.nu7ActivationHeight;
    final candidate = _roundUp(height, _stepAt(height));
    if (activation == null || height >= activation || candidate < activation) {
      return candidate;
    }
    // The pre-NU7 grid ran past activation: take the first post-NU7 boundary.
    return _roundUp(activation, _stepAt(activation));
  }

  int boundaryAfter(int height) => boundaryAtOrAbove(height + 1);

  static int _roundUp(int height, int step) =>
      (height + step - 1) ~/ step * step;

  /// The first boundary strictly above NU6.3 activation and at or after
  /// [fundingNoteHeight]: the oldest anchor a funding note can ever take.
  int lowestCandidateBoundary({
    required int fundingNoteHeight,
    int? activationHeight,
  }) => max(
    boundaryAfter(parameters.nu63ActivationHeightOr(activationHeight)),
    boundaryAtOrAbove(fundingNoteHeight),
  );

  /// How many boundaries [anchorHeight] lies below the most recent boundary
  /// at or below [referenceHeight]: 0 for that boundary itself. Null when the
  /// anchor is above it or more than [limit] boundaries back.
  int? anchorAge(
    int anchorHeight, {
    required int referenceHeight,
    required int limit,
  }) {
    int? h = boundaryAtOrBelow(referenceHeight);
    for (var age = 0; age <= limit && h != null; age++) {
      if (h == anchorHeight) return age;
      if (h < anchorHeight) return null;
      h = boundaryBefore(h);
    }
    return null;
  }

  /// A description of the grid for refusal messages.
  String get gridDescription {
    final activation = parameters.nu7ActivationHeight;
    final modulus = parameters.anchorBoundaryModulus;
    if (activation == null) return 'a multiple of $modulus';
    return 'a multiple of $modulus before NU7 activation at $activation, or '
        'of ${modulus * nu7PowTargetSpacingRatio} from it';
  }

  List<int> candidates({
    int? activationHeight,
    required int fundingNoteHeight,
    required int observedTipHeight,
  }) {
    final floor = max(
      parameters.nu63ActivationHeightOr(activationHeight) + 1,
      fundingNoteHeight,
    );
    final out = <int>[];
    for (
      int? h = boundaryAtOrBelow(observedTipHeight);
      h != null && h >= floor && h > 0;
      h = boundaryBefore(h)
    ) {
      out.add(h);
    }
    return out.reversed.toList(growable: false);
  }

  /// Draw at proving time, from the tip observed then. A transfer proved
  /// ahead of [broadcastHeight] counts its age from the boundary at that
  /// height instead, so the anchor it broadcasts with is no older than the
  /// cap; the most recent observed boundary stays excluded either way.
  int drawAnchorHeight({
    int? activationHeight,
    required int fundingNoteHeight,
    required int observedTipHeight,
    int? broadcastHeight,
    required Random rng,
  }) {
    final candidateHeights = candidates(
      activationHeight: activationHeight,
      fundingNoteHeight: fundingNoteHeight,
      observedTipHeight: observedTipHeight,
    );
    final cap = parameters.anchorAgeCapBoundaries;
    final newest = boundaryAtOrBelow(observedTipHeight);
    final reference = max(observedTipHeight, broadcastHeight ?? 0);
    // Ages counted from the reference boundary; the most recent observed
    // boundary (age 0 at proving time) is never used.
    final byAge = <int, int>{
      for (final h in candidateHeights)
        if (h < newest)
          ?anchorAge(h, referenceHeight: reference, limit: cap): h,
    };
    if (byAge.isEmpty) {
      throw ZcashModelException(
        candidateHeights.length < 2
            ? 'no canonical boundary anchor is available yet for this funding '
                  'note; wait for the next boundary rather than anchoring at '
                  'the chain tip'
            : 'the broadcast height is more than $cap boundaries past every '
                  'anchor observed so far; prove closer to the broadcast',
      );
    }
    // Draws past the cap or the candidate set are redrawn, which truncates
    // Geometric(1/2) to the admissible ages.
    while (true) {
      final anchor = byAge[_drawGeometric(rng)];
      if (anchor != null) return anchor;
    }
  }

  static int _drawGeometric(Random rng) {
    var a = 1;
    while (!rng.nextBool() && a < 64) {
      a++;
    }
    return a;
  }
}

/// Carries no anchor: ZIP 318 draws each transfer's anchor at proving time,
/// from the candidate set observed then (see [Zip318AnchorSelection]).
class Zip318ScheduledTransfer {
  const Zip318ScheduledTransfer({
    required this.denominationZatoshis,
    required this.feeZatoshis,
    required this.broadcastHeight,
    required this.expiryHeight,
  });

  final int denominationZatoshis;

  final int feeZatoshis;

  final int broadcastHeight;

  /// Fixed at scheduling, from [broadcastHeight]; a late build keeps it.
  final int expiryHeight;

  int get fundingNoteValueZatoshis => denominationZatoshis + feeZatoshis;

  bool isOverdueAt(int chainHeight) => chainHeight > broadcastHeight;
}

class Zip318Schedule {
  const Zip318Schedule({
    required this.transfers,
    required this.residualZatoshis,
    required this.parameters,
    this.startHeight,
  });

  final List<Zip318ScheduledTransfer> transfers;

  /// The height the delays accumulated from, after [plan] raised it to
  /// [earliestStartHeight]. Null for a schedule assembled by hand.
  final int? startHeight;

  final int residualZatoshis;

  final Zip318Parameters parameters;

  int get totalMigratedZatoshis =>
      transfers.fold(0, (sum, t) => sum + t.denominationZatoshis);

  int get totalFeeZatoshis =>
      transfers.fold(0, (sum, t) => sum + t.feeZatoshis);

  int? get finalBroadcastHeight =>
      transfers.isEmpty ? null : transfers.last.broadcastHeight;

  List<Zip318ScheduledTransfer> overdueAt(int chainHeight) => [
    for (final t in transfers)
      if (t.isOverdueAt(chainHeight)) t,
  ];

  static int canonicalExpiryHeight(
    int broadcastHeight, [
    Zip318Parameters parameters = Zip318Parameters.provisional,
  ]) {
    final modulus =
        parameters.expiryModulusBlocks *
        parameters.blockSpacing.blocksPerReferenceBlock(broadcastHeight);
    return (broadcastHeight ~/ modulus) * modulus + 2 * modulus;
  }

  /// The boundary after the lowest candidate boundary for funding notes
  /// created at [fundingNoteHeight]. From there every transfer has an anchor
  /// of age 1 or more, so none needs a fallback.
  static int earliestStartHeight({
    required int fundingNoteHeight,
    int? activationHeight,
    Zip318Parameters parameters = Zip318Parameters.provisional,
  }) {
    final grid = Zip318AnchorSelection(parameters);
    return grid.boundaryAfter(
      grid.lowestCandidateBoundary(
        fundingNoteHeight: fundingNoteHeight,
        activationHeight: activationHeight,
      ),
    );
  }

  /// [fundingNoteHeight] is when the funding notes exist: with note
  /// preparation, [Zip318PreparationSchedule.estimatedFundingNoteHeight].
  /// [startHeight] is raised to [earliestStartHeight] rather than clamping
  /// each transfer, which keeps the drawn gaps intact.
  static Zip318Schedule plan({
    required Zip318Decomposition decomposition,
    required int startHeight,
    required int canonicalFeeZatoshis,
    required int fundingNoteHeight,
    required Random rng,
    int? activationHeight,
    Zip318Parameters? parameters,
  }) {
    final params = parameters ?? decomposition.parameters;
    final start = max(
      startHeight,
      earliestStartHeight(
        fundingNoteHeight: fundingNoteHeight,
        activationHeight: activationHeight,
        parameters: params,
      ),
    );
    final parts = List<int>.from(decomposition.parts);
    parts.shuffle(rng);

    var height = start;
    final transfers = <Zip318ScheduledTransfer>[];
    for (final part in parts) {
      height = params.blockSpacing.advance(
        height,
        _drawExponentialDelay(
          rng,
          meanBlocks: params.meanDelayBlocks,
          maxBlocks: params.maxDelayBlocks,
        ),
      );
      transfers.add(
        Zip318ScheduledTransfer(
          denominationZatoshis: part,
          feeZatoshis: canonicalFeeZatoshis,
          broadcastHeight: height,
          expiryHeight: canonicalExpiryHeight(height, params),
        ),
      );
    }
    return Zip318Schedule(
      transfers: transfers,
      residualZatoshis: decomposition.residualZatoshis,
      parameters: params,
      startHeight: start,
    );
  }
}

class Zip318PreparationSchedule {
  const Zip318PreparationSchedule({
    required this.broadcastHeights,
    required this.actionsPerTransaction,
    required this.parameters,
  });

  final List<int> broadcastHeights;

  final int actionsPerTransaction;

  final Zip318Parameters parameters;

  int get transactionCount => broadcastHeights.length;

  /// When the funding notes are expected to exist: the last preparation
  /// broadcast plus [Zip318Parameters.prepMiningMarginBlocks]. Null with no
  /// preparation, where the funding notes' own height is the answer.
  int? get estimatedFundingNoteHeight => broadcastHeights.isEmpty
      ? null
      : broadcastHeights.last + parameters.prepMiningMarginBlocks;

  static Zip318PreparationSchedule plan({
    required int transactionCount,
    required int startHeight,
    required Random rng,
    Zip318Parameters parameters = Zip318Parameters.provisional,
  }) {
    if (transactionCount < 0) {
      throw ZcashModelException('transactionCount must not be negative');
    }
    var height = startHeight;
    final heights = <int>[];
    for (var i = 0; i < transactionCount; i++) {
      height = parameters.blockSpacing.advance(
        height,
        _drawExponentialDelay(
          rng,
          meanBlocks: parameters.prepMeanDelayBlocks,
          maxBlocks: parameters.prepMaxDelayBlocks,
        ),
      );
      heights.add(height);
    }
    return Zip318PreparationSchedule(
      broadcastHeights: heights,
      actionsPerTransaction: parameters.prepActionsPerTransaction,
      parameters: parameters,
    );
  }
}

class Zip318ConsentChecklist {
  const Zip318ConsentChecklist({
    this.disclosedPoolCrossingAmounts = false,
    this.displayedOrchardBalanceAtRisk = false,
    this.confirmedFullSchedule = false,
    this.presentedNetworkPrivacyOptions = false,
    this.separatesSyncFromBroadcast = false,
    this.limitsOverdueCatchUp = false,
  });

  /// User consented to publicly revealing pool-crossing amounts (ZIP 315).
  final bool disclosedPoolCrossingAmounts;

  final bool displayedOrchardBalanceAtRisk;

  final bool confirmedFullSchedule;

  final bool presentedNetworkPrivacyOptions;

  final bool separatesSyncFromBroadcast;

  final bool limitsOverdueCatchUp;

  List<String> get unmetRequirements => [
    if (!disclosedPoolCrossingAmounts) 'disclosedPoolCrossingAmounts',
    if (!displayedOrchardBalanceAtRisk) 'displayedOrchardBalanceAtRisk',
    if (!confirmedFullSchedule) 'confirmedFullSchedule',
    if (!presentedNetworkPrivacyOptions) 'presentedNetworkPrivacyOptions',
    if (!separatesSyncFromBroadcast) 'separatesSyncFromBroadcast',
    if (!limitsOverdueCatchUp) 'limitsOverdueCatchUp',
  ];

  bool get isSatisfied => unmetRequirements.isEmpty;
}

/// A draw may round to 0 (same block); ZIP 318 permits that.
int _drawExponentialDelay(
  Random rng, {
  required int meanBlocks,
  required int maxBlocks,
}) {
  for (var attempt = 0; attempt < 10000; attempt++) {
    final u = 1.0 - rng.nextDouble();
    final delay = (-log(u) * meanBlocks).round();
    if (delay <= maxBlocks) return delay;
  }
  throw ZcashModelException(
    'could not draw a delay within maxBlocks; check the parameter set',
  );
}
