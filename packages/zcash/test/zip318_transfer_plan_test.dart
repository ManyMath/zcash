import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

ZcashScannedNote orchardNote(int value, {String pool = 'orchard'}) =>
    ZcashScannedNote.fromJson({
      'height': 3428400,
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
  int anchorHeight = 3428496, // a multiple of 144
  int broadcastHeight = 3428600,
}) => Zip318ScheduledTransfer(
  denominationZatoshis: denomination,
  feeZatoshis: fee,
  broadcastHeight: broadcastHeight,
  anchorHeight: anchorHeight,
  expiryHeight: Zip318Schedule.canonicalExpiryHeight(broadcastHeight),
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
      String? orchardAnchor,
      String? ironwoodAnchor,
    }) {
      final t = scheduled ?? transfer();
      return Zip318TransferPlan.forTransfer(
        transfer: t,
        funding:
            funded ??
            Zip318FundingSelection.select(
              transfer: t,
              notes: [orchardNote(funding)],
            ),
        orchardAnchorHex: orchardAnchor ?? 'cd' * 32,
        ironwoodAnchorHex: ironwoodAnchor ?? 'ef' * 32,
        recipientAddress: 'uregtest1self',
      );
    }

    test('takes every canonical field from the schedule', () {
      final p = plan();
      expect(p.targetHeight, 3428600);
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
        () => plan(scheduled: transfer(anchorHeight: 3428497)),
        throwsA(
          isA<Zip318PlanException>().having(
            (e) => e.refusal,
            'refusal',
            Zip318PlanRefusal.anchorOffBoundary,
          ),
        ),
      );
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
