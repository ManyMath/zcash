import 'dart:convert';
import 'dart:typed_data';
import 'models/proposal.dart';

class ZcashPaymentTarget {
  final String address;
  final BigInt? amountZatoshis;
  final Uint8List? memo;
  final String? label;
  final String? message;
  final Map<String, String> other;

  ZcashPaymentTarget({
    required this.address,
    this.amountZatoshis,
    this.memo,
    this.label,
    this.message,
    this.other = const <String, String>{},
  });
}

class ZcashPaymentRequest {
  final List<ZcashPaymentTarget> payments;
  ZcashPaymentRequest({required this.payments});
}

ZcashPaymentRequest? parseZcashUri(String uri) {
  final colon = uri.indexOf(':');
  if (colon <= 0 || uri.substring(0, colon).toLowerCase() != 'zcash') {
    return null;
  }

  final remainder = uri.substring(colon + 1);
  if (remainder.contains('#')) return null;
  final question = remainder.indexOf('?');
  final rawPath = question < 0 ? remainder : remainder.substring(0, question);
  final rawQuery = question < 0 ? '' : remainder.substring(question + 1);
  if (rawQuery.contains('?')) return null;
  if (rawPath.isNotEmpty && !_addressSyntax.hasMatch(rawPath)) return null;
  final pathAddr = rawPath.isNotEmpty ? rawPath : null;

  final params = _rawQueryEntries(rawQuery);
  if (params == null) return null;

  final addresses = <int, String>{};
  final amounts = <int, String>{};
  final memos = <int, String>{};
  final labels = <int, String>{};
  final messages = <int, String>{};
  final others = <int, Map<String, String>>{};

  if (pathAddr != null) addresses[0] = pathAddr;

  for (final entry in params) {
    final parameter = _parameterSyntax.firstMatch(entry.name);
    if (parameter == null) return null;
    final name = parameter.group(1)!;
    final indexText = parameter.group(2);
    final index = indexText == null ? 0 : int.parse(indexText);

    switch (name) {
      case 'address':
        if (!entry.hasEquals || !_addressSyntax.hasMatch(entry.value)) {
          return null;
        }
        if (addresses.containsKey(index)) return null;
        addresses[index] = entry.value;
        break;
      case 'amount':
        if (!entry.hasEquals || !_amountSyntax.hasMatch(entry.value)) {
          return null;
        }
        if (amounts.containsKey(index)) return null;
        amounts[index] = entry.value;
        break;
      case 'memo':
        if (!entry.hasEquals || !_base64UrlSyntax.hasMatch(entry.value)) {
          return null;
        }
        if (memos.containsKey(index)) return null;
        memos[index] = entry.value;
        break;
      case 'label':
        if (!entry.hasEquals) return null;
        final value = _decodeQchar(entry.value);
        if (value == null) return null;
        if (labels.containsKey(index)) return null;
        labels[index] = value;
        break;
      case 'message':
        if (!entry.hasEquals) return null;
        final value = _decodeQchar(entry.value);
        if (value == null) return null;
        if (messages.containsKey(index)) return null;
        messages[index] = value;
        break;
      default:
        if (name.startsWith('req-')) return null;
        final value = _decodeQchar(entry.value);
        if (value == null) return null;
        final paymentOthers = others.putIfAbsent(index, () => {});
        if (paymentOthers.containsKey(name)) return null;
        paymentOthers[name] = value;
    }
  }

  final allIndexes = <int>{
    ...addresses.keys,
    ...amounts.keys,
    ...memos.keys,
    ...labels.keys,
    ...messages.keys,
    ...others.keys,
  }.toList()..sort();

  if (allIndexes.isEmpty) return null;

  final payments = <ZcashPaymentTarget>[];
  for (final i in allIndexes) {
    final addr = addresses[i];
    if (addr == null || addr.isEmpty) return null;

    BigInt? amount;
    if (amounts.containsKey(i)) {
      amount = _parseAmountZatoshis(amounts[i]!);
      if (amount == null ||
          amount < BigInt.zero ||
          amount > BigInt.from(maxMoneyZatoshis)) {
        return null;
      }
    }

    Uint8List? memo;
    if (memos.containsKey(i)) {
      try {
        memo = _decodeBase64Url(memos[i]!);
      } catch (_) {
        return null;
      }
      if (memo.length > 512) return null;
    }
    if (memo != null && _isTransparent(addr)) return null;

    payments.add(
      ZcashPaymentTarget(
        address: addr,
        amountZatoshis: amount,
        memo: memo,
        label: labels[i],
        message: messages[i],
        other: others[i] ?? const <String, String>{},
      ),
    );
  }

  return ZcashPaymentRequest(payments: payments);
}

