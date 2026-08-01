import 'dart:math';

import 'proposal.dart' show maxMoneyZatoshis;
import 'spend.dart';

// ZIP 318 is a Draft, so every constant here is provisional.

const int _zec = 100000000;

class Zip318Parameters {
  static const provisional = Zip318Parameters();

  const Zip318Parameters({
    this.maxResidualValueZatoshis = _zec ~/ 100,
    this.denomCapZatoshis = 10000 * _zec,
    this.meanDelayBlocks = 144,
    this.maxDelayBlocks = 576,
    this.anchorBoundaryModulus = 144,
    this.anchorAgeCapBoundaries = 16,
    this.expiryModulusBlocks = 34560,
    this.prepMeanDelayBlocks = 24,
    this.prepMaxDelayBlocks = 96,
    this.prepActionsPerTransaction = 16,
    this.isProvisional = true,
  });

  final int maxResidualValueZatoshis;

  final int denomCapZatoshis;

  final int meanDelayBlocks;

  final int maxDelayBlocks;

  final int anchorBoundaryModulus;

  final int anchorAgeCapBoundaries;

  final int expiryModulusBlocks;

  final int prepMeanDelayBlocks;

  final int prepMaxDelayBlocks;

  final int prepActionsPerTransaction;

  final bool isProvisional;
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
      int chosen;
      if (roll < 0.10 && place <= remaining) {
        chosen = place;
      } else if (roll < 0.35 && 2 * place <= remaining) {
        chosen = 2 * place;
      } else {
        chosen = largest;
      }
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

  int boundaryAtOrBelow(int height) =>
      (height ~/ parameters.anchorBoundaryModulus) *
      parameters.anchorBoundaryModulus;

  List<int> candidates({
    required int activationHeight,
    required int fundingNoteHeight,
    required int observedTipHeight,
  }) {
    final newest = boundaryAtOrBelow(observedTipHeight);
    final floor = max(activationHeight + 1, fundingNoteHeight);
    final out = <int>[];
    for (
      var h = newest;
      h >= floor && h > 0;
      h -= parameters.anchorBoundaryModulus
    ) {
      out.add(h);
    }
    return out.reversed.toList(growable: false);
  }

  int drawAnchorHeight({
    required int activationHeight,
    required int fundingNoteHeight,
    required int observedTipHeight,
    required Random rng,
  }) {
    final candidateHeights = candidates(
      activationHeight: activationHeight,
      fundingNoteHeight: fundingNoteHeight,
      observedTipHeight: observedTipHeight,
    );
    if (candidateHeights.isEmpty) {
      throw ZcashModelException(
        'no canonical boundary anchor is available yet for this funding note; '
        'wait for the next boundary rather than anchoring at the chain tip',
      );
    }
    final newest = boundaryAtOrBelow(observedTipHeight);
    final allowed = candidateHeights.toSet();
    for (var attempt = 0; attempt < 1000; attempt++) {
      final age = _drawGeometric(rng);
      if (age > parameters.anchorAgeCapBoundaries) continue;
      final height = newest - (age - 1) * parameters.anchorBoundaryModulus;
      if (allowed.contains(height)) return height;
    }
    throw ZcashModelException(
      'could not draw a boundary anchor within the age cap; the candidate set '
      'is too sparse for the configured parameters',
    );
  }

  static int _drawGeometric(Random rng) {
    var a = 1;
    while (!rng.nextBool() && a < 64) {
      a++;
    }
    return a;
  }
}

class Zip318ScheduledTransfer {
  const Zip318ScheduledTransfer({
    required this.denominationZatoshis,
    required this.feeZatoshis,
    required this.broadcastHeight,
    required this.anchorHeight,
    required this.expiryHeight,
  });

  final int denominationZatoshis;

  final int feeZatoshis;

  final int broadcastHeight;

  final int anchorHeight;

  final int expiryHeight;

  int get fundingNoteValueZatoshis => denominationZatoshis + feeZatoshis;

  bool isOverdueAt(int chainHeight) => chainHeight > broadcastHeight;
}

class Zip318Schedule {
  const Zip318Schedule({
    required this.transfers,
    required this.residualZatoshis,
    required this.parameters,
  });

  final List<Zip318ScheduledTransfer> transfers;

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
    final modulus = parameters.expiryModulusBlocks;
    return (broadcastHeight ~/ modulus) * modulus + 2 * modulus;
  }

  static Zip318Schedule plan({
    required Zip318Decomposition decomposition,
    required int startHeight,
    required int canonicalFeeZatoshis,
    required int anchorHeight,
    required Random rng,
    Zip318Parameters? parameters,
  }) {
    final params = parameters ?? decomposition.parameters;
    final parts = List<int>.from(decomposition.parts);
    parts.shuffle(rng);

    var height = startHeight;
    final transfers = <Zip318ScheduledTransfer>[];
    for (final part in parts) {
      height += _drawExponentialDelay(
        rng,
        meanBlocks: params.meanDelayBlocks,
        maxBlocks: params.maxDelayBlocks,
      );
      transfers.add(
        Zip318ScheduledTransfer(
          denominationZatoshis: part,
          feeZatoshis: canonicalFeeZatoshis,
          broadcastHeight: height,
          anchorHeight: anchorHeight,
          expiryHeight: canonicalExpiryHeight(height, params),
        ),
      );
    }
    return Zip318Schedule(
      transfers: transfers,
      residualZatoshis: decomposition.residualZatoshis,
      parameters: params,
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
      height += _drawExponentialDelay(
        rng,
        meanBlocks: parameters.prepMeanDelayBlocks,
        maxBlocks: parameters.prepMaxDelayBlocks,
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
