import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

// Mined after NU6.3 activation (3428143); its candidates start at 3428208.
const noteHeight = 3428200;

ZcashScannedNote orchardNote(
  int value, {
  String pool = 'orchard',
  int height = noteHeight,
}) => ZcashScannedNote.fromJson({
  'height': height,
  'tx': 'aa' * 32,
  'output': 0,
  'value': value,
  'pool': pool,
  'recipient': 'uregtest1note',
  'rseed': '2a' * 32,
  'rho': '3b' * 32,
  'note_version': pool == 'ironwood' ? 'v3' : 'v2',
  'witness': 'aabbcc',
}, allowExperimentalOrchardNotes: true);

ZcashScannedNote bareNote(int value) => ZcashScannedNote.fromJson({
  'height': 3428400,
  'tx': 'bb' * 32,
  'output': 0,
  'value': value,
  'pool': 'orchard',
}, allowExperimentalOrchardNotes: true);

const denomination = 10000000;
const fee = 15000;
const funding = denomination + fee;

Zip318ScheduledTransfer transfer({
  int broadcastHeight = 3428600,
  Zip318Parameters parameters = Zip318Parameters.provisional,
}) => Zip318ScheduledTransfer(
  denominationZatoshis: denomination,
  feeZatoshis: fee,
  broadcastHeight: broadcastHeight,
  expiryHeight: Zip318Schedule.canonicalExpiryHeight(
    broadcastHeight,
    parameters,
  ),
);

// At tip 3428599 the most recent boundary is 3428496, so 3428352 is age 1.
const anchorHeight = 3428352;
const tipHeight = 3428599;

Matcher refusal(Zip318PlanRefusal expected) => throwsA(
  isA<Zip318PlanException>().having((e) => e.refusal, 'refusal', expected),
);

