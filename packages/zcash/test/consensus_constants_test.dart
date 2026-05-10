import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

void main() {
  group('ZcashNetworkConstants', () {

    test('parses Zebra-style network upgrade JSON', () {
      final upgrade = NetworkUpgrade.fromJson({
        'name': 'Sapling',
        'activationheight': 419200,
        'status': 'active',
      });
      final activation = ZcashConsensusActivation.fromRpcUpgrade(
        '76b809bb',
        upgrade,
      );

      expect(activation.name, 'Sapling');
      expect(activation.activationHeight, 419200);
      expect(activation.branchId, '76b809bb');
      expect(activation.status, 'active');
      expect(activation.toJson()['activation_height'], 419200);
    });

    test('rejects constants without prefix object', () {
      expect(
        () => ZcashNetworkConstants.fromJson({
          'network': 'mainnet',
          'coin_type': 133,
          'zatoshis_per_zec': 100000000,
          'max_money_zatoshis': 2100000000000000,
          'coinbase_maturity_blocks': 100,
          'activation_heights': [],
        }),
        throwsFormatException,
      );
    });
  });
}
