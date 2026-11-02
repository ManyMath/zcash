library;

const _digestPinnedImagePattern =
    r'^[A-Za-z0-9][A-Za-z0-9._:/-]*@sha256:[a-fA-F0-9]{64}$';

bool isDigestPinnedDockerImage(String image) =>
    RegExp(_digestPinnedImagePattern).hasMatch(image);

String requireDigestPinnedDockerImage({
  required String? image,
  required String imageEnvName,
  required String binaryEnvName,
  required String serviceName,
}) {
  final trimmed = image?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    throw StateError(
      '$serviceName live harness requires $binaryEnvName or digest-pinned '
      '$imageEnvName; mutable default Docker images are not allowed',
    );
  }
  if (!isDigestPinnedDockerImage(trimmed)) {
    throw StateError(
      '$serviceName live harness requires digest-pinned $imageEnvName '
      '(example: repository/name@sha256:<64 hex chars>); got '
      '${_describeRejectedImage(trimmed)}',
    );
  }
  return trimmed;
}

String _describeRejectedImage(String image) =>
    '<non-digest image ref: ${image.length} chars>';