void main() {
  group('Zip318FundingSelection', () {
    test('prefers the exact-value note phase 1 produces', () {
      final selection = Zip318FundingSelection.select(
        transfer: transfer(),
        notes: [orchardNote(funding * 3), orchardNote(funding)],
      );
      expect(selection.isExact, isTrue);
      expect(selection.note.value, funding);
      expect(selection.changeZatoshis, 0);
    });

    test('falls back to the smallest covering note, with change', () {
      final selection = Zip318FundingSelection.select(
        transfer: transfer(),
        notes: [orchardNote(funding * 5), orchardNote(funding + 700)],
      );
      expect(selection.isExact, isFalse);
      expect(selection.note.value, funding + 700);
      expect(selection.changeZatoshis, 700);
    });

    test('refuses to invent an exact note when asked for one', () {
      expect(
        () => Zip318FundingSelection.select(
          transfer: transfer(),
          notes: [orchardNote(funding + 1)],
          requireExact: true,
        ),
        throwsA(
          isA<Zip318PlanException>().having(
            (e) => e.refusal,
            'refusal',
            Zip318PlanRefusal.notYetFunded,
          ),
        ),
      );
    });

    test('ignores other pools rather than spending them', () {
      expect(
        () => Zip318FundingSelection.select(
          transfer: transfer(),
          notes: [
            orchardNote(funding * 2, pool: 'ironwood'),
            orchardNote(funding * 2, pool: 'sapling'),
          ],
        ),
        throwsA(
          isA<Zip318PlanException>().having(
            (e) => e.refusal,
            'refusal',
            Zip318PlanRefusal.insufficientOrchardBalance,
          ),
        ),
      );
    });

    test('reports a note that cannot be spent rather than skipping it', () {
      expect(
        () => Zip318FundingSelection.select(
          transfer: transfer(),
          notes: [bareNote(funding)],
        ),
        throwsA(
          isA<Zip318PlanException>().having(
            (e) => e.refusal,
            'refusal',
            Zip318PlanRefusal.incompleteNote,
          ),
        ),
      );
    });
  });

  group('Zip318TransferPlan', () {
    Zip318TransferPlan plan({
      Zip318ScheduledTransfer? scheduled,
      Zip318FundingSelection? funded,
      int anchor = anchorHeight,
      int tip = tipHeight,
      int fundedAt = noteHeight,
      String? orchardAnchor,
      String? ironwoodAnchor,
      Zip318Parameters parameters = Zip318Parameters.provisional,
    }) {
      final t = scheduled ?? transfer();
      return Zip318TransferPlan.forTransfer(
        transfer: t,
        funding:
            funded ??
            Zip318FundingSelection.select(
              transfer: t,
              notes: [orchardNote(funding, height: fundedAt)],
            ),
        anchorHeight: anchor,
        orchardAnchorHex: orchardAnchor ?? 'cd' * 32,
        ironwoodAnchorHex: ironwoodAnchor ?? 'ef' * 32,
        observedTipHeight: tip,
        recipientAddress: 'uregtest1self',
        parameters: parameters,
      );
    }

    test('takes every canonical field from the schedule', () {
      final p = plan();
      expect(p.targetHeight, 3428600);
      expect(p.anchorHeight, anchorHeight);
      expect(p.observedTipHeight, tipHeight);
      expect(p.expiryHeight, Zip318Schedule.canonicalExpiryHeight(3428600));
      expect(p.ironwoodOutputZatoshis, denomination);
      expect(p.feeZatoshis, fee);
      expect(p.orchardChangeZatoshis, isNull);
    });

    test('carries the change amount when the funding note is inexact', () {
      final t = transfer();
      final p = plan(
        scheduled: t,
        funded: Zip318FundingSelection.select(
          transfer: t,
          notes: [orchardNote(funding + 2500)],
        ),
      );
      expect(p.orchardChangeZatoshis, 2500);
      expect(p.ironwoodOutputZatoshis, denomination);
    });

    test('refuses an anchor height off the boundary', () {
      expect(
        () => plan(anchor: anchorHeight + 1),
        refusal(Zip318PlanRefusal.anchorOffBoundary),
      );
    });

    test('refuses an anchor at or below NU6.3 activation', () {
      // 3428064 is a boundary, but below activation at 3428143.
      expect(
        () => plan(anchor: 3428064, tip: 3428400, fundedAt: 3428000),
        refusal(Zip318PlanRefusal.anchorBeforeActivation),
      );
      expect(
        () => plan(
          anchor: 288,
          tip: 600,
          fundedAt: 100,
          scheduled: transfer(broadcastHeight: 600),
          parameters: const Zip318Parameters(nu63ActivationHeight: 288),
        ),
        refusal(Zip318PlanRefusal.anchorBeforeActivation),
        reason: 'activation itself is not above activation',
      );
    });

    test('refuses an anchor that predates the funding note', () {
      expect(
        () => plan(fundedAt: anchorHeight + 1),
        refusal(Zip318PlanRefusal.anchorBeforeFundingNote),
      );
      // A note mined in the boundary block is in that boundary's tree.
      expect(() => plan(fundedAt: anchorHeight), returnsNormally);
    });

    test('refuses an anchor above the most recent observed boundary', () {
      expect(
        () => plan(anchor: 3428640),
        refusal(Zip318PlanRefusal.anchorNotObserved),
      );
    });

    test('refuses the most recent observed boundary (age 0)', () {
      expect(
        () => plan(anchor: 3428496),
        refusal(Zip318PlanRefusal.anchorAgeOutOfRange),
      );
    });

    test('accepts an anchor at the age cap and refuses one past it', () {
      // At tip 3428800 the most recent boundary is 3428784: 3428208 is age 4.
      expect(plan(anchor: 3428208, tip: 3428800).anchorHeight, 3428208);
      // At tip 3428928 the same anchor is age 5.
      expect(
        () => plan(anchor: 3428208, tip: 3428928),
        refusal(Zip318PlanRefusal.anchorAgeOutOfRange),
      );
    });

    test('counts the age from the broadcast when proved ahead of it', () {
      // The broadcast's boundary is 3428928: 3428352 is age 4, 3428208 age 5.
      final early = transfer(broadcastHeight: 3429000);
      expect(plan(scheduled: early).targetHeight, 3429000);
      expect(
        () => plan(scheduled: early, anchor: 3428208),
        refusal(Zip318PlanRefusal.anchorAgeOutOfRange),
      );
    });

    test('needs an NU6.3 height when the parameters lack one', () {
      expect(
        () => plan(parameters: const Zip318Parameters()),
        throwsA(isA<ZcashModelException>()),
      );
      expect(
        () => Zip318TransferPlan.forTransfer(
          transfer: transfer(),
          funding: Zip318FundingSelection.select(
            transfer: transfer(),
            notes: [orchardNote(funding)],
          ),
          anchorHeight: anchorHeight,
          orchardAnchorHex: 'cd' * 32,
          ironwoodAnchorHex: 'ef' * 32,
          observedTipHeight: tipHeight,
          recipientAddress: 'uregtest1self',
          activationHeight: 3428143,
          parameters: const Zip318Parameters(),
        ),
        returnsNormally,
      );
    });

    test('builds a late transfer for the next block, keeping its expiry', () {
      final p = plan(anchor: 3428496, tip: 3428800);
      expect(p.targetHeight, 3428801);
      expect(p.expiryHeight, Zip318Schedule.canonicalExpiryHeight(3428600));
    });

    test('a transfer scheduled before NU7 and built after it takes the NU7 '
        'target but keeps its pre-NU7 expiry', () {
      const mainnet = Zip318Parameters.mainnet;
      final scheduled = transfer(broadcastHeight: 3543300, parameters: mainnet);
      // At tip 3543500 the most recent boundary is 3543264; 3543120 is age 1.
      final p = plan(
        scheduled: scheduled,
        anchor: 3543120,
        tip: 3543500,
        fundedAt: 3542000,
        parameters: mainnet,
      );
      expect(
        p.targetHeight,
        greaterThanOrEqualTo(mainnet.nu7ActivationHeight!),
      );
      expect(p.expiryHeight, 3594240);
      expect(p.expiryHeight, scheduled.expiryHeight);
    });

    test('refuses to build once the expiry has passed', () {
      final expiry = Zip318Schedule.canonicalExpiryHeight(3428600);
      // At tip `expiry` (a boundary) the next block is past the expiry.
      expect(
        () => plan(anchor: expiry - 144, tip: expiry),
        refusal(Zip318PlanRefusal.offSchedule),
      );
      expect(plan(anchor: expiry - 288, tip: expiry - 1).targetHeight, expiry);
    });

    test(
      'refuses a note that does not cover denomination, fee, and change',
      () {
        final t = transfer();
        expect(
          () => plan(
            scheduled: t,
            funded: Zip318FundingSelection(
              note: orchardNote(funding + 900),
              changeZatoshis: 0,
            ),
          ),
          throwsA(
            isA<Zip318PlanException>().having(
              (e) => e.refusal,
              'refusal',
              Zip318PlanRefusal.notYetFunded,
            ),
          ),
        );
      },
    );

    test('refuses a note from the wrong pool', () {
      expect(
        () => plan(
          funded: Zip318FundingSelection(
            note: orchardNote(funding, pool: 'ironwood'),
            changeZatoshis: 0,
          ),
        ),
        throwsA(
          isA<Zip318PlanException>().having(
            (e) => e.refusal,
            'refusal',
            Zip318PlanRefusal.wrongPool,
          ),
        ),
      );
    });

    test('refuses a malformed anchor', () {
      expect(
        () => plan(ironwoodAnchor: 'ef' * 16),
        throwsA(
          isA<Zip318PlanException>().having(
            (e) => e.refusal,
            'refusal',
            Zip318PlanRefusal.malformedAnchor,
          ),
        ),
      );
    });

    test('holds a plan back until its scheduled height', () {
      final p = plan();
      expect(
        () => p.checkDueAt(3428599),
        throwsA(
          isA<Zip318PlanException>().having(
            (e) => e.refusal,
            'refusal',
            Zip318PlanRefusal.offSchedule,
          ),
        ),
      );
      expect(() => p.checkDueAt(3428600), returnsNormally);
      expect(() => p.checkDueAt(3428700), returnsNormally);
    });

    test('allows one broadcast per application open, and only one', () {
      final session = Zip318BroadcastSession();
      final p = plan();
      expect(session.hasBroadcast, isFalse);
      session.claim(p, chainHeight: 3428700);
      expect(session.hasBroadcast, isTrue);
      expect(
        () => session.claim(p, chainHeight: 3428700),
        throwsA(
          isA<Zip318PlanException>().having(
            (e) => e.refusal,
            'refusal',
            Zip318PlanRefusal.sessionAlreadyUsed,
          ),
        ),
      );
    });

    test('does not spend the session on a transfer that is not due', () {
      final session = Zip318BroadcastSession();
      expect(
        () => session.claim(plan(), chainHeight: 3428599),
        throwsA(isA<Zip318PlanException>()),
      );
      expect(session.hasBroadcast, isFalse);
    });

    test('drains a backlog oldest-first, one at a time', () {
      final schedule = Zip318Schedule(
        transfers: [
          transfer(broadcastHeight: 3428300),
          transfer(broadcastHeight: 3428400),
          transfer(broadcastHeight: 3429000),
        ],
        residualZatoshis: 0,
        parameters: Zip318Parameters.provisional,
      );
      final next = Zip318BroadcastSession.nextDue(schedule, 3428600);
      expect(next?.broadcastHeight, 3428300);
      expect(Zip318BroadcastSession.nextDue(schedule, 3428200), isNull);
    });

    test('refuses to broadcast an expired transfer', () {
      final p = plan();
      expect(
        () => p.checkDueAt(p.expiryHeight),
        throwsA(
          isA<Zip318PlanException>().having(
            (e) => e.refusal,
            'refusal',
            Zip318PlanRefusal.offSchedule,
          ),
        ),
      );
    });
  });
}
