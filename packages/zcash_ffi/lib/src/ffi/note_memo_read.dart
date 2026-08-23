import 'dart:convert';

import 'package:zcash/zcash.dart';

import 'address_utils.dart';
import 'native_result.dart';
import 'zcash_ffi_bindings.dart';

/// [minedHeight] selects ZIP 212 enforcement; supply it for mined txs.
ZcashNoteMemo? readNativeNoteMemo({
  required ZcashNetwork network,
  required String transactionHex,
  required ZcashMemoPool pool,
  required int outputIndex,
  required String ufvk,
  int? minedHeight,
  int? regtestNu63ActivationHeight,
  ZcashFfiBindings? bindings,
}) {
  if (outputIndex < 0) {
    throw ArgumentError.value(
      outputIndex,
      'outputIndex',
      'must be a non-negative index into the pool\'s own bundle',
    );
  }
  final ffi = bindings ?? ZcashFfiBindings.instance;
  final request = jsonEncode({
    'memo_read_version': 1,
    'network': network.ffiLabel,
    'transaction': transactionHex,
    'pool': pool.jsonValue,
    'output_index': outputIndex,
    'ufvk': ufvk,
    'mined_height': ?minedHeight,
    'regtest_nu63_activation_height': ?regtestNu63ActivationHeight,
  });
  final json = parseNativeJsonObject(
    ffi.readNoteMemo(request),
    context: 'read_note_memo',
    redactSensitive: [ufvk],
  );
  return ZcashNoteMemo.fromJson(json);
}
