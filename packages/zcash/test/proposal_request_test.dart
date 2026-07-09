import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

void main() {
  group('ProposalRecipient', () {
    test('constructs a valid sapling recipient with a memo', () {
      final recipient = ProposalRecipient(
        address: 'zs1validaddress',
        amountZatoshis: 150000,
        memo: Uint8List.fromList([0x01, 0x02, 0x03]),
      );

      expect(recipient.pool, ProposalOutputPool.sapling);
      expect(recipient.amountZatoshis, 150000);
      expect(recipient.memoHex, '010203');
      expect(recipient.isSendSupported, isTrue);
    });

    test('rejects empty address', () {
      expect(
        () => ProposalRecipient(address: '', amountZatoshis: 1),
        throwsA(isA<ZcashModelException>()),
      );
    });

    test('rejects non-positive amount', () {
      expect(
        () => ProposalRecipient(address: 'zs1a', amountZatoshis: 0),
        throwsA(isA<ZcashModelException>()),
      );
      expect(
        () => ProposalRecipient(address: 'zs1a', amountZatoshis: -5),
        throwsA(isA<ZcashModelException>()),
      );
    });

    test('rejects amount above max money', () {
      expect(
        () => ProposalRecipient(
          address: 'zs1a',
          amountZatoshis: maxMoneyZatoshis + 1,
        ),
        throwsA(isA<ZcashModelException>()),
      );
    });

    test('rejects memo longer than 512 bytes', () {
      expect(
        () => ProposalRecipient(
          address: 'zs1a',
          amountZatoshis: 1,
          memo: Uint8List(513),
        ),
        throwsA(isA<ZcashModelException>()),
      );
    });

    test('rejects memo on a transparent recipient', () {
      expect(
        () => ProposalRecipient(
          address: 't1a',
          amountZatoshis: 1,
          pool: ProposalOutputPool.transparent,
          memo: Uint8List.fromList([0x00]),
        ),
        throwsA(isA<ZcashModelException>()),
      );
    });

    test('allows a transparent recipient without a memo', () {
      final recipient = ProposalRecipient(
        address: 't1a',
        amountZatoshis: 1000,
        pool: ProposalOutputPool.transparent,
      );
      expect(recipient.memoHex, isNull);
      expect(recipient.isSendSupported, isTrue);
    });

    test('marks orchard recipients as unsupported for send', () {
      final recipient = ProposalRecipient(
        address: 'u1orchard',
        amountZatoshis: 1000,
        pool: ProposalOutputPool.orchard,
      );
      expect(recipient.isSendSupported, isFalse);
    });

    test('round-trips through JSON', () {
      final recipient = ProposalRecipient(
        address: 'zs1a',
        amountZatoshis: 100000000,
        memo: Uint8List.fromList([0xde, 0xad, 0xbe, 0xef]),
      );
      final parsed = ProposalRecipient.fromJson(recipient.toJson());

      expect(parsed.address, 'zs1a');
      expect(parsed.amountZatoshis, 100000000);
      expect(parsed.pool, ProposalOutputPool.sapling);
      expect(parsed.memoHex, 'deadbeef');
    });

    test('rejects malformed memo hex on parse', () {
      expect(
        () => ProposalRecipient.fromJson({
          'address': 'zs1a',
          'amount': '0.001',
          'memo': 'zz',
        }),
        throwsA(isA<ZcashModelException>()),
      );
    });
  });

  group('ProposalFeeRule', () {
    test('parses and serializes labels', () {
      expect(ProposalFeeRule.fromJson('zip317'), ProposalFeeRule.zip317);
      expect(ProposalFeeRule.fromJson('fixed'), ProposalFeeRule.fixed);
      expect(ProposalFeeRule.zip317.jsonValue, 'zip317');
    });

    test('rejects unknown labels', () {
      expect(
        () => ProposalFeeRule.fromJson('bogus'),
        throwsA(isA<ZcashModelException>()),
      );
    });
  });

  group('ProposalRequest', () {
    ProposalRecipient saplingRecipient() =>
        ProposalRecipient(address: 'zs1a', amountZatoshis: 100000);

    test('constructs with defaults', () {
      final request = ProposalRequest(
        network: ZcashAddressNetwork.mainnet,
        recipients: [saplingRecipient()],
      );

      expect(request.privacyPolicy, PrivacyPolicy.fullPrivacy);
      expect(request.feeRule, ProposalFeeRule.zip317);
      expect(request.minConfirmations, 10);
      expect(request.totalRecipientZatoshis, 100000);
      expect(request.isSendSupported, isTrue);
      expect(request.unsupportedSendPools, isEmpty);
    });

    test('rejects empty recipient list', () {
      expect(
        () => ProposalRequest(
          network: ZcashAddressNetwork.mainnet,
          recipients: const [],
        ),
        throwsA(isA<ZcashModelException>()),
      );
    });

    test('rejects negative minConfirmations', () {
      expect(
        () => ProposalRequest(
          network: ZcashAddressNetwork.mainnet,
          recipients: [saplingRecipient()],
          minConfirmations: -1,
        ),
        throwsA(isA<ZcashModelException>()),
      );
    });

    test('requires a fixed fee for the fixed fee rule', () {
      expect(
        () => ProposalRequest(
          network: ZcashAddressNetwork.mainnet,
          recipients: [saplingRecipient()],
          feeRule: ProposalFeeRule.fixed,
        ),
        throwsA(isA<ZcashModelException>()),
      );
    });

    test('rejects a fixed fee with a non-fixed fee rule', () {
      expect(
        () => ProposalRequest(
          network: ZcashAddressNetwork.mainnet,
          recipients: [saplingRecipient()],
          fixedFeeZatoshis: 1000,
        ),
        throwsA(isA<ZcashModelException>()),
      );
    });

    test('accepts a fixed fee with the fixed fee rule', () {
      final request = ProposalRequest(
        network: ZcashAddressNetwork.mainnet,
        recipients: [saplingRecipient()],
        feeRule: ProposalFeeRule.fixed,
        fixedFeeZatoshis: 10000,
      );
      expect(request.fixedFeeZatoshis, 10000);
      expect(request.toJson()['fixed_fee'], '0.00010000');
    });

    test('reports unsupported orchard send pools', () {
      final request = ProposalRequest(
        network: ZcashAddressNetwork.mainnet,
        recipients: [
          saplingRecipient(),
          ProposalRecipient(
            address: 'u1orchard',
            amountZatoshis: 5000,
            pool: ProposalOutputPool.orchard,
          ),
        ],
      );
      expect(request.isSendSupported, isFalse);
      expect(request.unsupportedSendPools, [ProposalOutputPool.orchard]);
    });

    test('rejects total recipient amount above max money', () {
      expect(
        () => ProposalRequest(
          network: ZcashAddressNetwork.mainnet,
          recipients: [
            ProposalRecipient(
              address: 'zs1a',
              amountZatoshis: maxMoneyZatoshis,
            ),
            ProposalRecipient(address: 'zs1b', amountZatoshis: 1),
          ],
        ),
        throwsA(isA<ZcashModelException>()),
      );
    });

    test('round-trips through JSON', () {
      final request = ProposalRequest(
        network: ZcashAddressNetwork.testnet,
        recipients: [
          ProposalRecipient(
            address: 'zs1a',
            amountZatoshis: 100000,
            memo: Uint8List.fromList([0x01]),
          ),
          ProposalRecipient(
            address: 't1b',
            amountZatoshis: 2000,
            pool: ProposalOutputPool.transparent,
          ),
        ],
        privacyPolicy: PrivacyPolicy.allowRevealedRecipients,
        minConfirmations: 3,
      );

      final json = request.toJson();
      expect(json['proposal_request_version'], ProposalRequest.schemaVersion);
      expect(json['network'], 'testnet');

      final parsed = ProposalRequest.fromJson(json);
      expect(parsed.network, ZcashAddressNetwork.testnet);
      expect(parsed.recipients.length, 2);
      expect(parsed.recipients[0].memoHex, '01');
      expect(parsed.recipients[1].pool, ProposalOutputPool.transparent);
      expect(parsed.privacyPolicy, PrivacyPolicy.allowRevealedRecipients);
      expect(parsed.minConfirmations, 3);
    });

    test('rejects an unsupported schema version on parse', () {
      expect(
        () => ProposalRequest.fromJson({
          'proposal_request_version': 999,
          'network': 'mainnet',
          'recipients': [
            {'address': 'zs1a', 'amount': '0.001'},
          ],
        }),
        throwsA(isA<ZcashModelException>()),
      );
    });

    test('produces a compact JSON string', () {
      final request = ProposalRequest(
        network: ZcashAddressNetwork.mainnet,
        recipients: [saplingRecipient()],
      );
      expect(request.toJsonString(), contains('"proposal_request_version":1'));
    });
  });
}
