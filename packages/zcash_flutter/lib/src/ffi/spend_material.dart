import 'package:zcash/zcash.dart';

import 'address_utils.dart';
import 'native_result.dart';
import 'zcash_ffi_bindings.dart';

/// Supplies one continuous compact-block range and scans it natively.
///
/// Keeping the source explicit makes the chain reads testable while ensuring
/// the acquisition routine, rather than an application caller, controls the
/// range and all reorg checks.
abstract interface class ZcashSpendMaterialSource {
  String get network;

  Future<ZcashLightwalletdScanSource> fetchRange(int start, int end);

  Future<TreeState> fetchTreeState(int height);

  Future<ZcashScanResult> scan(ScanInputEnvelope input);
}

/// A lightwalletd-backed source whose scan is performed by zcash_ffi.
class NativeLightwalletdSpendMaterialSource
    implements ZcashSpendMaterialSource {
  NativeLightwalletdSpendMaterialSource({
    required this.client,
    required this.ufvk,
    required ZcashNetwork network,
    ZcashFfiBindings? bindings,
  }) : network = network.ffiLabel,
       _bindings = bindings;

  final LightwalletdClient client;
  final String ufvk;

  @override
  final String network;

  final ZcashFfiBindings? _bindings;

  @override
  Future<ZcashLightwalletdScanSource> fetchRange(int start, int end) async =>
      ZcashLightwalletdScanSource(
        await client.getBlockRangeByHeight(start, end).toList(),
      );

  @override
  Future<TreeState> fetchTreeState(int height) async =>
      treeStateFromLightwalletd(await client.getTreeStateAtHeight(height));

  @override
  Future<ZcashScanResult> scan(ScanInputEnvelope input) async {
    final ffi = _bindings ?? ZcashFfiBindings.instance;
    const context = 'scan_compact_blocks/spend_material';
    return ZcashScanResult.fromJson(
      parseNativeJsonObject(
        ffi.scanCompactBlocksRaw(ufvk, network, input.encode()),
        context: context,
        redactSensitive: [ufvk],
      ),
      context: context,
      redactSensitive: [ufvk],
      allowExperimentalOrchardNotes: true,
    );
  }
}

/// Reacquires witnesses and note reconstruction fields for one Ironwood build.
///
/// The wallet remains untouched. The returned material is intentionally not a
/// serializable wallet model and should be discarded after transaction build.
Future<ZcashSpendMaterial> acquireNativeSpendMaterial({
  required ZcashWalletSyncState wallet,
  required ZcashSpendMaterialRequest request,
  required ZcashSpendMaterialSource source,
}) async {
  _requireWalletSelection(wallet, request);

  final start = request.earliestNoteHeight;
  if (start == 0) {
    throw ZcashModelException(
      'a note at height zero has no preceding tree state from which a '
      'continuous witness scan can begin',
    );
  }
  final priorState = await source.fetchTreeState(start - 1);
  final cursor = ZcashLightwalletdSyncCursor.fromTreeState(priorState);
  final served = await source.fetchRange(start, request.anchorHeight);
  final envelope = cursor.scanInputFor(
    served,
    network: source.network,
    includeOrchardWitnesses: true,
    watchedNullifiers: ZcashWatchedNullifiers.forPool(
      request.pool,
      request.noteIdentities.map((identity) => identity.nullifier),
    ),
  );

  final anchorState = await source.fetchTreeState(request.anchorHeight);
  cursor.advance(scanned: served, treeState: anchorState);
  final scanned = await source.scan(envelope);

  _requireExactScannedRange(scanned, request, served);
  await _requireExactIronwoodAnchor(
    source: source,
    scanned: scanned,
    anchorState: anchorState,
  );
  final selected = _requireExactSelectedNotes(scanned, request);
  _requireStillUnspent(scanned, request);

  await _requireUnchangedAnchor(
    source: source,
    request: request,
    served: served,
    anchorState: anchorState,
  );

  final buildScan = ZcashScanResult(
    scannedBlocks: scanned.scannedBlocks,
    discoveredNotes: selected.length,
    totalValue: selected.fold(0, (sum, note) => sum + note.value),
    notes: selected,
    scannedHeightRange: scanned.scannedHeightRange,
    orderedBlocks: scanned.orderedBlocks,
    diagnostics: scanned.diagnostics,
    orchardActions: scanned.orchardActions,
    saplingAnchor: scanned.saplingAnchor,
    orchardAnchor: scanned.orchardAnchor,
    ironwoodAnchor: scanned.ironwoodAnchor,
  );
  return ZcashSpendMaterial.verified(
    accountFingerprint: request.accountFingerprint,
    pool: request.pool,
    anchorHeight: request.anchorHeight,
    anchorBlockHash: served.lastBlockHash!,
    scan: buildScan,
  );
}

Future<void> _requireExactIronwoodAnchor({
  required ZcashSpendMaterialSource source,
  required ZcashScanResult scanned,
  required TreeState anchorState,
}) async {
  final frontier = anchorState.ironwood?.finalState;
  if (frontier == null || frontier.isEmpty) {
    throw ZcashModelException(
      'the requested Ironwood anchor tree has no frontier, so the scan root '
      'cannot be tied to the node tree at that height',
    );
  }
  final boundary = await source.scan(
    ScanInputEnvelope(
      network: source.network,
      includeOrchardWitnesses: true,
      priorIronwoodFrontier: frontier,
      blocks: const [],
    ),
  );
  if (boundary.scannedBlocks != 0 ||
      boundary.ironwoodAnchor == null ||
      boundary.ironwoodAnchor != scanned.ironwoodAnchor) {
    throw ZcashModelException(
      'the continuous scan reported an Ironwood anchor root that is not the '
      'exact root independently derived from the anchor tree state',
    );
  }
}

