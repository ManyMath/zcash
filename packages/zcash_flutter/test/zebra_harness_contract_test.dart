import 'dart:io';

import 'package:test/test.dart';

import 'integration/harness.dart';

void main() {
  test('staged schedule is immutable and binds Zebra to native NU6.3', () {
    final schedule = ZebraConsensusSchedule.stagedNu63(activationHeight: 130);

    expect(schedule.activationHeight(ZebraUpgrade.nu61), 1);
    expect(schedule.activationHeight(ZebraUpgrade.nu62), 1);
    expect(schedule.activationHeight(ZebraUpgrade.nu63), 130);
    expect(schedule.nativeRegtestNu63ActivationHeight, 130);
    expect(
      () => schedule.activationHeights[ZebraUpgrade.nu63] = 140,
      throwsUnsupportedError,
    );
    expect(schedule.toZebraToml(), contains('"NU6.3" = 130'));
    expect(schedule.toZebraToml(), isNot(contains('NU7 = 130')));
  });

  test('staging at or below genesis is rejected before startup', () {
    expect(
      () => ZebraConsensusSchedule.stagedNu63(activationHeight: 1),
      throwsArgumentError,
    );
  });

  test('reported node heights must match the native-bound schedule', () {
    final schedule = ZebraConsensusSchedule.stagedNu63(activationHeight: 130);
    final reported = {
      for (final entry in schedule.activationHeights.entries)
        entry.key.configName: entry.value,
    };

    expect(
      () => schedule.validateReportedActivationHeights(reported),
      returnsNormally,
    );
    expect(
      () => schedule.validateReportedActivationHeights({
        ...reported,
        'NU6.3': 131,
      }),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          allOf(contains('NU6.3'), contains('130'), contains('131')),
        ),
      ),
    );
    expect(schedule.nativeRegtestNu63ActivationHeight, 130);
  });

  test('unsupported-upgrade failure reports exactly what Zebra supports', () {
    final failure = ZebraStartupException.fromStderr(
      schedule: ZebraConsensusSchedule.stagedNu63(activationHeight: 130),
      stderr: '''
error parsing config: unknown variant `NU6.2`, expected one of `BeforeOverwinter`, `Overwinter`, `Sapling`, `Blossom`, `Heartwood`, `Canopy`, `NU5`, `NU6`, `NU6.1`, `NU7`
''',
    );

    expect(failure.unsupportedUpgrade, 'NU6.2');
    expect(failure.supportedUpgradeNames, containsAll(['NU6.1', 'NU7']));
    expect(failure.supportedUpgradeNames, isNot(contains('NU6.3')));
    expect(failure.toString(), contains('requested upgrade NU6.2'));
    expect(failure.toString(), contains('NU6.3 and NU7 are distinct'));
    expect(failure.toString(), isNot(contains('pre-Ironwood')));
  });

  test('parses the unknown-field wording emitted by Zebra 4.3.1', () {
    final failure = ZebraStartupException.fromStderr(
      schedule: ZebraConsensusSchedule.stagedNu63(activationHeight: 130),
      stderr:
          'Configuration error: unknown field `NU6.3`, expected one of '
          '`BeforeOverwinter`, `Overwinter`, `Sapling`, `Blossom`, '
          '`Heartwood`, `Canopy`, `NU5`, `NU6`, `NU6.1`, `NU7` for key '
          '`network.testnet_parameters.activation_heights`',
    );

    expect(failure.unsupportedUpgrade, 'NU6.3');
    expect(failure.supportedUpgradeNames, contains('NU7'));
    expect(failure.supportedUpgradeNames, isNot(contains('NU6.3')));
    expect(
      failure.supportedUpgradeNames,
      isNot(contains('network.testnet_parameters.activation_heights')),
    );
  });

  test('generic startup failure does not invent upgrade capability claims', () {
    final failure = ZebraStartupException.fromStderr(
      schedule: ZebraConsensusSchedule.standard,
      stderr: 'fatal: address already in use',
    );

    expect(failure.unsupportedUpgrade, isNull);
    expect(failure.supportedUpgradeNames, isEmpty);
    expect(failure.toString(), contains('address already in use'));
    expect(failure.toString(), isNot(contains('NU6.3')));
  });

  test(
    'a process-launch failure removes its partially built runtime',
    () async {
      String? configPath;

      await expectLater(
        ZebraHarness.start(
          zebraBinary: '/fixture/zebrad',
          processStarter: (executable, arguments, environment) async {
            configPath = arguments[arguments.indexOf('--config') + 1];
            expect(await File(configPath!).exists(), isTrue);
            throw StateError('fixture launch failure');
          },
        ),
        throwsStateError,
      );

      expect(configPath, isNotNull);
      expect(await Directory(File(configPath!).parent.path).exists(), isFalse);
    },
  );
}
