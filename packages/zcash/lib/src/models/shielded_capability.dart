enum CapabilityStatus {
  supported,

  gated,

  exposed,

  parsedOnly,

  experimental,

  unsupported,
}

enum ShieldedPool { sapling, orchard, ironwood, transparent, unifiedAddress }

enum CapabilitySurface {
  unifiedAddressReceiver,
  walletSend,
  nativeTransactionBuild,
  compactBlockNoteDiscovery,
  compactBlockActionParsing,
  lightwalletdCompactBlockFields,
  treeState,
  nativeAddressDerivation,

  noteMemoRead,
}

enum NativeCapability {
  unifiedAddressDerivation('unified_address_derivation'),
  transparentAddressDerivation('transparent_address_derivation'),
  saplingScan('sapling_scan'),
  equihashSolver('equihash_solver'),
  orchardReceiverExposure('orchard_receiver_exposure'),
  orchardCompactBlockParsing('orchard_compact_block_parsing'),
  orchardNoteDiscovery('orchard_note_discovery'),
  transparentTransactionBuild('transparent_transaction_build'),
  saplingTransactionBuild('sapling_transaction_build'),

  /// ZIP 258: permanently off after NU6.3; only creates pre-activation
  /// notes for a ZIP 318 migration proof.
  orchardTransactionBuild('orchard_transaction_build'),

  ironwoodNoteDiscovery('ironwood_note_discovery'),

  ironwoodTransactionBuild('ironwood_transaction_build'),
  memoRead('memo_read');

  const NativeCapability(this.jsonKey);

  final String jsonKey;

  static NativeCapability? fromJsonKey(String value) {
    for (final capability in values) {
      if (capability.jsonKey == value) {
        return capability;
      }
    }
    return null;
  }
}

class ShieldedCapability {
  const ShieldedCapability({
    required this.pool,
    required this.surface,
    required this.status,
    required this.proof,
    required this.boundary,
  });

  final ShieldedPool pool;
  final CapabilitySurface surface;
  final CapabilityStatus status;
  final String proof;
  final String boundary;
}

class ShieldedCapabilityMatrix {
  const ShieldedCapabilityMatrix(this.capabilities);

