@TestOn('vm')
library;

import 'package:test/test.dart';

import '../hook/ios_build.dart';

void main() {
  test('maps each iOS architecture and SDK to its Rust triple', () {
    expect(iosRustTriple('arm64', simulator: false), 'aarch64-apple-ios');
    expect(iosRustTriple('arm64', simulator: true), 'aarch64-apple-ios-sim');
    expect(iosRustTriple('x64', simulator: true), 'x86_64-apple-ios');
    expect(() => iosRustTriple('x64', simulator: false), throwsArgumentError);
    expect(() => iosRustTriple('arm', simulator: true), throwsArgumentError);
  });

  test('sets the deployment target, an @rpath install name and no strip', () {
    final env = iosCargoEnvironment(
      rustTriple: 'aarch64-apple-ios-sim',
      deploymentTarget: 13,
    );
    expect(env['IPHONEOS_DEPLOYMENT_TARGET'], '13.0');
    expect(
      env['CARGO_TARGET_AARCH64_APPLE_IOS_SIM_RUSTFLAGS'],
      contains('-install_name,@rpath/libzcash_ffi.dylib'),
    );
    expect(env['CARGO_PROFILE_RELEASE_STRIP'], 'none');
  });
}
