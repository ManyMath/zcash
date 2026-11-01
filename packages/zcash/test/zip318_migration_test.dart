import 'dart:math';

import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

const int zec = 100000000;

/// ZIP 317 fee of a canonical migration: three logical actions at 5000.
const int canonicalFee = 15000;

void main() {
  final denominations = const Zip318Denominations();

  group('canonical denominations', () {
    test('are exactly n x 10^k ZEC for n in {1, 2, 5} within the bounds', () {
      final canonical = denominations.canonical;
      expect(canonical.first, zec ~/ 100, reason: 'MAX_RESIDUAL_VALUE floor');
      expect(canonical.last, 10000 * zec, reason: 'DENOM_CAP ceiling');
      for (final value in canonical) {
        var reduced = value;
        while (reduced % 10 == 0) {
          reduced ~/= 10;
        }
        expect(
          reduced,
          anyOf(1, 2, 5),
          reason: '$value is not of the form n x 10^k with n in {1,2,5}',
        );
      }
      for (var i = 1; i < canonical.length; i++) {
        expect(canonical[i], greaterThan(canonical[i - 1]));
      }
      expect(canonical.contains(20000 * zec), isFalse);
    });

    test('recognises canonical values and rejects near-misses', () {
      expect(denominations.isCanonical(5 * zec), isTrue);
      expect(denominations.isCanonical(zec ~/ 100), isTrue);
      expect(denominations.isCanonical(3 * zec), isFalse);
      expect(denominations.isCanonical(zec ~/ 1000), isFalse);
    });
  });

  group('decomposition', () {
    test("matches ZIP 318's own worked examples", () {
      expect(denominations.decompose((123.45 * zec).round()).parts, [
        100 * zec,
        20 * zec,
        2 * zec,
        1 * zec,
        (0.2 * zec).round(),
        (0.2 * zec).round(),
        (0.05 * zec).round(),
      ]);
      expect(denominations.decompose(540 * zec).parts, [
        500 * zec,
        20 * zec,
        20 * zec,
      ]);
      expect(denominations.decompose(25000 * zec).parts, [
        10000 * zec,
        10000 * zec,
        5000 * zec,
      ]);
    });

    test('expands each digit greedily from {5, 2, 1}', () {
      expect(denominations.decompose(9 * zec).parts, [
        5 * zec,
        2 * zec,
        2 * zec,
      ]);
      expect(denominations.decompose(8 * zec).parts, [
        5 * zec,
        2 * zec,
        1 * zec,
      ]);
      expect(denominations.decompose(7 * zec).parts, [5 * zec, 2 * zec]);
      expect(denominations.decompose(6 * zec).parts, [5 * zec, 1 * zec]);
      expect(denominations.decompose(4 * zec).parts, [2 * zec, 2 * zec]);
      expect(denominations.decompose(3 * zec).parts, [2 * zec, 1 * zec]);
    });

    test('leaves sub-MAX_RESIDUAL_VALUE balance unmigrated', () {
      final result = denominations.decompose((1.234 * zec).round());
      expect(result.residualZatoshis, (0.004 * zec).round());
      expect(result.migratedZatoshis, (1.23 * zec).round());
      expect(result.residualZatoshis, lessThan(zec ~/ 100));
      for (final part in result.parts) {
        expect(denominations.isCanonical(part), isTrue);
      }
    });

    test('leaves an entirely sub-threshold balance wholly unmigrated', () {
      final result = denominations.decompose((0.009 * zec).round());
      expect(result.parts, isEmpty);
      expect(result.residualZatoshis, (0.009 * zec).round());
      expect(result.transferCount, 0);
    });

    test('every part is canonical and the total is conserved', () {
      final rng = Random(7);
      for (var i = 0; i < 200; i++) {
        final amount = rng.nextInt(50000) * zec + rng.nextInt(zec);
        final result = denominations.decompose(amount);
        for (final part in result.parts) {
          expect(
            denominations.isCanonical(part),
            isTrue,
            reason: 'non-canonical part ${result.parts} for $amount',
          );
        }
        expect(
          result.migratedZatoshis + result.residualZatoshis,
          amount,
          reason: 'value must be conserved for $amount',
        );
      }
    });

    test('rejects a negative or impossible value', () {
      expect(
        () => denominations.decompose(-1),
        throwsA(isA<ZcashModelException>()),
      );
      expect(
        () => denominations.decompose(22000000 * zec),
        throwsA(isA<ZcashModelException>()),
      );
    });

    test('randomized decomposition conserves value and stays canonical', () {
      final rng = Random(11);
      for (var i = 0; i < 100; i++) {
        final amount = rng.nextInt(5000) * zec + rng.nextInt(zec);
        final result = denominations.decomposeRandomized(amount, rng);
        for (final part in result.parts) {
          expect(denominations.isCanonical(part), isTrue);
        }
        expect(result.migratedZatoshis + result.residualZatoshis, amount);
      }
    });

    test('randomized decomposition never exceeds DENOM_CAP', () {
      final rng = Random(41);
      for (var i = 0; i < 200; i++) {
        final result = denominations.decomposeRandomized(25000 * zec, rng);
        for (final part in result.parts) {
          expect(denominations.isCanonical(part), isTrue, reason: '$part');
        }
        expect(result.migratedZatoshis, 25000 * zec);
      }
    });

    test('randomized decomposition uses the ZIP 318 frequencies', () {
      final rng = Random(43);
      const trials = 4000;
      var oneOfOneTwo = 0;
      var oneOfAll = 0;
      var twoOfAll = 0;
      for (var i = 0; i < trials; i++) {
        // Only {1, 2} ZEC fit under 2 ZEC; all of {1, 2, 5} fit under 5.
        if (denominations.decomposeRandomized(2 * zec, rng).parts.first ==
            zec) {
          oneOfOneTwo++;
        }
        final first = denominations.decomposeRandomized(5 * zec, rng).parts;
        if (first.first == zec) oneOfAll++;
        if (first.first == 2 * zec) twoOfAll++;
      }
      expect(oneOfOneTwo / trials, closeTo(0.25, 0.03));
      expect(oneOfAll / trials, closeTo(0.10, 0.02));
      expect(twoOfAll / trials, closeTo(0.25, 0.03));
    });

    test('reports funding note values as denomination plus fee', () {
      final result = denominations.decompose(7 * zec);
      expect(result.transferCount, 2);
      expect(result.totalFeeZatoshis(canonicalFee), 2 * canonicalFee);
      expect(result.fundingNoteValues(canonicalFee), [
        5 * zec + canonicalFee,
        2 * zec + canonicalFee,
      ]);
    });
  });

  group('boundary anchors', () {
    const selection = Zip318AnchorSelection();
    const activation = 3428143;

    test('boundaries fall on multiples of M', () {
      expect(selection.boundaryAtOrBelow(3456000), 3456000);
      expect(selection.boundaryAtOrBelow(3456001), 3456000);
      expect(selection.boundaryAtOrBelow(3456143), 3456000);
      expect(selection.boundaryAtOrBelow(3456144), 3456144);
      for (final height in [3456000, 3456144, 3456288]) {
        expect(height % 144, 0);
      }
    });

    test('candidates are bounded by activation, note height, and tip', () {
      final candidates = selection.candidates(
        activationHeight: activation,
        fundingNoteHeight: 3456000,
        observedTipHeight: 3456500,
      );
      expect(candidates, isNotEmpty);
      expect(candidates.first, greaterThanOrEqualTo(3456000));
      expect(candidates.last, selection.boundaryAtOrBelow(3456500));
      for (final height in candidates) {
        expect(height % 144, 0);
        expect(height, greaterThan(activation));
      }
    });

    test('drawn anchors are always boundaries aged 1 to the cap', () {
      final rng = Random(3);
      final newest = selection.boundaryAtOrBelow(3500000);
      for (var i = 0; i < 300; i++) {
        final anchor = selection.drawAnchorHeight(
          activationHeight: activation,
          fundingNoteHeight: 3450000,
          observedTipHeight: 3500000,
          rng: rng,
        );
        expect(anchor % 144, 0, reason: 'anchor must be a boundary');
        expect(anchor, lessThan(newest), reason: 'age 0 is never drawn');
        final age = (newest - anchor) ~/ 144;
        expect(age, inInclusiveRange(1, 4));
      }
    });

    test('the draw is recency-weighted, not uniform', () {
      final rng = Random(5);
      final newest = selection.boundaryAtOrBelow(3500000);
      var atAgeOne = 0;
      const trials = 2000;
      for (var i = 0; i < trials; i++) {
        final anchor = selection.drawAnchorHeight(
          activationHeight: activation,
          fundingNoteHeight: 3450000,
          observedTipHeight: 3500000,
          rng: rng,
        );
        if (anchor == newest - 144) atAgeOne++;
      }
      // Geometric(1/2) truncated to [1, 4]: P(1) = 8/15.
      expect(atAgeOne / trials, closeTo(8 / 15, 0.05));
    });

    test('truncates the age to the candidate set', () {
      final rng = Random(9);
      for (var i = 0; i < 50; i++) {
        // Candidates 3456000 and 3456144; only age 1 is admissible.
        expect(
          selection.drawAnchorHeight(
            activationHeight: activation,
            fundingNoteHeight: 3456000,
            observedTipHeight: 3456200,
            rng: rng,
          ),
          3456000,
        );
      }
    });

    test('rounds up to boundaries', () {
      expect(selection.boundaryAtOrAbove(3456000), 3456000);
      expect(selection.boundaryAtOrAbove(3456001), 3456144);
      expect(selection.boundaryAfter(3456000), 3456144);
      expect(selection.boundaryAfter(3455999), 3456000);
    });

    test('defaults the activation height to the parameter set', () {
      expect(
        selection.candidates(fundingNoteHeight: 0, observedTipHeight: 3428500),
        selection.candidates(
          activationHeight: activation,
          fundingNoteHeight: 0,
          observedTipHeight: 3428500,
        ),
      );
    });

    test('counts the age from the broadcast when proved ahead of it', () {
      final rng = Random(73);
      // Observed boundary 3499920; the broadcast's is two boundaries later,
      // so only ages 3 and 4 from it are both observed and within the cap.
      final drawn = <int>{};
      for (var i = 0; i < 200; i++) {
        drawn.add(
          selection.drawAnchorHeight(
            fundingNoteHeight: 3450000,
            observedTipHeight: 3500000,
            broadcastHeight: 3500300,
            rng: rng,
          ),
        );
      }
      expect(drawn, {3499776, 3499632});
      expect(
        () => selection.drawAnchorHeight(
          fundingNoteHeight: 3450000,
          observedTipHeight: 3500000,
          broadcastHeight: 3500000 + 6 * 144,
          rng: rng,
        ),
        throwsA(isA<ZcashModelException>()),
      );
    });

    test('refuses to anchor when no boundary is available yet', () {
      expect(
        () => selection.drawAnchorHeight(
          activationHeight: activation,
          fundingNoteHeight: 3456100,
          observedTipHeight: 3456143,
          rng: Random(1),
        ),
        throwsA(isA<ZcashModelException>()),
      );
      // The most recent boundary alone is age 0, which is never used.
      expect(
        () => selection.drawAnchorHeight(
          activationHeight: activation,
          fundingNoteHeight: 3456000,
          observedTipHeight: 3456143,
          rng: Random(1),
        ),
        throwsA(isA<ZcashModelException>()),
      );
    });
  });

  group('phase-2 schedule', () {
    test('delays are positive-ish, bounded by MAX_DELAY, and cumulative', () {
      final decomposition = denominations.decompose(1234 * zec);
      final schedule = Zip318Schedule.plan(
        decomposition: decomposition,
        startHeight: 3500000,
        canonicalFeeZatoshis: canonicalFee,
        fundingNoteHeight: 3499000,
        rng: Random(13),
      );
      expect(schedule.transfers, hasLength(decomposition.transferCount));
      var previous = 3500000;
      for (final transfer in schedule.transfers) {
        final delay = transfer.broadcastHeight - previous;
        expect(delay, inInclusiveRange(0, 576));
        previous = transfer.broadcastHeight;
      }
      expect(schedule.finalBroadcastHeight, previous);
    });

    test('preserves the multiset of denominations but shuffles the order', () {
      final decomposition = denominations.decompose(9876 * zec);
      final schedule = Zip318Schedule.plan(
        decomposition: decomposition,
        startHeight: 3500000,
        canonicalFeeZatoshis: canonicalFee,
        fundingNoteHeight: 3499000,
        rng: Random(17),
      );
      final scheduled = schedule.transfers
          .map((t) => t.denominationZatoshis)
          .toList();
      expect(scheduled..sort(), (List<int>.from(decomposition.parts))..sort());
      expect(schedule.totalMigratedZatoshis, decomposition.migratedZatoshis);
      expect(
        schedule.totalFeeZatoshis,
        decomposition.transferCount * canonicalFee,
      );

      final descending = List<int>.from(decomposition.parts)
        ..sort((a, b) => b.compareTo(a));
      expect(
        schedule.transfers.map((t) => t.denominationZatoshis).toList(),
        isNot(descending),
      );
    });

    test('delays have mean MEAN_DELAY', () {
      final schedule = Zip318Schedule.plan(
        decomposition: Zip318Decomposition(
          parts: List.filled(4000, zec),
          residualZatoshis: 0,
          parameters: Zip318Parameters.provisional,
        ),
        startHeight: 0,
        canonicalFeeZatoshis: canonicalFee,
        fundingNoteHeight: 0,
        activationHeight: 0,
        rng: Random(53),
        parameters: const Zip318Parameters(),
      );
      expect(
        (schedule.finalBroadcastHeight! - schedule.startHeight!) / 4000,
        closeTo(66, 4),
      );
    });

    test('keeps a start already past the bound', () {
      final schedule = Zip318Schedule.plan(
        decomposition: denominations.decompose(100 * zec),
        startHeight: 3500000,
        canonicalFeeZatoshis: canonicalFee,
        fundingNoteHeight: 3499000,
        rng: Random(19),
      );
      expect(schedule.startHeight, 3500000);
    });

    test(
      'canonical expiry is a shared rolling window, not a per-wallet one',
      () {
        const modulus = 34560;
        final first = Zip318Schedule.canonicalExpiryHeight(3500000);
        final second = Zip318Schedule.canonicalExpiryHeight(3500001);
        expect(first, second);
        expect(first % modulus, 0);
        expect(first - 3500000, greaterThan(modulus));
        expect(first - 3500000, lessThanOrEqualTo(2 * modulus));
        final next = Zip318Schedule.canonicalExpiryHeight(3500000 + modulus);
        expect(next, first + modulus);
      },
    );

    test('surfaces overdue transfers without draining them', () {
      final schedule = Zip318Schedule.plan(
        decomposition: denominations.decompose(1234 * zec),
        startHeight: 3500000,
        canonicalFeeZatoshis: canonicalFee,
        fundingNoteHeight: 3499000,
        rng: Random(23),
      );
      expect(schedule.transfers.length, greaterThan(2));
      final past = schedule.transfers[1].broadcastHeight + 1;
      final overdue = schedule.overdueAt(past);
      expect(overdue, isNotEmpty);
      expect(overdue.length, lessThan(schedule.transfers.length));
      for (final transfer in overdue) {
        expect(transfer.isOverdueAt(past), isTrue);
      }
      expect(schedule.overdueAt(3499999), isEmpty);
    });

    test('raises the start to the boundary after the lowest candidate', () {
      // Funding at 3456100: the lowest candidate is 3456144, so every
      // transfer has 3456144 at age 1 or more from 3456288 on.
      expect(
        Zip318Schedule.earliestStartHeight(fundingNoteHeight: 3456100),
        3456288,
      );
      final schedule = Zip318Schedule.plan(
        decomposition: denominations.decompose(1234 * zec),
        startHeight: 3456000,
        canonicalFeeZatoshis: canonicalFee,
        fundingNoteHeight: 3456100,
        rng: Random(61),
      );
      expect(schedule.startHeight, 3456288);
      const grid = Zip318AnchorSelection();
      for (final transfer in schedule.transfers) {
        expect(transfer.broadcastHeight, greaterThanOrEqualTo(3456288));
        expect(
          grid.candidates(
            fundingNoteHeight: 3456100,
            observedTipHeight: transfer.broadcastHeight,
          ),
          hasLength(greaterThanOrEqualTo(2)),
          reason: 'an age-1 anchor must exist at every broadcast',
        );
      }
    });

    test('raising the start preserves the drawn gaps', () {
      Zip318Schedule planFrom(int start) => Zip318Schedule.plan(
        decomposition: denominations.decompose(987 * zec),
        startHeight: start,
        canonicalFeeZatoshis: canonicalFee,
        fundingNoteHeight: 3456100,
        rng: Random(67),
      );
      final raised = planFrom(3400000);
      final atBound = planFrom(3456288);
      expect(
        raised.transfers.map((t) => t.broadcastHeight),
        atBound.transfers.map((t) => t.broadcastHeight),
      );
    });

    test('bounds the start by NU6.3 activation just before and after it', () {
      const activation = 3428143;
      // The first boundary above activation is 3428208, whether the note
      // was created before activation, at it, or just after it.
      for (final funding in [3428000, activation, activation + 1, 3428208]) {
        expect(
          const Zip318AnchorSelection().lowestCandidateBoundary(
            fundingNoteHeight: funding,
          ),
          3428208,
          reason: 'funding at $funding',
        );
        expect(
          Zip318Schedule.earliestStartHeight(fundingNoteHeight: funding),
          3428352,
        );
      }
      // One block past a boundary moves the lowest candidate a whole bucket.
      expect(
        Zip318Schedule.earliestStartHeight(fundingNoteHeight: 3428209),
        3428496,
      );
      // Activation on a boundary is not itself a candidate.
      expect(
        Zip318Schedule.earliestStartHeight(
          fundingNoteHeight: 0,
          activationHeight: 288,
          parameters: const Zip318Parameters(),
        ),
        576,
      );
    });

    test('needs an NU6.3 height when the parameters lack one', () {
      expect(
        () => Zip318Schedule.plan(
          decomposition: denominations.decompose(zec),
          startHeight: 100,
          canonicalFeeZatoshis: canonicalFee,
          fundingNoteHeight: 0,
          rng: Random(1),
          parameters: const Zip318Parameters(),
        ),
        throwsA(isA<ZcashModelException>()),
      );
    });

    test('a wholly sub-threshold balance schedules nothing', () {
      final decomposition = denominations.decompose((0.005 * zec).round());
      final schedule = Zip318Schedule.plan(
        decomposition: decomposition,
        startHeight: 3500000,
        canonicalFeeZatoshis: canonicalFee,
        fundingNoteHeight: 3499000,
        rng: Random(29),
      );
      expect(schedule.transfers, isEmpty);
      expect(schedule.finalBroadcastHeight, isNull);
      expect(schedule.residualZatoshis, (0.005 * zec).round());
    });
  });

  group('phase-1 note preparation', () {
    test('spaces preparation broadcasts within PREP_MAX_DELAY', () {
      final schedule = Zip318PreparationSchedule.plan(
        transactionCount: 40,
        startHeight: 3400000,
        rng: Random(31),
      );
      expect(schedule.transactionCount, 40);
      expect(schedule.actionsPerTransaction, 16);
      var previous = 3400000;
      for (final height in schedule.broadcastHeights) {
        final delay = height - previous;
        expect(delay, inInclusiveRange(0, 96));
        previous = height;
      }
    });

    test('preparation delays have mean PREP_MEAN_DELAY', () {
      final schedule = Zip318PreparationSchedule.plan(
        transactionCount: 20000,
        startHeight: 0,
        rng: Random(47),
        parameters: const Zip318Parameters(),
      );
      // Redrawing above PREP_MAX_DELAY pulls the mean of 16 down to 15.76.
      expect(schedule.broadcastHeights.last / 20000, closeTo(15.76, 0.5));
    });

    test('estimates the funding height as last broadcast plus the margin', () {
      final schedule = Zip318PreparationSchedule.plan(
        transactionCount: 3,
        startHeight: 3400000,
        rng: Random(71),
      );
      expect(
        schedule.estimatedFundingNoteHeight,
        schedule.broadcastHeights.last + 10,
      );
      expect(
        Zip318PreparationSchedule.plan(
          transactionCount: 0,
          startHeight: 3400000,
          rng: Random(71),
        ).estimatedFundingNoteHeight,
        isNull,
        reason: 'with no preparation the notes give their own height',
      );
    });

    test('preparation is spaced far more tightly than migration', () {
      const params = Zip318Parameters.provisional;
      expect(params.prepMeanDelayBlocks, lessThan(params.meanDelayBlocks));
      expect(params.prepMaxDelayBlocks, lessThan(params.maxDelayBlocks));
    });

    test('rejects a negative count', () {
      expect(
        () => Zip318PreparationSchedule.plan(
          transactionCount: -1,
          startHeight: 1,
          rng: Random(1),
        ),
        throwsA(isA<ZcashModelException>()),
      );
    });
  });

  group('consent and behaviour', () {
    test('an empty checklist names every unmet requirement', () {
      const checklist = Zip318ConsentChecklist();
      expect(checklist.isSatisfied, isFalse);
      expect(
        checklist.unmetRequirements,
        containsAll([
          'disclosedPoolCrossingAmounts',
          'displayedOrchardBalanceAtRisk',
          'confirmedFullSchedule',
          'presentedNetworkPrivacyOptions',
          'separatesSyncFromBroadcast',
          'limitsOverdueCatchUp',
        ]),
      );
    });

    test('a partially-met checklist is not satisfied', () {
      const checklist = Zip318ConsentChecklist(
        disclosedPoolCrossingAmounts: true,
        displayedOrchardBalanceAtRisk: true,
        confirmedFullSchedule: true,
        presentedNetworkPrivacyOptions: true,
        separatesSyncFromBroadcast: true,
      );
      expect(checklist.isSatisfied, isFalse);
      expect(checklist.unmetRequirements, ['limitsOverdueCatchUp']);
    });

    test('a fully-met checklist is satisfied', () {
      const checklist = Zip318ConsentChecklist(
        disclosedPoolCrossingAmounts: true,
        displayedOrchardBalanceAtRisk: true,
        confirmedFullSchedule: true,
        presentedNetworkPrivacyOptions: true,
        separatesSyncFromBroadcast: true,
        limitsOverdueCatchUp: true,
      );
      expect(checklist.isSatisfied, isTrue);
      expect(checklist.unmetRequirements, isEmpty);
    });
  });

  group('parameters', () {
    test('are marked provisional', () {
      expect(Zip318Parameters.provisional.isProvisional, isTrue);
      expect(
        const Zip318Parameters(isProvisional: false).isProvisional,
        isFalse,
      );
    });

    test('carry the specified values', () {
      const params = Zip318Parameters.provisional;
      expect(params.maxResidualValueZatoshis, zec ~/ 100);
      expect(params.denomCapZatoshis, 10000 * zec);
      expect(params.meanDelayBlocks, 66);
      expect(params.maxDelayBlocks, 576);
      expect(params.anchorBoundaryModulus, 144);
      expect(params.anchorAgeCapBoundaries, 4);
      expect(params.expiryModulusBlocks, 34560);
      expect(params.prepMeanDelayBlocks, 16);
      expect(params.prepMaxDelayBlocks, 96);
      expect(params.prepActionsPerTransaction, 16);
      expect(params.prepMiningMarginBlocks, 10);
    });

    test('a substituted parameter set is honoured end to end', () {
      const tighter = Zip318Parameters(
        anchorBoundaryModulus: 100,
        meanDelayBlocks: 10,
        maxDelayBlocks: 20,
        isProvisional: false,
      );
      const selection = Zip318AnchorSelection(tighter);
      expect(selection.boundaryAtOrBelow(3456789), 3456700);

      final schedule = Zip318Schedule.plan(
        decomposition: const Zip318Denominations().decompose(100 * zec),
        startHeight: 1000,
        canonicalFeeZatoshis: canonicalFee,
        fundingNoteHeight: 0,
        activationHeight: 0,
        rng: Random(37),
        parameters: tighter,
      );
      var previous = 1000;
      for (final transfer in schedule.transfers) {
        expect(transfer.broadcastHeight - previous, inInclusiveRange(0, 20));
        previous = transfer.broadcastHeight;
      }
    });
  });

  group('NU7 block spacing', () {
    const mainnet = Zip318Parameters.mainnet;
    const uniform = Zip318Parameters();
    const nu7 = 3543405;

    test('presets carry the NU6.3 and NU7 activation heights', () {
      expect(Zip318Parameters.provisional.nu7ActivationHeight, nu7);
      expect(Zip318Parameters.testnet.nu7ActivationHeight, 4465026);
      expect(uniform.nu7ActivationHeight, isNull);
      expect(Zip318Parameters.mainnet.nu63ActivationHeight, 3428143);
      expect(Zip318Parameters.testnet.nu63ActivationHeight, 4134000);
      expect(uniform.nu63ActivationHeight, isNull);
    });

    test('forNetwork picks the preset for the network', () {
      expect(
        Zip318Parameters.forNetwork(ZcashConsensusNetwork.mainnet),
        same(Zip318Parameters.mainnet),
      );
      expect(
        Zip318Parameters.forNetwork(ZcashConsensusNetwork.testnet),
        same(Zip318Parameters.testnet),
      );
      expect(
        Zip318Parameters.forNetwork(
          ZcashConsensusNetwork.regtest,
        ).nu7ActivationHeight,
        isNull,
      );
      expect(
        Zip318Parameters.forNetwork(
          ZcashConsensusNetwork.regtest,
          regtestNu7ActivationHeight: 200,
        ).blockSpacing.advance(195, 10),
        215,
      );
      final regtest = Zip318Parameters.forNetwork(
        ZcashConsensusNetwork.regtest,
        regtestNu63ActivationHeight: 5,
      );
      expect(regtest.nu63ActivationHeight, 5);
      expect(
        Zip318Parameters.forNetwork(
          ZcashConsensusNetwork.regtest,
        ).nu63ActivationHeight,
        isNull,
      );
    });

    test('advance keeps a span the same length in time', () {
      expect(Zip318BlockSpacing.uniform.advance(100, 10), 110);
      final spacing = mainnet.blockSpacing;
      expect(spacing.advance(3500000, 10), 3500010);
      expect(spacing.advance(3600000, 10), 3600030);
      // Five reference blocks before activation, five (15 blocks) after.
      expect(spacing.advance(nu7 - 5, 10), nu7 + 15);
    });

    test('canonical expiry triples its modulus and window from NU7', () {
      expect(Zip318Schedule.canonicalExpiryHeight(3600000, mainnet), 3732480);
      expect(Zip318Schedule.canonicalExpiryHeight(3600000, uniform), 3663360);
      expect(
        Zip318Schedule.canonicalExpiryHeight(3500000, mainnet),
        Zip318Schedule.canonicalExpiryHeight(3500000, uniform),
      );
      expect(
        Zip318Schedule.canonicalExpiryHeight(4000000, Zip318Parameters.testnet),
        4043520,
      );
    });

    test('anchor boundaries are 432 blocks apart from NU7', () {
      const grid = Zip318AnchorSelection(mainnet);
      expect(grid.boundaryAtOrBelow(3600000), 3599856);
      expect(grid.isBoundary(3599856), isTrue);
      // A multiple of 144 but not of 432, after activation.
      expect(grid.isBoundary(3543552), isFalse);
      expect(grid.isBoundary(3543264), isTrue);
      // No boundary lies between activation and the first multiple of 432.
      expect(grid.boundaryAtOrBelow(3543500), 3543264);
      expect(grid.boundaryAtOrBelow(3543696), 3543696);
      expect(grid.boundaryBefore(3543696), 3543264);
      expect(
        grid.candidates(
          activationHeight: 3428143,
          fundingNoteHeight: 3542976,
          observedTipHeight: 3544000,
        ),
        [3542976, 3543120, 3543264, 3543696],
      );
    });

    test('rounds up across activation onto the post-NU7 grid', () {
      const grid = Zip318AnchorSelection(mainnet);
      // 3543408 is a multiple of 144 past activation, not a boundary.
      expect(grid.boundaryAtOrAbove(3543300), 3543696);
      expect(grid.boundaryAtOrAbove(3543200), 3543264);
      expect(grid.boundaryAfter(3543264), 3543696);
      expect(grid.boundaryAfter(3543696), 3544128);
    });

    test('the start bound follows the post-NU7 grid', () {
      expect(
        Zip318Schedule.earliestStartHeight(
          fundingNoteHeight: 3543200,
          parameters: mainnet,
        ),
        3543696,
      );
      expect(
        Zip318Schedule.earliestStartHeight(
          fundingNoteHeight: 3543300,
          parameters: mainnet,
        ),
        3544128,
      );
      // The mining margin is a block count: NU7 does not triple it.
      final prep = Zip318PreparationSchedule.plan(
        transactionCount: 2,
        startHeight: 3600000,
        rng: Random(79),
        parameters: mainnet,
      );
      expect(prep.estimatedFundingNoteHeight, prep.broadcastHeights.last + 10);
    });

    test('refuses a pre-NU7 grid anchor after activation', () {
      expect(
        () => Zip318BoundaryAnchors.at(
          boundaryHeight: 3543552,
          fetch: (_) async => throw StateError('must not fetch'),
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

    test('schedule delays scale to post-NU7 blocks', () {
      final schedule = Zip318Schedule.plan(
        decomposition: denominations.decompose(1234 * zec),
        startHeight: 3600000,
        canonicalFeeZatoshis: canonicalFee,
        fundingNoteHeight: 3599000,
        rng: Random(13),
        parameters: mainnet,
      );
      var previous = 3600000;
      for (final transfer in schedule.transfers) {
        final delay = transfer.broadcastHeight - previous;
        expect(delay % nu7PowTargetSpacingRatio, 0);
        expect(delay, inInclusiveRange(0, 3 * 576));
        expect(
          transfer.expiryHeight,
          Zip318Schedule.canonicalExpiryHeight(
            transfer.broadcastHeight,
            mainnet,
          ),
        );
        previous = transfer.broadcastHeight;
      }
    });
  });
}
