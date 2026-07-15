import 'package:zcash/zcash.dart';

import 'native_result.dart';
import 'zcash_ffi_bindings.dart';

ZcashNetworkConstants nativeNetworkConstants({
  required String network,
  ZcashFfiBindings? bindings,
}) {
  final ffi = bindings ?? ZcashFfiBindings.instance;
  final raw = ffi.networkConstantsRaw(network);
  final json = parseNativeJsonObject(
    raw,
    context: 'network_constants/DynamicLibrary',
    redactSensitive: [network],
  );
  return ZcashNetworkConstants.fromJson(json);
}
