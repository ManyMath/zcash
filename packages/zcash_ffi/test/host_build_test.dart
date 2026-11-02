@TestOn('vm')
library;

import 'package:test/test.dart';

import '../hook/host_build.dart';

void main() {
  test('maps every desktop target to its Rust triple', () {
    expect(hostRustTriple('linux', 'x64'), 'x86_64-unknown-linux-gnu');
    expect(hostRustTriple('linux', 'arm64'), 'aarch64-unknown-linux-gnu');
    expect(hostRustTriple('linux', 'riscv64'), 'riscv64gc-unknown-linux-gnu');
    expect(hostRustTriple('macos', 'x64'), 'x86_64-apple-darwin');
    expect(hostRustTriple('macos', 'arm64'), 'aarch64-apple-darwin');
    expect(hostRustTriple('windows', 'x64'), 'x86_64-pc-windows-msvc');
    expect(hostRustTriple('windows', 'arm64'), 'aarch64-pc-windows-msvc');
    expect(() => hostRustTriple('android', 'arm64'), throwsArgumentError);
    expect(() => hostRustTriple('linux', 'ia32'), throwsArgumentError);
  });

  test('looks for a host build under the profile directory', () {
    expect(
      hostLibraryPath(
        targetDir: '/out',
        rustTriple: 'x86_64-unknown-linux-gnu',
        hostTriple: 'x86_64-unknown-linux-gnu',
        libraryFileName: 'libzcash_ffi.so',
        release: true,
      ),
      '/out/release/libzcash_ffi.so',
    );
    expect(
      hostLibraryPath(
        targetDir: '/out',
        rustTriple: 'x86_64-unknown-linux-gnu',
        hostTriple: 'x86_64-unknown-linux-gnu',
        libraryFileName: 'libzcash_ffi.so',
        release: false,
      ),
      '/out/debug/libzcash_ffi.so',
    );
  });

  test('looks for a cross build under the triple directory', () {
    expect(
      hostLibraryPath(
        targetDir: '/out',
        rustTriple: 'x86_64-apple-darwin',
        hostTriple: 'aarch64-apple-darwin',
        libraryFileName: 'libzcash_ffi.dylib',
        release: true,
      ),
      '/out/x86_64-apple-darwin/release/libzcash_ffi.dylib',
    );
  });
}
