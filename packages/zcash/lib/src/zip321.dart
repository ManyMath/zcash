import 'dart:convert';
import 'dart:typed_data';

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
  Uri parsed;
  try {
    parsed = Uri.parse(uri);
  } catch (_) {
    return null;
  }

  if (parsed.scheme != 'zcash') return null;

  final pathAddr = parsed.path.isNotEmpty ? parsed.path : null;

  Map<String, String> params;
  try {
    params = parsed.queryParameters;
  } catch (_) {
    return null;
  }

  final addresses = <int, String>{};
  final amounts = <int, String>{};
  final memos = <int, String>{};
  final labels = <int, String>{};
  final messages = <int, String>{};
  final others = <int, Map<String, String>>{};

  if (pathAddr != null) addresses[0] = pathAddr;

  for (final entry in params.entries) {
    String name;
    int index;

    final dot = entry.key.lastIndexOf('.');
    if (dot == -1) {
      name = entry.key;
      index = 0;
    } else {
      final suffix = entry.key.substring(dot + 1);
      final i = int.tryParse(suffix);
      if (i == null || i < 0) return null;
      name = entry.key.substring(0, dot);
      index = i;
    }

    switch (name) {
      case 'address':
        if (addresses.containsKey(index)) return null;
        addresses[index] = entry.value;
        break;
      case 'amount':
        if (amounts.containsKey(index)) return null;
        amounts[index] = entry.value;
        break;
      case 'memo':
        if (memos.containsKey(index)) return null;
        memos[index] = entry.value;
        break;
      case 'label':
        if (labels.containsKey(index)) return null;
        labels[index] = entry.value;
        break;
      case 'message':
        if (messages.containsKey(index)) return null;
        messages[index] = entry.value;
        break;
      default:
        others.putIfAbsent(index, () => {})[name] = entry.value;
    }
  }

  final allIndexes = <int>{
    ...addresses.keys,
    ...amounts.keys,
    ...memos.keys,
    ...labels.keys,
    ...messages.keys,
    ...others.keys,
  }.toList()
    ..sort();

  if (allIndexes.isEmpty) return null;

  final payments = <ZcashPaymentTarget>[];
  for (final i in allIndexes) {
    final addr = addresses[i];
    if (addr == null || addr.isEmpty) return null;

    BigInt? amount;
    if (amounts.containsKey(i)) {
      amount = _parseAmountZatoshis(amounts[i]!);
      if (amount == null || amount < BigInt.zero) return null;
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

    payments.add(ZcashPaymentTarget(
      address: addr,
      amountZatoshis: amount,
      memo: memo,
      label: labels[i],
      message: messages[i],
      other: others[i] ?? const <String, String>{},
    ));
  }

  return ZcashPaymentRequest(payments: payments);
}

String formatZcashUri(ZcashPaymentRequest request) {
  if (request.payments.isEmpty) {
    throw ArgumentError('payments must not be empty');
  }
  for (final p in request.payments) {
    if (p.amountZatoshis != null && p.amountZatoshis! < BigInt.zero) {
      throw ArgumentError('amountZatoshis must not be negative');
    }
    if (p.memo != null && _isTransparent(p.address)) {
      throw ArgumentError(
          'memo is not allowed for transparent address ${p.address}');
    }
  }

  if (request.payments.length == 1) {
    final p = request.payments.first;
    final parts = _queryParts(p, null);
    if (parts.isEmpty) return 'zcash:${p.address}';
    return 'zcash:${p.address}?${parts.join('&')}';
  }

  final parts = <String>[];
  for (var i = 0; i < request.payments.length; i++) {
    parts.addAll(_queryParts(request.payments[i], i));
  }
  return 'zcash:?${parts.join('&')}';
}

List<String> _queryParts(ZcashPaymentTarget p, int? index) {
  final s = index == null ? '' : '.$index';
  final parts = <String>[];

  if (index != null) parts.add('address$s=${Uri.encodeComponent(p.address)}');
  if (p.amountZatoshis != null) {
    parts.add('amount$s=${_formatAmountZec(p.amountZatoshis!)}');
  }
  if (p.memo != null) parts.add('memo$s=${_encodeBase64Url(p.memo!)}');
  if (p.label != null) parts.add('label$s=${Uri.encodeComponent(p.label!)}');
  if (p.message != null) {
    parts.add('message$s=${Uri.encodeComponent(p.message!)}');
  }
  for (final e in p.other.entries) {
    parts.add('${e.key}$s=${Uri.encodeComponent(e.value)}');
  }

  return parts;
}

bool _isTransparent(String address) =>
    address.startsWith('t') || address.startsWith('T');

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
  final trimmed =
      decPart.toString().padLeft(8, '0').replaceFirst(RegExp(r'0+$'), '');
  return '$intPart.$trimmed';
}

Uint8List _decodeBase64Url(String s) {
  final rem = s.length % 4;
  final padded = rem == 0 ? s : s + '=' * (4 - rem);
  return base64Url.decode(padded);
}

String _encodeBase64Url(Uint8List bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');