  static const current = ShieldedCapabilityMatrix([
    ShieldedCapability(
      pool: ShieldedPool.sapling,
      surface: CapabilitySurface.noteMemoRead,
      status: CapabilityStatus.supported,
      proof: 'Round-trips a Sapling builder memo under sapling-spend-build.',
      boundary: 'Reads one named output of a caller-supplied transaction.',
    ),
    ShieldedCapability(
      pool: ShieldedPool.orchard,
      surface: CapabilitySurface.noteMemoRead,
      status: CapabilityStatus.supported,
      proof: 'Round-trips an Orchard builder memo under orchard-tx-build.',
      boundary: 'Reading a memo is not Orchard note discovery.',
    ),
    ShieldedCapability(
      pool: ShieldedPool.ironwood,
      surface: CapabilitySurface.noteMemoRead,
      status: CapabilityStatus.supported,
      proof:
          'Round-trips an Ironwood builder memo; an empty memo reads as absent.',
      boundary:
          'Ironwood actions are decrypted under the Ironwood domain only.',
    ),
    ShieldedCapability(
      pool: ShieldedPool.sapling,
      surface: CapabilitySurface.compactBlockNoteDiscovery,
      status: CapabilityStatus.supported,
      proof: 'Rust FFI and Dart scanner tests.',
      boundary: 'Not wallet history or balance reconciliation.',
    ),
    ShieldedCapability(
      pool: ShieldedPool.sapling,
      surface: CapabilitySurface.walletSend,
      status: CapabilityStatus.gated,
      proof: 'Guarded zcashd regtest integration tests.',
      boundary: 'Requires the live gates and a local zcashd.',
    ),
    ShieldedCapability(
      pool: ShieldedPool.sapling,
      surface: CapabilitySurface.nativeTransactionBuild,
      status: CapabilityStatus.unsupported,
      proof: 'Off by default; sapling-spend-build builds Sapling spends.',
      boundary:
          'Proofs are placeholders unless the Sapling MPC parameters are supplied.',
    ),
    ShieldedCapability(
      pool: ShieldedPool.orchard,
      surface: CapabilitySurface.unifiedAddressReceiver,
      status: CapabilityStatus.exposed,
      proof: 'Rust FFI, native-assets and CLI receiver tests.',
      boundary:
          'Receiver presence is not Orchard send, scan or note discovery.',
    ),
    ShieldedCapability(
      pool: ShieldedPool.orchard,
      surface: CapabilitySurface.lightwalletdCompactBlockFields,
      status: CapabilityStatus.parsedOnly,
      proof: 'Generated compact-block models carry Orchard actions.',
      boundary: 'Parsed fields are not decrypted Orchard notes.',
    ),
    ShieldedCapability(
      pool: ShieldedPool.orchard,
      surface: CapabilitySurface.treeState,
      status: CapabilityStatus.parsedOnly,
      proof: 'Tree-state models carry the Orchard tree.',
      boundary: 'Tree-state parsing is not Orchard note discovery.',
    ),
    ShieldedCapability(
      pool: ShieldedPool.orchard,
      surface: CapabilitySurface.compactBlockActionParsing,
      status: CapabilityStatus.parsedOnly,
      proof: 'Scan results report Orchard action counts and tree sizes.',
      boundary: 'Structural counts, not decrypted Orchard notes.',
    ),
    ShieldedCapability(
      pool: ShieldedPool.orchard,
      surface: CapabilitySurface.compactBlockNoteDiscovery,
      status: CapabilityStatus.unsupported,
      proof: 'Off by default; the orchard-note-discovery feature enables it.',
      boundary: 'Orchard discovery needs the experimental native feature.',
    ),
    ShieldedCapability(
      pool: ShieldedPool.orchard,
      surface: CapabilitySurface.nativeTransactionBuild,
      status: CapabilityStatus.unsupported,
      proof:
          'Off by default; orchard-tx-build shields transparent value into Orchard.',
      boundary:
          'Only before NU6.3: ZIP 258 closes the Orchard pool to new value.',
    ),
    ShieldedCapability(
      pool: ShieldedPool.orchard,
      surface: CapabilitySurface.walletSend,
      status: CapabilityStatus.unsupported,
      proof: 'The only Orchard spend built is a ZIP 318 migration to Ironwood.',
      boundary: 'After NU6.3 Orchard value can only migrate out (ZIP 258).',
    ),
    ShieldedCapability(
      pool: ShieldedPool.transparent,
      surface: CapabilitySurface.nativeAddressDerivation,
      status: CapabilityStatus.supported,
      proof: 'Native-assets derivation tests.',
      boundary: 'Transparent derivation is not shielded wallet support.',
    ),
    ShieldedCapability(
      pool: ShieldedPool.transparent,
      surface: CapabilitySurface.walletSend,
      status: CapabilityStatus.unsupported,
      proof:
          'Off by default; transparent-tx-build builds transparent-only transactions.',
      boundary: 'Needs the experimental transparent-tx-build feature.',
    ),
    ShieldedCapability(
      pool: ShieldedPool.unifiedAddress,
      surface: CapabilitySurface.nativeAddressDerivation,
      status: CapabilityStatus.supported,
      proof: 'Rust FFI, native-assets and CLI receiver tests.',
      boundary:
          'Receivers in one Unified Address can differ in support by pool.',
    ),
    ShieldedCapability(
      pool: ShieldedPool.ironwood,
      surface: CapabilitySurface.compactBlockNoteDiscovery,
      status: CapabilityStatus.supported,
      proof: 'Rust discovery tests and the live Ironwood suites.',
      boundary:
          'A pre-NU6.3 lightwalletd serves no Ironwood data; check requireIronwoodParity.',
    ),
    ShieldedCapability(
      pool: ShieldedPool.ironwood,
      surface: CapabilitySurface.nativeTransactionBuild,
      status: CapabilityStatus.supported,
      proof: 'Rust build vectors and live suites whose transactions are mined.',
      boundary:
          'Needs a caller-supplied anchor; rng_seed is refused (rng_seed_not_permitted).',
    ),
    ShieldedCapability(
      pool: ShieldedPool.ironwood,
      surface: CapabilitySurface.walletSend,
      status: CapabilityStatus.supported,
      proof:
          'prepareNativeIronwoodSend and broadcastIronwoodSend, run by the live suite.',
      boundary: 'The caller supplies the anchor and tracks in-flight notes.',
    ),
  ]);

