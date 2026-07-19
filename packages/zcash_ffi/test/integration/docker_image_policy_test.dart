@TestOn('vm')
library;

import 'package:test/test.dart';

import 'docker_image_policy.dart';

void main() {
  group('Docker image policy', () {
    const digest =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

    test('accepts digest-pinned image references', () {
      final image = requireDigestPinnedDockerImage(
        image: 'electriccoinco/zcashd@sha256:$digest',
        imageEnvName: 'ZCASHD_DOCKER_IMAGE',
        binaryEnvName: 'ZCASHD_BIN',
        serviceName: 'zcashd',
      );

      expect(image, equals('electriccoinco/zcashd@sha256:$digest'));
      expect(isDigestPinnedDockerImage(image), isTrue);
    });

    test('rejects missing Docker image when no binary is configured', () {
      expect(
        () => requireDigestPinnedDockerImage(
          image: null,
          imageEnvName: 'LIGHTWALLETD_DOCKER_IMAGE',
          binaryEnvName: 'LIGHTWALLETD_BIN',
          serviceName: 'lightwalletd',
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('LIGHTWALLETD_BIN'),
              contains('LIGHTWALLETD_DOCKER_IMAGE'),
              contains('digest-pinned'),
              contains('mutable default Docker images are not allowed'),
            ),
          ),
        ),
      );
    });

    test('rejects mutable latest tags', () {
      expect(
        () => requireDigestPinnedDockerImage(
          image: 'zfnd/zebra:latest',
          imageEnvName: 'ZEBRA_DOCKER_IMAGE',
          binaryEnvName: 'ZEBRA_BIN',
          serviceName: 'Zebra',
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('ZEBRA_DOCKER_IMAGE'),
              contains('digest-pinned'),
              contains('<non-digest image ref:'),
              isNot(contains('zfnd/zebra:latest')),
            ),
          ),
        ),
      );
    });

    test('rejects non-digest stable tags', () {
      expect(isDigestPinnedDockerImage('electriccoinco/zcashd:6.2.0'), isFalse);
      expect(
        isDigestPinnedDockerImage('electriccoinco/zcashd@sha256:abc123'),
        isFalse,
      );
    });
  });
}
