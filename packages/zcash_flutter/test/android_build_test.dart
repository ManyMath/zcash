@TestOn('vm')
library;

import 'package:test/test.dart';

import 'package:zcash_flutter/src/hook/android_build.dart';

void main() {
  test('maps every Android ABI to its Rust triple and NDK wrapper prefix', () {
    expect(androidTarget('arm64'), (
      rustTriple: 'aarch64-linux-android',
      clangPrefix: 'aarch64-linux-android',
    ));
    expect(androidTarget('arm'), (
      rustTriple: 'armv7-linux-androideabi',
      clangPrefix: 'armv7a-linux-androideabi',
    ));
    expect(androidTarget('x64').rustTriple, 'x86_64-linux-android');
    expect(androidTarget('ia32').rustTriple, 'i686-linux-android');
    expect(() => androidTarget('riscv64'), throwsArgumentError);
  });

  test('points cargo at the NDK wrapper for the target and API level', () {
    final env = androidCargoEnvironment(
      toolchainBin: '/ndk/bin',
      rustTriple: 'armv7-linux-androideabi',
      clangPrefix: 'armv7a-linux-androideabi',
      ndkApi: 24,
    );
    expect(
      env['CARGO_TARGET_ARMV7_LINUX_ANDROIDEABI_LINKER'],
      '/ndk/bin/armv7a-linux-androideabi24-clang',
    );
    expect(
      env['CC_armv7_linux_androideabi'],
      '/ndk/bin/armv7a-linux-androideabi24-clang',
    );
    expect(env['AR_armv7_linux_androideabi'], '/ndk/bin/llvm-ar');
    expect(
      env['CARGO_TARGET_ARMV7_LINUX_ANDROIDEABI_RUSTFLAGS'],
      contains('max-page-size=16384'),
    );
  });
}