  final List<ShieldedCapability> capabilities;

  CapabilityStatus statusFor(ShieldedPool pool, CapabilitySurface surface) {
    return capabilityFor(pool, surface).status;
  }

  Iterable<ShieldedCapability> capabilitiesForPool(ShieldedPool pool) {
    return capabilities.where((capability) => capability.pool == pool);
  }

  ShieldedCapability capabilityFor(
    ShieldedPool pool,
    CapabilitySurface surface,
  ) {
    return capabilities.firstWhere(
      (capability) => capability.pool == pool && capability.surface == surface,
      orElse: () => ShieldedCapability(
        pool: pool,
        surface: surface,
        status: CapabilityStatus.unsupported,
        proof: 'No proof is registered for this pool and surface.',
        boundary: 'Unsupported until implemented and tested.',
      ),
    );
  }
}

class NativeCapabilitySnapshot {
  const NativeCapabilitySnapshot(this.statuses);

  static const documented = NativeCapabilitySnapshot({
    NativeCapability.unifiedAddressDerivation: CapabilityStatus.supported,
    NativeCapability.transparentAddressDerivation: CapabilityStatus.supported,
    NativeCapability.saplingScan: CapabilityStatus.supported,
    NativeCapability.equihashSolver: CapabilityStatus.supported,
    NativeCapability.orchardReceiverExposure: CapabilityStatus.exposed,
    NativeCapability.orchardCompactBlockParsing: CapabilityStatus.parsedOnly,
    NativeCapability.orchardNoteDiscovery: CapabilityStatus.unsupported,
    NativeCapability.transparentTransactionBuild: CapabilityStatus.unsupported,
    NativeCapability.saplingTransactionBuild: CapabilityStatus.unsupported,
    NativeCapability.orchardTransactionBuild: CapabilityStatus.unsupported,
    NativeCapability.ironwoodNoteDiscovery: CapabilityStatus.supported,
    NativeCapability.ironwoodTransactionBuild: CapabilityStatus.supported,
    NativeCapability.memoRead: CapabilityStatus.supported,
  });

  final Map<NativeCapability, CapabilityStatus> statuses;

  factory NativeCapabilitySnapshot.fromJson(Map<String, Object?> json) {
    final rawCapabilities = json['capabilities'];
    if (rawCapabilities is! Map) {
      throw StateError('native capabilities missing "capabilities" object');
    }
    final statuses = <NativeCapability, CapabilityStatus>{};
    for (final entry in rawCapabilities.entries) {
      final key = entry.key;
      if (key is! String) {
        throw StateError('native capabilities contain a non-string key');
      }
      final capability = NativeCapability.fromJsonKey(key);
      if (capability == null) {
        throw StateError('native capabilities contain unsupported key "$key"');
      }
      final status = _capabilityStatusFromJson(entry.value);
      statuses[capability] = status;
    }
    return NativeCapabilitySnapshot(Map.unmodifiable(statuses));
  }

  CapabilityStatus statusFor(NativeCapability capability) {
    return statuses[capability] ?? CapabilityStatus.unsupported;
  }

  Map<String, Object?> toJson() => {
    'capabilities': {
      for (final entry in statuses.entries) entry.key.jsonKey: entry.value.name,
    },
  };
}

CapabilityStatus _capabilityStatusFromJson(Object? value) {
  if (value is! String || value.isEmpty) {
    throw StateError('native capability status must be a non-empty string');
  }
  for (final status in CapabilityStatus.values) {
    if (status.name == value) {
      return status;
    }
  }
  throw StateError('unsupported native capability status "$value"');
}