String formatZcashUri(ZcashPaymentRequest request) {
  if (request.payments.isEmpty) {
    throw ArgumentError('payments must not be empty');
  }
  for (final p in request.payments) {
    if (!_addressSyntax.hasMatch(p.address)) {
      throw ArgumentError.value(
        p.address,
        'address',
        'must use ZIP-321 address syntax',
      );
    }
    if (p.amountZatoshis != null && p.amountZatoshis! < BigInt.zero) {
      throw ArgumentError('amountZatoshis must not be negative');
    }
    if (p.amountZatoshis != null &&
        p.amountZatoshis! > BigInt.from(maxMoneyZatoshis)) {
      throw ArgumentError('amountZatoshis exceeds the Zcash money range');
    }
    if (p.memo != null && p.memo!.length > maxMemoLengthBytes) {
      throw ArgumentError('memo exceeds $maxMemoLengthBytes bytes');
    }
    if (p.memo != null && _isTransparent(p.address)) {
      throw ArgumentError(
        'memo is not allowed for transparent address ${p.address}',
      );
    }
  }
  if (request.payments.length > 10000) {
    throw ArgumentError('ZIP-321 supports at most 10000 payment indices');
  }

  if (request.payments.length == 1) {
    final p = request.payments.first;
    final parts = _queryParts(p, suffix: '', includeAddress: false);
    if (parts.isEmpty) return 'zcash:${p.address}';
    return 'zcash:${p.address}?${parts.join('&')}';
  }

  final parts = <String>[];
  for (var i = 0; i < request.payments.length; i++) {
    parts.addAll(
      _queryParts(
        request.payments[i],
        suffix: i == 0 ? '' : '.$i',
        includeAddress: true,
      ),
    );
  }
  return 'zcash:?${parts.join('&')}';
}

List<String> _queryParts(
  ZcashPaymentTarget p, {
  required String suffix,
  required bool includeAddress,
}) {
  final parts = <String>[];

  if (includeAddress) parts.add('address$suffix=${p.address}');
  if (p.amountZatoshis != null) {
    parts.add('amount$suffix=${_formatAmountZec(p.amountZatoshis!)}');
  }
  if (p.memo != null) {
    parts.add('memo$suffix=${_encodeBase64Url(p.memo!)}');
  }
  if (p.label != null) {
    parts.add('label$suffix=${Uri.encodeComponent(p.label!)}');
  }
  if (p.message != null) {
    parts.add('message$suffix=${Uri.encodeComponent(p.message!)}');
  }
  for (final e in p.other.entries) {
    if (!_parameterNameSyntax.hasMatch(e.key) ||
        e.key.startsWith('req-') ||
        const {
          'address',
          'amount',
          'memo',
          'label',
          'message',
        }.contains(e.key)) {
      throw ArgumentError.value(
        e.key,
        'other',
        'must be a non-required, non-reserved ZIP-321 parameter name',
      );
    }
    parts.add('${e.key}$suffix=${Uri.encodeComponent(e.value)}');
  }

  return parts;
}

bool _isTransparent(String address) => zcashAddressIsTransparent(address);

BigInt? _parseAmountZatoshis(String s) {
  if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(s)) return null;
  final parts = s.split('.');
  final intPart = BigInt.parse(parts[0]);
  if (parts.length == 1) return intPart * BigInt.from(100000000);
  final decStr = parts[1];
  if (decStr.length > 8) return null;
  return intPart * BigInt.from(100000000) +
      BigInt.parse(decStr.padRight(8, '0'));
}

String _formatAmountZec(BigInt zatoshis) {
  final intPart = zatoshis ~/ BigInt.from(100000000);
  final decPart = zatoshis % BigInt.from(100000000);
  if (decPart == BigInt.zero) return intPart.toString();
  final trimmed = decPart
      .toString()
      .padLeft(8, '0')
      .replaceFirst(RegExp(r'0+$'), '');
  return '$intPart.$trimmed';
}

Uint8List _decodeBase64Url(String s) {
  if (!_base64UrlSyntax.hasMatch(s)) {
    throw const FormatException('memo is not base64url');
  }
  final rem = s.length % 4;
  if (rem == 1) throw const FormatException('invalid base64url length');
  final padded = rem == 0 ? s : s + '=' * (4 - rem);
  return base64Url.decode(padded);
}

String _encodeBase64Url(Uint8List bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

List<_RawQueryEntry>? _rawQueryEntries(String query) {
  if (query.isEmpty) return const [];
  final entries = <_RawQueryEntry>[];
  for (final component in query.split('&')) {
    if (component.isEmpty) return null;
    final equals = component.indexOf('=');
    entries.add(
      _RawQueryEntry(
        name: equals < 0 ? component : component.substring(0, equals),
        value: equals < 0 ? '' : component.substring(equals + 1),
        hasEquals: equals >= 0,
      ),
    );
  }
  return entries;
}

String? _decodeQchar(String value) {
  if (!_qcharSyntax.hasMatch(value)) return null;
  try {
    return Uri.decodeComponent(value);
  } on FormatException {
    return null;
  }
}

final _addressSyntax = RegExp(r'^[A-Za-z0-9]+$');
final _amountSyntax = RegExp(r'^\d+(?:\.\d{1,8})?$');
final _base64UrlSyntax = RegExp(r'^[A-Za-z0-9_-]*$');
final _parameterNameSyntax = RegExp(r'^[A-Za-z][A-Za-z0-9+-]*$');
final _parameterSyntax = RegExp(
  r'^([A-Za-z][A-Za-z0-9+-]*)(?:\.([1-9][0-9]{0,3}))?$',
);
final _qcharSyntax = RegExp(
  r"^(?:[A-Za-z0-9._~!\$'()*+,;:@-]|%[0-9A-Fa-f]{2})*$",
);

class _RawQueryEntry {
  final String name;
  final String value;
  final bool hasEquals;

  const _RawQueryEntry({
    required this.name,
    required this.value,
    required this.hasEquals,
  });
}
