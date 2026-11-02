import 'dart:convert';

const nativeResultVersionKey = 'ffi_result_version';
const nativeResultStatusKey = 'status';
const nativeResultErrorStatus = 'error';
const nativeResultOkStatus = 'ok';

Map<String, Object?> parseNativeJsonObject(
  String raw, {
  required String context,
  Iterable<String> redactSensitive = const [],
}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException catch (e) {
    throw StateError('$context returned malformed JSON: ${e.message}');
  }
  if (decoded is! Map) {
    throw StateError('$context returned non-object JSON');
  }
  final json = decoded.cast<String, Object?>();
  throwIfNativeError(json, context: context, redactSensitive: redactSensitive);
  return json;
}

void throwIfNativeError(
  Map<String, Object?> json, {
  required String context,
  Iterable<String> redactSensitive = const [],
}) {
  final error = json['error'];
  final status = json[nativeResultStatusKey];
  if (error == null && status != nativeResultErrorStatus) {
    return;
  }

  final category = json['category'];
  final blockIndex = json['block_index'];
  final height = json['height'];
  final parts = <String>[
    '$context failed',
    if (category is String && category.isNotEmpty) '[$category]',
    if (error != null)
      redactNativeMessage(error.toString(), redactSensitive)
    else
      'native status=error',
    if (blockIndex is num) 'block_index=${blockIndex.toInt()}',
    if (height is num) 'height=${height.toInt()}',
  ];
  throw StateError(parts.join(' '));
}

String requiredNativeString(
  String raw,
  String key, {
  required String context,
  Iterable<String> redactSensitive = const [],
}) => requiredNativeStringFromObject(
  parseNativeJsonObject(
    raw,
    context: context,
    redactSensitive: redactSensitive,
  ),
  key,
  context: context,
);

String requiredNativeStringFromObject(
  Map<String, Object?> json,
  String key, {
  required String context,
}) {
  final value = json[key];
  if (value is String && value.isNotEmpty) {
    return value;
  }
  throw StateError('$context missing non-empty "$key" string');
}

String? optionalNativeStringFromObject(
  Map<String, Object?> json,
  String key, {
  required String context,
}) {
  final value = json[key];
  if (value == null) {
    return null;
  }
  if (value is String && value.isNotEmpty) {
    return value;
  }
  throw StateError('$context has invalid "$key" field');
}

String redactNativeMessage(String message, Iterable<String> sensitiveValues) {
  var redacted = message;
  for (final value in sensitiveValues) {
    if (value.isNotEmpty) {
      redacted = redacted.replaceAll(value, '<redacted>');
    }
  }
  return redacted;
}