void _requireWalletSelection(
  ZcashWalletSyncState wallet,
  ZcashSpendMaterialRequest request,
) {
  if (request.accountFingerprint != wallet.accountFingerprint ||
      wallet.ironwood.accountFingerprint != wallet.accountFingerprint) {
    throw ZcashModelException(
      'the spend-material request and Ironwood store must belong to the '
      'wallet account being used for acquisition',
    );
  }
  final storedByKey = {
    for (final note in wallet.ironwood.notes) '${note.tx}:${note.output}': note,
  };
  final spent = {for (final spend in wallet.ironwood.spends) spend.nullifier};
  for (final identity in request.noteIdentities) {
    final stored = storedByKey[identity.key];
    if (stored == null || !identity.matches(stored)) {
      throw ZcashModelException(
        'a requested Ironwood note identity does not exactly match the '
        'durable note held by this wallet',
      );
    }
    if (spent.contains(identity.nullifier)) {
      throw ZcashModelException(
        'a requested Ironwood note is already spent in the durable wallet '
        'state',
      );
    }
  }
}

void _requireExactScannedRange(
  ZcashScanResult scanned,
  ZcashSpendMaterialRequest request,
  ZcashLightwalletdScanSource served,
) {
  final range = scanned.scannedHeightRange;
  if (range == null ||
      range.start != request.earliestNoteHeight ||
      range.end != request.anchorHeight ||
      scanned.scannedBlocks != served.blocks.length ||
      scanned.ironwoodAnchor == null) {
    throw ZcashModelException(
      'native spend-material acquisition must report the exact continuous '
      'range from the earliest selected note through the requested Ironwood '
      'anchor, and the resulting Ironwood root',
    );
  }
}

List<ZcashScannedNote> _requireExactSelectedNotes(
  ZcashScanResult scanned,
  ZcashSpendMaterialRequest request,
) {
  final discoveredByKey = {
    for (final note in scanned.notes) '${note.tx}:${note.output}': note,
  };
  final selected = <ZcashScannedNote>[];
  for (final identity in request.noteIdentities) {
    final note = discoveredByKey[identity.key];
    if (note == null || !identity.matches(note)) {
      throw ZcashModelException(
        'the reacquired Ironwood note identity does not exactly match the '
        'durable note selected by the wallet',
      );
    }
    final status = IronwoodNoteSet.fromScan(
      notes: [note],
    ).tracked.single.status;
    if (status != IronwoodNoteStatus.spendable) {
      throw ZcashModelException(
        'the reacquired Ironwood note is missing its witness or note '
        'reconstruction fields and cannot be passed to a transaction build',
      );
    }
    selected.add(note);
  }
  return List.unmodifiable(selected);
}

void _requireStillUnspent(
  ZcashScanResult scanned,
  ZcashSpendMaterialRequest request,
) {
  final selectedNullifiers = {
    for (final identity in request.noteIdentities) identity.nullifier,
  };
  for (final spend in scanned.spends) {
    if (spend.pool == request.pool &&
        selectedNullifiers.contains(spend.nullifier)) {
      throw ZcashModelException(
        'a selected Ironwood note was spent in the continuous range used to '
        'acquire its witness',
      );
    }
  }
}

Future<void> _requireUnchangedAnchor({
  required ZcashSpendMaterialSource source,
  required ZcashSpendMaterialRequest request,
  required ZcashLightwalletdScanSource served,
  required TreeState anchorState,
}) async {
  final firstHash = served.lastBlockHash;
  final repeated = await source.fetchRange(
    request.anchorHeight,
    request.anchorHeight,
  );
  final repeatedHash = repeated.lastBlockHash;
  if (repeated.blocks.length != 1 ||
      repeated.heights.single != request.anchorHeight ||
      firstHash == null ||
      repeatedHash == null ||
      repeatedHash != firstHash) {
    throw ZcashChainReorgException(
      height: request.anchorHeight,
      expectedPrevHash: firstHash,
      servedPrevHash: repeatedHash ?? '(missing)',
      message:
          'the anchor block changed while spend material was being acquired; '
          'discarding the witness rather than building on a possible reorg',
    );
  }

  final repeatedState = await source.fetchTreeState(request.anchorHeight);
  final firstStateHash = blockHashFromDisplayedHash(anchorState.hash);
  final repeatedStateHash = blockHashFromDisplayedHash(repeatedState.hash);
  if (repeatedState.height != anchorState.height ||
      repeatedStateHash == null ||
      firstStateHash == null ||
      repeatedStateHash != firstStateHash ||
      repeatedState.ironwood?.finalState != anchorState.ironwood?.finalState) {
    throw ZcashChainReorgException(
      height: request.anchorHeight,
      expectedPrevHash: firstStateHash,
      servedPrevHash: repeatedStateHash ?? '(missing)',
      message:
          'the anchor tree state changed while spend material was being '
          'acquired; discarding the witness rather than building on a '
          'possible reorg',
    );
  }
}
