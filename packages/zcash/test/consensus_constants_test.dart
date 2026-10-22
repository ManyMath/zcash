import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

void main() {
  group('ZcashNetworkConstants', () {
    test('parses native mainnet constants JSON', () {
      final constants = ZcashNetworkConstants.fromJson({
        'network': 'mainnet',
        'network_kind': 'mainnet',
        'coin_type': 133,
        'zatoshis_per_zec': 100000000,
        'max_money_zatoshis': 2100000000000000,
        'coinbase_maturity_blocks': 100,
        'address_prefixes': {
          'sapling_payment_address_hrp': 'zs',
          'sapling_extended_spending_key_hrp': 'secret-extended-key-main',
          'sapling_extended_full_viewing_key_hrp': 'zxviews',
          'tex_address_hrp': 'tex',
          'unified_address_hrp': 'u',
          'unified_full_viewing_key_hrp': 'uview',
          'unified_incoming_viewing_key_hrp': 'uivk',
          'sprout_address_b58_prefix': [0x16, 0x9a],
          'transparent_pubkey_address_b58_prefix': [0x1c, 0xb8],
          'transparent_script_address_b58_prefix': [0x1c, 0xbd],
          'transparent_secret_key_b58_prefix': [0x80],
        },
        'activation_heights': [
          {
            'name': 'Sapling',
            'activation_height': 419200,
            'branch_id': '76b809bb',
          },
          {
            'name': 'Nu6.2',
            'activation_height': 3364600,
            'branch_id': '5437f330',
          },
          {
            'name': 'Nu6.3',
            'activation_height': 3428143,
            'branch_id': '37a5165b',
          },
          {
            'name': 'Nu7',
            'activation_height': 3543405,
            'branch_id': '77190ad9',
          },
        ],
      });

      expect(constants.network, ZcashConsensusNetwork.mainnet);
      expect(constants.coinType, 133);
      expect(constants.zatoshisPerZec, 100000000);
      expect(constants.maxMoneyZatoshis, 2100000000000000);
      expect(constants.coinbaseMaturityBlocks, 100);
      expect(constants.addressPrefixes.saplingPaymentAddressHrp, 'zs');
      expect(constants.addressPrefixes.transparentPubkeyAddressB58Prefix, [
        0x1c,
        0xb8,
      ]);
      expect(constants.activationByName('Sapling')?.activationHeight, 419200);
      expect(constants.activationByName('Sapling')?.branchId, '76b809bb');
      expect(constants.activationByName('Nu6.2')?.activationHeight, 3364600);
      expect(constants.activationByName('Nu6.2')?.branchId, '5437f330');
      expect(constants.activationByName('Nu6.3')?.activationHeight, 3428143);
      expect(constants.activationByName('Nu6.3')?.branchId, '37a5165b');
      expect(constants.activationByName('Nu7')?.activationHeight, 3543405);
      expect(constants.activationByName('Nu7')?.branchId, '77190ad9');
    });

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
