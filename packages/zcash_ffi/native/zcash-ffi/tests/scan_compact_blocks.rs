use std::ffi::{CStr, CString};
use std::os::raw::c_char;

use base64::{engine::general_purpose::STANDARD, Engine as _};
use prost::Message;
use serde_json::Value;
use zcash_client_backend::proto::compact_formats::{CompactBlock, CompactOrchardAction};
use zcash_client_backend::scanning::testing::fake_compact_block;
#[cfg(all(
    feature = "ironwood-tx-build",
    any(
        feature = "orchard-note-discovery",
        feature = "ironwood-note-discovery"
    )
))]
use zcash_ffi::zcash_ffi_build_ironwood_transaction;
#[cfg(feature = "sapling-spend-build")]
use zcash_ffi::zcash_ffi_build_sapling_transaction;
use zcash_ffi::{
    zcash_ffi_compact_blocks_from_raw_blocks, zcash_ffi_free_string, zcash_ffi_scan_compact_blocks,
    zcash_ffi_seed_to_sapling_spending_key,
};
use zcash_keys::keys::{UnifiedFullViewingKey, UnifiedSpendingKey};
use zcash_primitives::block::BlockHash;
use zcash_protocol::{
    consensus::{BlockHeight, TestNetwork},
    value::Zatoshis,
};
use zip32::AccountId;

fn cstr(s: &str) -> CString {
    CString::new(s).unwrap()
}

fn take_json(ptr: *mut c_char) -> Value {
    unsafe {
        let s = CStr::from_ptr(ptr).to_str().unwrap().to_owned();
        zcash_ffi_free_string(ptr);
        serde_json::from_str(&s).unwrap()
    }
}

fn scan_json(ufvk: &str, network: &str, payload: &str) -> Value {
    let ufvk = cstr(ufvk);
    let network = cstr(network);
    let payload = cstr(payload);
    let ptr = zcash_ffi_scan_compact_blocks(ufvk.as_ptr(), network.as_ptr(), payload.as_ptr());
    take_json(ptr)
}

fn convert_blocks_json(request: &str) -> Value {
    let request = cstr(request);
    take_json(zcash_ffi_compact_blocks_from_raw_blocks(request.as_ptr()))
}

fn sapling_spending_key_json(seed_hex: &str, network: &str, account: u32) -> Value {
    let seed = cstr(seed_hex);
    let network = cstr(network);
    let ptr = zcash_ffi_seed_to_sapling_spending_key(seed.as_ptr(), network.as_ptr(), account);
    take_json(ptr)
}

const TEST_SEED_HEX: &str = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f\
     202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f";

const TEST_SEED: [u8; 64] = [
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25,
    26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49,
    50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
];

fn test_ufvk() -> UnifiedFullViewingKey {
    ufvk_from_seed(TEST_SEED)
}

fn ufvk_from_seed(seed: [u8; 64]) -> UnifiedFullViewingKey {
    let account = AccountId::try_from(0).unwrap();
    UnifiedSpendingKey::from_seed(&TestNetwork, &seed, account)
        .unwrap()
        .to_unified_full_viewing_key()
}

fn encode_block(block: &CompactBlock) -> String {
    STANDARD.encode(block.encode_to_vec())
}

fn push_orchard_actions(block: &mut CompactBlock, count: u32) {
    let tx = block.vtx.last_mut().expect("block has a transaction");
    for _ in 0..count {
        tx.actions.push(CompactOrchardAction {
            nullifier: vec![0; 32],
            cmx: vec![0; 32],
            ephemeral_key: vec![0; 32],
            ciphertext: vec![0; 52],
        });
    }
    if let Some(meta) = block.chain_metadata.as_mut() {
        meta.orchard_commitment_tree_size += count;
    }
}

#[test]
fn scan_reports_zero_orchard_actions_for_sapling_only_block() {
    let ufvk = test_ufvk();
    let ufvk_str = ufvk.encode(&TestNetwork);
    let sapling_dfvk = ufvk.sapling().expect("test UFVK has Sapling");
    let block = fake_compact_block(
        BlockHeight::from_u32(1),
        BlockHash([0; 32]),
        sapling::Nullifier([7; 32]),
        sapling_dfvk,
        Zatoshis::from_u64(12_345).unwrap(),
        false,
        Some((0, 0)),
    );
    let payload = serde_json::json!({
        "blocks": [{"height": 1, "data": encode_block(&block)}]
    })
    .to_string();

    let out = scan_json(&ufvk_str, "test", &payload);

    assert!(
        out.get("error").is_none(),
        "unexpected scanner error: {out}"
    );
    assert_eq!(out["orchard_actions"], 0);
    assert_eq!(out["diagnostics"][0]["orchard_actions"], 0);
    assert_eq!(out["diagnostics"][0]["orchard_commitment_tree_size"], 0);
}

#[test]
fn scan_reports_parsed_orchard_action_counts_without_discovery() {
    let ufvk = test_ufvk();
    let ufvk_str = ufvk.encode(&TestNetwork);
    let sapling_dfvk = ufvk.sapling().expect("test UFVK has Sapling");
    let mut block = fake_compact_block(
        BlockHeight::from_u32(1),
        BlockHash([0; 32]),
        sapling::Nullifier([7; 32]),
        sapling_dfvk,
        Zatoshis::from_u64(12_345).unwrap(),
        false,
        Some((0, 0)),
    );
    push_orchard_actions(&mut block, 2);
    let payload = serde_json::json!({
        "blocks": [{"height": 1, "data": encode_block(&block)}]
    })
    .to_string();

    let out = scan_json(&ufvk_str, "test", &payload);

    assert!(
        out.get("error").is_none(),
        "unexpected scanner error: {out}"
    );
    assert_eq!(out["discovered_notes"], 1);
    assert_eq!(out["orchard_actions"], 2);
    assert_eq!(out["diagnostics"][0]["orchard_actions"], 2);
    assert_eq!(out["diagnostics"][0]["orchard_commitment_tree_size"], 2);
    for note in out["notes"].as_array().expect("notes array") {
        assert_eq!(note["pool"], "sapling");
    }
}

#[test]
fn scan_aggregates_orchard_actions_across_mixed_blocks() {
    let ufvk = test_ufvk();
    let ufvk_str = ufvk.encode(&TestNetwork);
    let sapling_dfvk = ufvk.sapling().expect("test UFVK has Sapling");

    let block_one = fake_compact_block(
        BlockHeight::from_u32(1),
        BlockHash([1; 32]),
        sapling::Nullifier([1; 32]),
        sapling_dfvk,
        Zatoshis::from_u64(5_000).unwrap(),
        false,
        Some((0, 0)),
    );
    let mut block_two = fake_compact_block(
        BlockHeight::from_u32(2),
        BlockHash([2; 32]),
        sapling::Nullifier([2; 32]),
        sapling_dfvk,
        Zatoshis::from_u64(9_000).unwrap(),
        false,
        Some((2, 0)),
    );
    block_two.prev_hash = block_one.hash.clone();
    push_orchard_actions(&mut block_two, 3);
    let payload = serde_json::json!({
        "blocks": [
            {"height": 1, "data": encode_block(&block_one)},
            {"height": 2, "data": encode_block(&block_two)}
        ]
    })
    .to_string();

    let out = scan_json(&ufvk_str, "test", &payload);

    assert!(
        out.get("error").is_none(),
        "unexpected scanner error: {out}"
    );
    assert_eq!(out["orchard_actions"], 3);
    assert_eq!(out["diagnostics"][0]["orchard_actions"], 0);
    assert_eq!(out["diagnostics"][1]["orchard_actions"], 3);
}

#[test]
fn sapling_spending_key_export_uses_regtest_import_hrp() {
    let out = sapling_spending_key_json(TEST_SEED_HEX, "regtest", 0);

    assert!(out.get("error").is_none(), "unexpected key error: {out}");
    let sk = out["sapling_spending_key"]
        .as_str()
        .expect("sapling_spending_key missing");
    assert!(sk.starts_with("secret-extended-key-regtest"));
    assert!(!out.to_string().contains(TEST_SEED_HEX));
}

#[test]
fn sapling_spending_key_export_rejects_boundary_account() {
    let out = sapling_spending_key_json(TEST_SEED_HEX, "test", 1 << 31);

    assert_eq!(out["error"], "account_index out of range");
    assert!(!out.to_string().contains(TEST_SEED_HEX));
}

/// A real encrypted Orchard note the scanning key can trial-decrypt, from
/// `orchard::note_encryption::testing::fake_compact_action`.
#[cfg(any(
    feature = "orchard-note-discovery",
    all(feature = "ironwood-note-discovery", feature = "ironwood-tx-build")
))]
fn push_discoverable_orchard_action(
    block: &mut CompactBlock,
    ufvk: &UnifiedFullViewingKey,
    value: u64,
) {
    use orchard::keys::Scope;
    use orchard::note::Nullifier;
    use orchard::note_encryption::testing::fake_compact_action;
    use orchard::note_encryption::{NoteEncryptionDomain, OrchardVersion};
    use orchard::value::NoteValue;
    use rand::rngs::OsRng;
    use zcash_note_encryption::{ShieldedOutput, COMPACT_NOTE_SIZE};

    type OrchardCompact =
        dyn ShieldedOutput<NoteEncryptionDomain<OrchardVersion>, COMPACT_NOTE_SIZE>;

    let ofvk = ufvk.orchard().expect("test UFVK has an Orchard component");
    let recipient = ofvk.address_at(0u32, Scope::External);
    let mut rng = OsRng;
    let nf_old = Nullifier::from_bytes(&{
        let mut bytes = [0u8; 32];
        bytes[0] = 1;
        bytes
    })
    .unwrap();
    let (action, _note) = fake_compact_action(
        &mut rng,
        nf_old,
        recipient,
        NoteValue::from_raw(value),
        None,
    );

    let tx = block.vtx.last_mut().expect("block has a transaction");
    tx.actions.push(CompactOrchardAction {
        nullifier: action.nullifier().to_bytes().to_vec(),
        cmx: action.cmx().to_bytes().to_vec(),
        ephemeral_key: <OrchardCompact>::ephemeral_key(&action).0.to_vec(),
        ciphertext: <OrchardCompact>::enc_ciphertext(&action).to_vec(),
    });
    if let Some(meta) = block.chain_metadata.as_mut() {
        meta.orchard_commitment_tree_size += 1;
    }
}

/// ZIP 2005: a `NoteVersion::V3` note under `IronwoodDomain` (plaintext lead byte 0x03).
#[cfg(feature = "ironwood-note-discovery")]
fn push_discoverable_ironwood_action(
    block: &mut CompactBlock,
    ufvk: &UnifiedFullViewingKey,
    value: u64,
) {
    use orchard::keys::Scope;
    use orchard::note::{ExtractedNoteCommitment, Note, NoteVersion, Nullifier, RandomSeed, Rho};
    use orchard::note_encryption::{IronwoodDomain, IronwoodNoteEncryption};
    use orchard::value::NoteValue;
    use rand::rngs::OsRng;
    use rand::RngCore;
    use zcash_note_encryption::Domain;

    let ofvk = ufvk.orchard().expect("test UFVK has an Orchard component");
    let recipient = ofvk.address_at(0u32, Scope::External);
    let mut rng = OsRng;

    let nf_old = Nullifier::from_bytes(&{
        let mut bytes = [0u8; 32];
        bytes[0] = 1;
        bytes
    })
    .unwrap();
    let rho = Rho::from_bytes(&nf_old.to_bytes()).unwrap();
    let rseed = loop {
        let mut bytes = [0u8; 32];
        rng.fill_bytes(&mut bytes);
        if let Some(rseed) = Option::from(RandomSeed::from_bytes(bytes, &rho)) {
            break rseed;
        }
    };
    let note = Note::from_parts(
        recipient,
        NoteValue::from_raw(value),
        rho,
        rseed,
        NoteVersion::V3,
    )
    .unwrap();
    let encryptor = IronwoodNoteEncryption::new(None, note, [0u8; 512]);
    let cmx = ExtractedNoteCommitment::from(note.commitment());
    let ephemeral_key = IronwoodDomain::epk_bytes(encryptor.epk());
    let enc_ciphertext = encryptor.encrypt_note_plaintext();

    let tx = block.vtx.last_mut().expect("block has a transaction");
    tx.ironwood_actions.push(CompactOrchardAction {
        nullifier: nf_old.to_bytes().to_vec(),
        cmx: cmx.to_bytes().to_vec(),
        ephemeral_key: ephemeral_key.0.to_vec(),
        ciphertext: enc_ciphertext[..52].to_vec(),
    });
    if let Some(meta) = block.chain_metadata.as_mut() {
        meta.ironwood_commitment_tree_size += 1;
    }
}

#[cfg(feature = "ironwood-note-discovery")]
#[test]
fn scan_discovers_ironwood_note_with_experimental_feature() {
    let ufvk = test_ufvk();
    let ufvk_str = ufvk.encode(&TestNetwork);
    let sapling_dfvk = ufvk.sapling().expect("test UFVK has Sapling");
    let ironwood_value = 12_345;
    let mut block = fake_compact_block(
        BlockHeight::from_u32(1),
        BlockHash([0; 32]),
        sapling::Nullifier([7; 32]),
        sapling_dfvk,
        Zatoshis::from_u64(7_000).unwrap(),
        false,
        Some((0, 0)),
    );
    push_discoverable_ironwood_action(&mut block, &ufvk, ironwood_value);
    let payload = serde_json::json!({
        "blocks": [{"height": 1, "data": encode_block(&block)}]
    })
    .to_string();
    let out = scan_json(&ufvk_str, "test", &payload);

    assert!(
        out.get("error").is_none(),
        "unexpected scanner error: {out}"
    );

    assert_eq!(out["ironwood_actions"], 1, "{out}");
    assert_eq!(out["orchard_actions"], 0, "{out}");

    let notes = out["notes"].as_array().expect("notes array");
    let ironwood_notes: Vec<&Value> = notes
        .iter()
        .filter(|note| note["pool"] == "ironwood")
        .collect();
    assert_eq!(
        ironwood_notes.len(),
        1,
        "exactly one Ironwood note should be discovered: {out}"
    );
    assert!(
        !notes.iter().any(|note| note["pool"] == "orchard"),
        "an Ironwood note must never be labelled orchard: {out}"
    );
    assert!(notes.iter().any(|note| note["pool"] == "sapling"));

    let note = ironwood_notes[0];
    assert_eq!(note["value"], ironwood_value);
    let nullifier = note["nullifier"]
        .as_str()
        .expect("discovered Ironwood note exposes a nullifier");
    assert_eq!(nullifier.len(), 64, "Ironwood nullifier is 32-byte hex");
    assert!(nullifier.chars().all(|c| c.is_ascii_hexdigit()));
    assert!(
        note["commitment_position"].is_u64(),
        "commitment_position indexes the Ironwood tree"
    );
    assert_eq!(note["is_change"], false);
    assert!(!out.to_string().contains("secret-extended-key"));
}

#[cfg(feature = "orchard-note-discovery")]
#[test]
fn scan_discovers_orchard_note_with_experimental_feature() {
    let ufvk = test_ufvk();
    let ufvk_str = ufvk.encode(&TestNetwork);
    let sapling_dfvk = ufvk.sapling().expect("test UFVK has Sapling");
    let orchard_value = 54_321;
    let mut block = fake_compact_block(
        BlockHeight::from_u32(1),
        BlockHash([0; 32]),
        sapling::Nullifier([7; 32]),
        sapling_dfvk,
        Zatoshis::from_u64(7_000).unwrap(),
        false,
        Some((0, 0)),
    );
    push_discoverable_orchard_action(&mut block, &ufvk, orchard_value);
    let payload = serde_json::json!({
        "blocks": [{"height": 1, "data": encode_block(&block)}]
    })
    .to_string();

    let out = scan_json(&ufvk_str, "test", &payload);

    assert!(
        out.get("error").is_none(),
        "unexpected scanner error: {out}"
    );
    assert_eq!(out["orchard_actions"], 1);
    let notes = out["notes"].as_array().expect("notes array");
    let orchard_notes: Vec<&Value> = notes
        .iter()
        .filter(|note| note["pool"] == "orchard")
        .collect();
    assert_eq!(
        orchard_notes.len(),
        1,
        "exactly one Orchard note should be discovered: {out}"
    );
    assert!(notes.iter().any(|note| note["pool"] == "sapling"));

    let note = orchard_notes[0];
    assert_eq!(note["value"], orchard_value);
    let nullifier = note["nullifier"]
        .as_str()
        .expect("discovered Orchard note exposes a nullifier");
    assert_eq!(nullifier.len(), 64, "Orchard nullifier is 32-byte hex");
    assert!(nullifier.chars().all(|c| c.is_ascii_hexdigit()));
    assert!(
        note["commitment_position"].is_u64(),
        "commitment_position is a tree index"
    );
    assert_eq!(note["is_change"], false);
    assert!(!out.to_string().contains("secret-extended-key"));
    assert!(!out.to_string().contains(TEST_SEED_HEX));
}

#[cfg(feature = "orchard-note-discovery")]
fn expected_orchard_anchor(block: &CompactBlock) -> String {
    use orchard::tree::MerkleHashOrchard;
    use zcash_primitives::merkle_tree::read_commitment_tree;

    const DEPTH: u8 = orchard::NOTE_COMMITMENT_TREE_DEPTH as u8;
    let mut tree =
        read_commitment_tree::<MerkleHashOrchard, _, DEPTH>(&[0u8, 0, 0][..]).expect("empty tree");
    for tx in &block.vtx {
        for action in &tx.actions {
            let mut cmx = [0u8; 32];
            cmx.copy_from_slice(&action.cmx);
            let leaf = Option::<MerkleHashOrchard>::from(MerkleHashOrchard::from_bytes(&cmx))
                .expect("canonical cmx");
            tree.append(leaf).expect("append");
        }
    }
    hex::encode(tree.root().to_bytes())
}

#[test]
#[cfg(feature = "orchard-note-discovery")]
fn scan_exports_orchard_witness_anchor_and_plaintext() {
    use incrementalmerkletree::witness::IncrementalWitness;
    use orchard::tree::MerkleHashOrchard;
    use zcash_primitives::merkle_tree::read_incremental_witness;

    const DEPTH: u8 = orchard::NOTE_COMMITMENT_TREE_DEPTH as u8;

    let ufvk = test_ufvk();
    let ufvk_str = ufvk.encode(&TestNetwork);
    let sapling_dfvk = ufvk.sapling().expect("test UFVK has Sapling");
    let orchard_value = 54_321;
    let mut block = fake_compact_block(
        BlockHeight::from_u32(1),
        BlockHash([0; 32]),
        sapling::Nullifier([7; 32]),
        sapling_dfvk,
        Zatoshis::from_u64(7_000).unwrap(),
        false,
        Some((0, 0)),
    );
    push_discoverable_orchard_action(&mut block, &ufvk, orchard_value);
    let expected_anchor = expected_orchard_anchor(&block);

    let payload = serde_json::json!({
        "include_orchard_witnesses": true,
        "blocks": [{"height": 1, "data": encode_block(&block)}]
    })
    .to_string();

    let out = scan_json(&ufvk_str, "test", &payload);
    assert!(
        out.get("error").is_none(),
        "unexpected scanner error: {out}"
    );

    let anchor = out["orchard_anchor"]
        .as_str()
        .expect("Orchard tip anchor present");
    assert_eq!(anchor, expected_anchor, "anchor matches independent tree");

    let note = out["notes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|n| n["pool"] == "orchard")
        .expect("an Orchard note was discovered");

    let witness_bytes =
        hex::decode(note["witness"].as_str().expect("note carries a witness")).unwrap();
    let witness: IncrementalWitness<MerkleHashOrchard, DEPTH> =
        read_incremental_witness(&witness_bytes[..]).expect("witness deserializes");
    assert_eq!(hex::encode(witness.root().to_bytes()), anchor);
    assert_eq!(
        u64::from(witness.witnessed_position()),
        note["commitment_position"].as_u64().unwrap(),
        "witness position equals the note's reported commitment position"
    );

    let recipient = note["recipient"].as_str().expect("recipient exported");
    assert!(
        recipient.starts_with("utest1"),
        "recipient is a testnet UA: {recipient}"
    );
    assert_eq!(
        note["rseed"].as_str().expect("rseed exported").len(),
        64,
        "rseed is 32-byte hex"
    );

    assert!(out["ironwood_anchor"].is_null(), "{out}");
    assert!(!out.to_string().contains(TEST_SEED_HEX));
}

#[test]
#[cfg(feature = "orchard-note-discovery")]
fn scan_exports_mid_chain_orchard_witness_with_prior_frontier() {
    use incrementalmerkletree::witness::IncrementalWitness;
    use orchard::tree::MerkleHashOrchard;
    use zcash_primitives::merkle_tree::{
        read_commitment_tree, read_incremental_witness, write_commitment_tree,
    };

    const DEPTH: u8 = orchard::NOTE_COMMITMENT_TREE_DEPTH as u8;

    let mut prior =
        read_commitment_tree::<MerkleHashOrchard, _, DEPTH>(&[0u8, 0, 0][..]).expect("empty tree");
    for i in 1u8..=2 {
        let mut repr = [0u8; 32];
        repr[0] = i;
        let leaf = Option::<MerkleHashOrchard>::from(MerkleHashOrchard::from_bytes(&repr))
            .expect("canonical leaf");
        prior.append(leaf).expect("append");
    }
    let mut prior_bytes = Vec::new();
    write_commitment_tree(&prior, &mut prior_bytes).expect("serialize prior tree");

    let ufvk = test_ufvk();
    let ufvk_str = ufvk.encode(&TestNetwork);
    let sapling_dfvk = ufvk.sapling().expect("test UFVK has Sapling");
    let mut block = fake_compact_block(
        BlockHeight::from_u32(1),
        BlockHash([0; 32]),
        sapling::Nullifier([7; 32]),
        sapling_dfvk,
        Zatoshis::from_u64(7_000).unwrap(),
        false,
        Some((0, 0)),
    );
    push_discoverable_orchard_action(&mut block, &ufvk, 54_321);

    let mut expected_tree = prior.clone();
    for tx in &block.vtx {
        for action in &tx.actions {
            let mut cmx = [0u8; 32];
            cmx.copy_from_slice(&action.cmx);
            let leaf = Option::<MerkleHashOrchard>::from(MerkleHashOrchard::from_bytes(&cmx))
                .expect("canonical cmx");
            expected_tree.append(leaf).expect("append");
        }
    }
    let expected_anchor = hex::encode(expected_tree.root().to_bytes());
    let origin_anchor = expected_orchard_anchor(&block);
    assert_ne!(
        expected_anchor, origin_anchor,
        "the prior frontier must actually change the anchor, or this proves nothing"
    );

    let payload = serde_json::json!({
        "include_orchard_witnesses": true,
        "prior_orchard_frontier": hex::encode(&prior_bytes),
        "blocks": [{"height": 1, "data": encode_block(&block)}]
    })
    .to_string();

    let out = scan_json(&ufvk_str, "test", &payload);
    assert!(
        out.get("error").is_none(),
        "unexpected scanner error: {out}"
    );
    assert_eq!(out["orchard_anchor"].as_str().unwrap(), expected_anchor);

    let note = out["notes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|n| n["pool"] == "orchard")
        .expect("an Orchard note was discovered");
    let witness_bytes = hex::decode(note["witness"].as_str().unwrap()).unwrap();
    let witness: IncrementalWitness<MerkleHashOrchard, DEPTH> =
        read_incremental_witness(&witness_bytes[..]).expect("witness deserializes");
    assert_eq!(
        hex::encode(witness.root().to_bytes()),
        expected_anchor,
        "witness roots at the real chain anchor, not an origin-anchored one"
    );
    assert!(
        u64::from(witness.witnessed_position()) >= 2,
        "the witnessed leaf sits after the prior frontier's leaves"
    );
}

#[test]
#[cfg(all(
    feature = "ironwood-note-discovery",
    feature = "orchard-note-discovery"
))]
fn scan_exports_ironwood_witness_against_its_own_tree() {
    use incrementalmerkletree::witness::IncrementalWitness;
    use orchard::tree::MerkleHashOrchard;
    use zcash_primitives::merkle_tree::{read_commitment_tree, read_incremental_witness};

    const DEPTH: u8 = orchard::NOTE_COMMITMENT_TREE_DEPTH as u8;

    let ufvk = test_ufvk();
    let ufvk_str = ufvk.encode(&TestNetwork);
    let sapling_dfvk = ufvk.sapling().expect("test UFVK has Sapling");
    let mut block = fake_compact_block(
        BlockHeight::from_u32(1),
        BlockHash([0; 32]),
        sapling::Nullifier([7; 32]),
        sapling_dfvk,
        Zatoshis::from_u64(7_000).unwrap(),
        false,
        Some((0, 0)),
    );
    push_discoverable_orchard_action(&mut block, &ufvk, 54_321);
    push_discoverable_ironwood_action(&mut block, &ufvk, 12_345);

    let mut expected_ironwood =
        read_commitment_tree::<MerkleHashOrchard, _, DEPTH>(&[0u8, 0, 0][..]).expect("empty tree");
    for tx in &block.vtx {
        for action in &tx.ironwood_actions {
            let mut cmx = [0u8; 32];
            cmx.copy_from_slice(&action.cmx);
            let leaf = Option::<MerkleHashOrchard>::from(MerkleHashOrchard::from_bytes(&cmx))
                .expect("canonical cmx");
            expected_ironwood.append(leaf).expect("append");
        }
    }
    let expected_ironwood_anchor = hex::encode(expected_ironwood.root().to_bytes());
    let expected_orchard_anchor = expected_orchard_anchor(&block);

    let payload = serde_json::json!({
        "include_orchard_witnesses": true,
        "blocks": [{"height": 1, "data": encode_block(&block)}]
    })
    .to_string();

    let out = scan_json(&ufvk_str, "test", &payload);
    assert!(
        out.get("error").is_none(),
        "unexpected scanner error: {out}"
    );

    let orchard_anchor = out["orchard_anchor"].as_str().expect("Orchard anchor");
    let ironwood_anchor = out["ironwood_anchor"].as_str().expect("Ironwood anchor");
    assert_eq!(orchard_anchor, expected_orchard_anchor);
    assert_eq!(ironwood_anchor, expected_ironwood_anchor);
    assert_ne!(
        orchard_anchor, ironwood_anchor,
        "the pools must not share an anchor"
    );

    let note = out["notes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|n| n["pool"] == "ironwood")
        .expect("an Ironwood note was discovered");
    let witness_bytes = hex::decode(note["witness"].as_str().expect("witness")).unwrap();
    let witness: IncrementalWitness<MerkleHashOrchard, DEPTH> =
        read_incremental_witness(&witness_bytes[..]).expect("witness deserializes");
    assert_eq!(
        hex::encode(witness.root().to_bytes()),
        ironwood_anchor,
        "the Ironwood note's witness roots at the IRONWOOD anchor"
    );
    assert_eq!(
        u64::from(witness.witnessed_position()),
        note["commitment_position"].as_u64().unwrap(),
        "positions index the Ironwood tree, not the Orchard one"
    );
    assert!(note["recipient"].as_str().unwrap().starts_with("utest1"));
    assert_eq!(note["rseed"].as_str().unwrap().len(), 64);
}

#[test]
#[cfg(feature = "orchard-note-discovery")]
fn exported_orchard_note_plaintext_rebuilds_the_same_note() {
    use orchard::keys::Scope;
    use orchard::note::{Note, NoteVersion, RandomSeed, Rho};
    use orchard::value::NoteValue;

    let ufvk = test_ufvk();
    let ufvk_str = ufvk.encode(&TestNetwork);
    let sapling_dfvk = ufvk.sapling().expect("test UFVK has Sapling");
    let value = 54_321;
    let mut block = fake_compact_block(
        BlockHeight::from_u32(1),
        BlockHash([0; 32]),
        sapling::Nullifier([7; 32]),
        sapling_dfvk,
        Zatoshis::from_u64(7_000).unwrap(),
        false,
        Some((0, 0)),
    );
    push_discoverable_orchard_action(&mut block, &ufvk, value);

    let payload = serde_json::json!({
        "include_orchard_witnesses": true,
        "blocks": [{"height": 1, "data": encode_block(&block)}]
    })
    .to_string();
    let out = scan_json(&ufvk_str, "test", &payload);
    assert!(
        out.get("error").is_none(),
        "unexpected scanner error: {out}"
    );

    let note_json = out["notes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|n| n["pool"] == "orchard")
        .expect("an Orchard note was discovered");

    let rho_bytes: [u8; 32] = hex::decode(note_json["rho"].as_str().expect("rho exported"))
        .expect("rho is hex")
        .try_into()
        .expect("rho is 32 bytes");
    let rseed_bytes: [u8; 32] = hex::decode(note_json["rseed"].as_str().expect("rseed exported"))
        .expect("rseed is hex")
        .try_into()
        .expect("rseed is 32 bytes");
    let rho = Option::<Rho>::from(Rho::from_bytes(&rho_bytes)).expect("rho is canonical");
    let rseed = Option::<RandomSeed>::from(RandomSeed::from_bytes(rseed_bytes, &rho))
        .expect("rseed belongs to this rho");
    let version = match note_json["note_version"].as_str().expect("note_version") {
        "v2" => NoteVersion::V2,
        "v3" => NoteVersion::V3,
        other => panic!("unexpected note version {other}"),
    };
    assert_eq!(
        version,
        NoteVersion::V2,
        "an Orchard-pool note is ZIP 212 V2"
    );

    let expected_recipient = ufvk
        .orchard()
        .expect("test UFVK has Orchard")
        .address_at(0u32, Scope::External);

    let rebuilt = Option::<Note>::from(Note::from_parts(
        expected_recipient,
        NoteValue::from_raw(note_json["value"].as_u64().expect("value")),
        rho,
        rseed,
        version,
    ))
    .expect("the exported parts must form a valid note");

    let rebuilt_cmx = orchard::note::ExtractedNoteCommitment::from(rebuilt.commitment());
    let mut in_block = false;
    for tx in &block.vtx {
        for action in &tx.actions {
            if action.cmx == rebuilt_cmx.to_bytes().to_vec() {
                in_block = true;
            }
        }
    }
    assert!(
        in_block,
        "the rebuilt note's commitment must be the one the block committed"
    );
    assert_eq!(rebuilt.value().inner(), value);
    assert!(!out.to_string().contains(TEST_SEED_HEX));
}

#[test]
#[cfg(feature = "orchard-note-discovery")]
fn scan_rejects_a_malformed_prior_orchard_frontier() {
    let ufvk = test_ufvk();
    let ufvk_str = ufvk.encode(&TestNetwork);
    let sapling_dfvk = ufvk.sapling().expect("test UFVK has Sapling");
    let block = fake_compact_block(
        BlockHeight::from_u32(1),
        BlockHash([0; 32]),
        sapling::Nullifier([7; 32]),
        sapling_dfvk,
        Zatoshis::from_u64(7_000).unwrap(),
        false,
        Some((0, 0)),
    );
    for frontier in ["not hex", "abcdef"] {
        let payload = serde_json::json!({
            "include_orchard_witnesses": true,
            "prior_orchard_frontier": frontier,
            "blocks": [{"height": 1, "data": encode_block(&block)}]
        })
        .to_string();
        let out = scan_json(&ufvk_str, "test", &payload);
        assert_eq!(out["category"], "invalid_prior_frontier", "{out}");
        assert!(!out.to_string().contains(&ufvk_str));
    }
}

#[test]
#[cfg(not(any(
    feature = "orchard-note-discovery",
    feature = "ironwood-note-discovery"
)))]
fn scan_rejects_orchard_witness_request_without_a_discovery_feature() {
    let ufvk = test_ufvk();
    let ufvk_str = ufvk.encode(&TestNetwork);
    let payload = serde_json::json!({
        "include_orchard_witnesses": true,
        "blocks": []
    })
    .to_string();
    let out = scan_json(&ufvk_str, "test", &payload);
    assert_eq!(out["category"], "witness_export_unavailable", "{out}");
    assert!(!out.to_string().contains(&ufvk_str));
}

#[test]
fn scan_omits_orchard_witness_and_anchors_without_opt_in() {
    let ufvk = test_ufvk();
    let ufvk_str = ufvk.encode(&TestNetwork);
    let sapling_dfvk = ufvk.sapling().expect("test UFVK has Sapling");
    let block = fake_compact_block(
        BlockHeight::from_u32(1),
        BlockHash([0; 32]),
        sapling::Nullifier([7; 32]),
        sapling_dfvk,
        Zatoshis::from_u64(7_000).unwrap(),
        false,
        Some((0, 0)),
    );
    let payload = serde_json::json!({
        "blocks": [{"height": 1, "data": encode_block(&block)}]
    })
    .to_string();
    let out = scan_json(&ufvk_str, "test", &payload);
    assert!(out.get("error").is_none(), "{out}");
    assert!(out["orchard_anchor"].is_null());
    assert!(out["ironwood_anchor"].is_null());
    for note in out["notes"].as_array().unwrap() {
        assert!(note.get("witness").is_none(), "{note}");
    }
}

#[test]
fn scan_discovers_sapling_note_from_compact_block() {
    let ufvk = test_ufvk();
    let ufvk_str = ufvk.encode(&TestNetwork);
    let sapling_dfvk = ufvk.sapling().expect("test UFVK has Sapling");
    let value = 12_345;
    let block = fake_compact_block(
        BlockHeight::from_u32(1),
        BlockHash([0; 32]),
        sapling::Nullifier([7; 32]),
        sapling_dfvk,
        Zatoshis::from_u64(value).unwrap(),
        false,
        Some((0, 0)),
    );
    let payload = serde_json::json!({
        "blocks": [{"height": 1, "data": encode_block(&block)}]
    })
    .to_string();

    let out = scan_json(&ufvk_str, "test", &payload);

    assert!(
        out.get("error").is_none(),
        "unexpected scanner error: {out}"
    );
    assert_eq!(out["scanned_blocks"], 1);
    assert_eq!(out["discovered_notes"], 1);
    assert_eq!(out["total_value"], value);
    assert_eq!(out["notes"][0]["height"], 1);
    assert_eq!(out["notes"][0]["value"], value);
    assert_eq!(out["notes"][0]["pool"], "sapling");
    assert_eq!(out["notes"][0]["output"], 0);
    assert!(out["notes"][0]["tx"].as_str().unwrap().len() >= 32);

    let nullifier = out["notes"][0]["nullifier"]
        .as_str()
        .expect("discovered note exposes a nullifier");
    assert_eq!(nullifier.len(), 64, "nullifier is 32-byte hex");
    assert!(nullifier.chars().all(|c| c.is_ascii_hexdigit()));
    assert!(
        out["notes"][0]["commitment_position"].is_u64(),
        "commitment_position is a tree index"
    );
    assert_eq!(out["notes"][0]["is_change"], false);
    assert!(!out.to_string().contains("secret-extended-key"));

    assert_eq!(out["ordered_blocks"], 1);
    assert_eq!(out["scanned_height_range"]["start"], 1);
    assert_eq!(out["scanned_height_range"]["end"], 1);
    let diagnostics = out["diagnostics"].as_array().expect("diagnostics array");
    assert_eq!(diagnostics.len(), 1);
    assert_eq!(diagnostics[0]["block_index"], 0);
    assert_eq!(diagnostics[0]["height"], 1);
    assert_eq!(diagnostics[0]["category"], "notes_found");
    assert_eq!(diagnostics[0]["notes"], 1);
}

#[test]
fn scan_scans_ordered_range_and_reports_note_in_later_block() {
    let scan_ufvk = test_ufvk();
    let scan_ufvk_str = scan_ufvk.encode(&TestNetwork);
    let sapling_dfvk = scan_ufvk.sapling().expect("test UFVK has Sapling");
    let mut other_seed = TEST_SEED;
    other_seed[0] = 88;
    let other_ufvk = ufvk_from_seed(other_seed);

    let block_one = fake_compact_block(
        BlockHeight::from_u32(1),
        BlockHash([1; 32]),
        sapling::Nullifier([1; 32]),
        other_ufvk.sapling().expect("test UFVK has Sapling"),
        Zatoshis::from_u64(5_000).unwrap(),
        false,
        Some((0, 0)),
    );
    let block_two_value = 98_765;
    let mut block_two = fake_compact_block(
        BlockHeight::from_u32(2),
        BlockHash([2; 32]),
        sapling::Nullifier([2; 32]),
        sapling_dfvk,
        Zatoshis::from_u64(block_two_value).unwrap(),
        false,
        Some((2, 0)),
    );
    block_two.prev_hash = block_one.hash.clone();
    let payload = serde_json::json!({
        "blocks": [
            {"height": 1, "data": encode_block(&block_one)},
            {"height": 2, "data": encode_block(&block_two)}
        ]
    })
    .to_string();

    let out = scan_json(&scan_ufvk_str, "test", &payload);

    assert!(
        out.get("error").is_none(),
        "unexpected scanner error for ordered range: {out}"
    );
    assert_eq!(out["scanned_blocks"], 2);
    assert_eq!(out["discovered_notes"], 1);
    assert_eq!(out["total_value"], block_two_value);
    let note = &out["notes"][0];
    assert_eq!(note["pool"], "sapling");
    assert_eq!(note["height"], 2);
    assert_eq!(note["output"], 0);
    assert_eq!(note["value"], block_two_value);
    assert!(note["tx"].as_str().unwrap().len() >= 32);

    assert_eq!(out["ordered_blocks"], 2);
    assert_eq!(out["scanned_height_range"]["start"], 1);
    assert_eq!(out["scanned_height_range"]["end"], 2);
    let diagnostics = out["diagnostics"].as_array().expect("diagnostics array");
    assert_eq!(diagnostics.len(), 2);
    assert_eq!(diagnostics[0]["height"], 1);
    assert_eq!(diagnostics[0]["category"], "empty");
    assert_eq!(diagnostics[0]["notes"], 0);
    assert_eq!(diagnostics[1]["height"], 2);
    assert_eq!(diagnostics[1]["category"], "notes_found");
    assert_eq!(diagnostics[1]["notes"], 1);
}

#[test]
fn scan_rejects_invalid_json_without_echoing_key() {
    let out = scan_json("uviewtest_secret_key_material", "test", "not json");

    assert_eq!(out["ffi_result_version"], 1);
    assert_eq!(out["status"], "error");
    assert_eq!(out["category"], "invalid_json");
    assert!(out["error"].as_str().unwrap().contains("invalid JSON"));
    assert!(!out.to_string().contains("uviewtest_secret_key_material"));
}

#[test]
fn scan_rejects_malformed_ufvk_without_echoing_key() {
    let out = scan_json("uviewtest_secret_key_material", "test", r#"{"blocks":[]}"#);

    assert_eq!(out["category"], "invalid_ufvk");
    assert!(!out.to_string().contains("uviewtest_secret_key_material"));
}

#[test]
fn scan_rejects_unsupported_network() {
    let ufvk = test_ufvk().encode(&TestNetwork);
    let out = scan_json(&ufvk, "devnet", r#"{"blocks":[]}"#);

    assert_eq!(out["category"], "unsupported_network");
    assert!(!out.to_string().contains(&ufvk));
}

#[test]
fn scan_rejects_invalid_base64_with_block_context() {
    let ufvk = test_ufvk().encode(&TestNetwork);
    let out = scan_json(&ufvk, "test", r#"{"blocks":[{"height":7,"data":"%%"}]}"#);

    assert_eq!(out["category"], "invalid_base64");
    assert_eq!(out["block_index"], 0);
    assert_eq!(out["height"], 7);
    assert!(!out.to_string().contains(&ufvk));
}

#[test]
fn scan_rejects_invalid_protobuf_with_block_context() {
    let ufvk = test_ufvk().encode(&TestNetwork);
    let invalid = STANDARD.encode([0xff, 0xff, 0xff]);
    let payload = serde_json::json!({"blocks":[{"height":8,"data":invalid}]}).to_string();
    let out = scan_json(&ufvk, "test", &payload);

    assert_eq!(out["category"], "invalid_protobuf");
    assert_eq!(out["block_index"], 0);
    assert_eq!(out["height"], 8);
}

#[test]
fn scan_accepts_empty_block_list() {
    let ufvk = test_ufvk().encode(&TestNetwork);
    let out = scan_json(&ufvk, "test", r#"{"blocks":[]}"#);

    assert!(
        out.get("error").is_none(),
        "unexpected scanner error: {out}"
    );
    assert_eq!(out["scanned_blocks"], 0);
    assert_eq!(out["discovered_notes"], 0);
    assert_eq!(out["total_value"], 0);
    assert_eq!(out["notes"].as_array().unwrap().len(), 0);

    assert!(out["scanned_height_range"].is_null());
    assert_eq!(out["ordered_blocks"], 0);
    assert_eq!(out["diagnostics"].as_array().unwrap().len(), 0);
}

#[test]
fn scan_reports_no_matching_notes() {
    let scan_ufvk = test_ufvk().encode(&TestNetwork);
    let mut other_seed = TEST_SEED;
    other_seed[0] = 99;
    let other_ufvk = ufvk_from_seed(other_seed);
    let block = fake_compact_block(
        BlockHeight::from_u32(3),
        BlockHash([0; 32]),
        sapling::Nullifier([9; 32]),
        other_ufvk.sapling().expect("test UFVK has Sapling"),
        Zatoshis::from_u64(7_000).unwrap(),
        false,
        Some((0, 0)),
    );
    let payload = serde_json::json!({
        "blocks": [{"height": 3, "data": encode_block(&block)}]
    })
    .to_string();

    let out = scan_json(&scan_ufvk, "test", &payload);

    assert!(
        out.get("error").is_none(),
        "unexpected scanner error: {out}"
    );
    assert_eq!(out["scanned_blocks"], 1);
    assert_eq!(out["discovered_notes"], 0);
    assert_eq!(out["total_value"], 0);

    assert_eq!(out["scanned_height_range"]["start"], 3);
    assert_eq!(out["scanned_height_range"]["end"], 3);
    assert_eq!(out["diagnostics"][0]["category"], "empty");
    assert_eq!(out["diagnostics"][0]["notes"], 0);
}

#[test]
fn scan_rejects_out_of_order_heights_with_context() {
    let ufvk = test_ufvk();
    let ufvk_str = ufvk.encode(&TestNetwork);
    let sapling_dfvk = ufvk.sapling().expect("test UFVK has Sapling");
    let block_two = fake_compact_block(
        BlockHeight::from_u32(2),
        BlockHash([0; 32]),
        sapling::Nullifier([1; 32]),
        sapling_dfvk,
        Zatoshis::from_u64(1).unwrap(),
        false,
        Some((0, 0)),
    );
    let block_one = fake_compact_block(
        BlockHeight::from_u32(1),
        BlockHash([0; 32]),
        sapling::Nullifier([2; 32]),
        sapling_dfvk,
        Zatoshis::from_u64(1).unwrap(),
        false,
        Some((0, 0)),
    );
    let payload = serde_json::json!({
        "blocks": [
            {"height": 2, "data": encode_block(&block_two)},
            {"height": 1, "data": encode_block(&block_one)}
        ]
    })
    .to_string();

    let out = scan_json(&ufvk_str, "test", &payload);

    assert_eq!(out["category"], "chain_discontinuity");
    assert_eq!(out["block_index"], 1);
    assert_eq!(out["height"], 1);
    assert!(!out.to_string().contains(&ufvk_str));
}

#[test]
fn scan_omits_sapling_witness_without_opt_in() {
    let ufvk = test_ufvk();
    let ufvk_str = ufvk.encode(&TestNetwork);
    let sapling_dfvk = ufvk.sapling().expect("test UFVK has Sapling");
    let block = fake_compact_block(
        BlockHeight::from_u32(1),
        BlockHash([0; 32]),
        sapling::Nullifier([3; 32]),
        sapling_dfvk,
        Zatoshis::from_u64(1_000).unwrap(),
        false,
        Some((0, 0)),
    );
    let payload = serde_json::json!({
        "blocks": [{"height": 1, "data": encode_block(&block)}]
    })
    .to_string();

    let out = scan_json(&ufvk_str, "test", &payload);

    assert!(
        out.get("error").is_none(),
        "unexpected scanner error: {out}"
    );
    assert_eq!(out["discovered_notes"], 1);
    assert!(
        out["sapling_anchor"].is_null(),
        "anchor is null without opt-in: {out}"
    );
    assert!(
        out["notes"][0].get("witness").is_none(),
        "no witness without opt-in: {out}"
    );
}

#[cfg(not(feature = "sapling-spend-build"))]
#[test]
fn scan_rejects_witness_request_without_feature() {
    let ufvk = test_ufvk();
    let ufvk_str = ufvk.encode(&TestNetwork);
    let sapling_dfvk = ufvk.sapling().expect("test UFVK has Sapling");
    let block = fake_compact_block(
        BlockHeight::from_u32(1),
        BlockHash([0; 32]),
        sapling::Nullifier([4; 32]),
        sapling_dfvk,
        Zatoshis::from_u64(1_000).unwrap(),
        false,
        Some((0, 0)),
    );
    let payload = serde_json::json!({
        "include_sapling_witnesses": true,
        "blocks": [{"height": 1, "data": encode_block(&block)}]
    })
    .to_string();

    let out = scan_json(&ufvk_str, "test", &payload);

    assert_eq!(out["category"], "witness_export_unavailable");
    assert!(out.get("error").is_some());
    assert!(!out.to_string().contains(&ufvk_str));
}

#[cfg(feature = "sapling-spend-build")]
#[test]
fn scan_exports_sapling_witness_and_anchor_with_feature() {
    use sapling::{CommitmentTree, Node};
    use zcash_primitives::merkle_tree::read_incremental_witness;

    let ufvk = test_ufvk();
    let ufvk_str = ufvk.encode(&TestNetwork);
    let sapling_dfvk = ufvk.sapling().expect("test UFVK has Sapling");
    let value = 54_321;
    let block = fake_compact_block(
        BlockHeight::from_u32(1),
        BlockHash([0; 32]),
        sapling::Nullifier([9; 32]),
        sapling_dfvk,
        Zatoshis::from_u64(value).unwrap(),
        false,
        Some((0, 0)),
    );

    let mut expected_tree = CommitmentTree::empty();
    for tx in &block.vtx {
        for out in &tx.outputs {
            let mut cmu = [0u8; 32];
            cmu.copy_from_slice(&out.cmu);
            let node = Option::<Node>::from(Node::from_bytes(cmu)).expect("canonical cmu");
            expected_tree.append(node).expect("append");
        }
    }
    let expected_anchor = hex::encode(expected_tree.root().to_bytes());

    let payload = serde_json::json!({
        "include_sapling_witnesses": true,
        "blocks": [{"height": 1, "data": encode_block(&block)}]
    })
    .to_string();

    let out = scan_json(&ufvk_str, "test", &payload);

    assert!(
        out.get("error").is_none(),
        "unexpected scanner error: {out}"
    );
    assert_eq!(out["discovered_notes"], 1);

    let anchor = out["sapling_anchor"].as_str().expect("tip anchor present");
    assert_eq!(anchor.len(), 64, "anchor is 32-byte hex");
    assert_eq!(
        anchor, expected_anchor,
        "tip anchor matches independent tree"
    );

    let note = &out["notes"][0];
    let witness_hex = note["witness"].as_str().expect("note carries a witness");
    let witness_bytes = hex::decode(witness_hex).expect("witness is valid hex");
    let witness: sapling::IncrementalWitness =
        read_incremental_witness(&witness_bytes[..]).expect("witness deserializes");

    assert_eq!(hex::encode(witness.root().to_bytes()), anchor);
    let position = u64::from(witness.witnessed_position());
    assert_eq!(
        position,
        note["commitment_position"].as_u64().unwrap(),
        "witness position equals the note's commitment position"
    );

    assert!(!out.to_string().contains("secret-extended-key"));
    assert!(!out.to_string().contains(TEST_SEED_HEX));
}

#[cfg(feature = "sapling-spend-build")]
#[test]
fn scan_exports_mid_chain_witness_with_prior_frontier() {
    use sapling::{CommitmentTree, Node};
    use zcash_primitives::merkle_tree::{read_incremental_witness, write_commitment_tree};

    fn append_block_outputs(tree: &mut CommitmentTree, block: &CompactBlock) {
        for tx in &block.vtx {
            for out in &tx.outputs {
                let mut cmu = [0u8; 32];
                cmu.copy_from_slice(&out.cmu);
                let node = Option::<Node>::from(Node::from_bytes(cmu)).expect("canonical cmu");
                tree.append(node).expect("append");
            }
        }
    }

    let ufvk = test_ufvk();
    let ufvk_str = ufvk.encode(&TestNetwork);
    let sapling_dfvk = ufvk.sapling().expect("test UFVK has Sapling");

    let prior_block = fake_compact_block(
        BlockHeight::from_u32(1),
        BlockHash([7; 32]),
        sapling::Nullifier([1; 32]),
        sapling_dfvk,
        Zatoshis::from_u64(11_111).unwrap(),
        false,
        Some((0, 0)),
    );
    let mut prior_tree = CommitmentTree::empty();
    append_block_outputs(&mut prior_tree, &prior_block);
    let prior_size = prior_tree.size() as u32;
    assert!(prior_size > 0, "prior frontier must be non-empty");
    let mut frontier_bytes = Vec::new();
    write_commitment_tree(&prior_tree, &mut frontier_bytes).expect("serialize frontier");
    let frontier_hex = hex::encode(&frontier_bytes);

    let value = 54_321;
    let block = fake_compact_block(
        BlockHeight::from_u32(2),
        BlockHash([8; 32]),
        sapling::Nullifier([9; 32]),
        sapling_dfvk,
        Zatoshis::from_u64(value).unwrap(),
        false,
        Some((prior_size, 0)),
    );

    let mut expected_tree = prior_tree.clone();
    append_block_outputs(&mut expected_tree, &block);
    let expected_anchor = hex::encode(expected_tree.root().to_bytes());

    let mut origin_tree = CommitmentTree::empty();
    append_block_outputs(&mut origin_tree, &block);
    let origin_anchor = hex::encode(origin_tree.root().to_bytes());
    assert_ne!(
        expected_anchor, origin_anchor,
        "frontier must change the anchor"
    );

    let payload = serde_json::json!({
        "include_sapling_witnesses": true,
        "prior_sapling_frontier": frontier_hex,
        "blocks": [{"height": 2, "data": encode_block(&block)}]
    })
    .to_string();

    let out = scan_json(&ufvk_str, "test", &payload);

    assert!(
        out.get("error").is_none(),
        "unexpected scanner error: {out}"
    );
    assert_eq!(out["discovered_notes"], 1);

    let anchor = out["sapling_anchor"].as_str().expect("tip anchor present");
    assert_eq!(
        anchor, expected_anchor,
        "exported anchor includes the prior frontier"
    );

    let note = &out["notes"][0];
    let witness_hex = note["witness"].as_str().expect("note carries a witness");
    let witness_bytes = hex::decode(witness_hex).expect("witness is valid hex");
    let witness: sapling::IncrementalWitness =
        read_incremental_witness(&witness_bytes[..]).expect("witness deserializes");

    assert_eq!(hex::encode(witness.root().to_bytes()), anchor);
    let position = u64::from(witness.witnessed_position());
    assert_eq!(
        position,
        note["commitment_position"].as_u64().unwrap(),
        "witness position equals the note's absolute commitment position"
    );
    assert!(
        position >= u64::from(prior_size),
        "the witnessed position is mid-chain, not origin-anchored"
    );

    assert!(!out.to_string().contains(TEST_SEED_HEX));
}

#[cfg(feature = "sapling-spend-build")]
#[test]
fn scan_rejects_malformed_prior_frontier() {
    let ufvk = test_ufvk();
    let ufvk_str = ufvk.encode(&TestNetwork);
    let sapling_dfvk = ufvk.sapling().expect("test UFVK has Sapling");
    let block = fake_compact_block(
        BlockHeight::from_u32(1),
        BlockHash([0; 32]),
        sapling::Nullifier([5; 32]),
        sapling_dfvk,
        Zatoshis::from_u64(1_000).unwrap(),
        false,
        Some((0, 0)),
    );

    let payload = serde_json::json!({
        "include_sapling_witnesses": true,
        "prior_sapling_frontier": "nothex!!",
        "blocks": [{"height": 1, "data": encode_block(&block)}]
    })
    .to_string();
    let out = scan_json(&ufvk_str, "test", &payload);
    assert_eq!(out["category"], "invalid_prior_frontier");
    assert!(out.get("error").is_some());
    assert!(!out.to_string().contains(&ufvk_str));

    let payload = serde_json::json!({
        "include_sapling_witnesses": true,
        "prior_sapling_frontier": "deadbeef",
        "blocks": [{"height": 1, "data": encode_block(&block)}]
    })
    .to_string();
    let out = scan_json(&ufvk_str, "test", &payload);
    assert_eq!(out["category"], "invalid_prior_frontier");
}

#[cfg(feature = "sapling-spend-build")]
fn build_json(request: &str) -> Value {
    let request = cstr(request);
    take_json(zcash_ffi_build_sapling_transaction(request.as_ptr()))
}

#[cfg(feature = "sapling-spend-build")]
#[test]
fn scan_exports_recipient_and_rseed_for_discovered_note() {
    let ufvk = test_ufvk();
    let ufvk_str = ufvk.encode(&TestNetwork);
    let sapling_dfvk = ufvk.sapling().expect("test UFVK has Sapling");
    // Post-Canopy testnet height, so the note is ZIP 212 (AfterZip212).
    let block = fake_compact_block(
        BlockHeight::from_u32(1_500_000),
        BlockHash([0; 32]),
        sapling::Nullifier([2; 32]),
        sapling_dfvk,
        Zatoshis::from_u64(100_000).unwrap(),
        false,
        Some((0, 0)),
    );
    let payload = serde_json::json!({
        "include_sapling_witnesses": true,
        "blocks": [{"height": 1_500_000, "data": encode_block(&block)}]
    })
    .to_string();

    let out = scan_json(&ufvk_str, "test", &payload);
    assert_eq!(out["discovered_notes"], 1);
    let note = &out["notes"][0];
    let recipient = note["recipient"].as_str().expect("recipient exported");
    assert!(
        recipient.starts_with("ztestsapling"),
        "recipient uses the test-network Sapling HRP: {recipient}"
    );
    let rseed = note["rseed"].as_str().expect("rseed exported");
    assert_eq!(rseed.len(), 64, "rseed is 32-byte hex");
    assert!(!out.to_string().contains(TEST_SEED_HEX));
}

#[cfg(feature = "sapling-spend-build")]
#[test]
fn scanned_sapling_note_is_directly_buildable() {
    let value: u64 = 100_000;
    let fee: u64 = 10_000;

    let ufvk = test_ufvk();
    let ufvk_str = ufvk.encode(&TestNetwork);
    let sapling_dfvk = ufvk.sapling().expect("test UFVK has Sapling");
    let block = fake_compact_block(
        BlockHeight::from_u32(1_500_000),
        BlockHash([0; 32]),
        sapling::Nullifier([3; 32]),
        sapling_dfvk,
        Zatoshis::from_u64(value).unwrap(),
        false,
        Some((0, 0)),
    );
    let payload = serde_json::json!({
        "include_sapling_witnesses": true,
        "blocks": [{"height": 1_500_000, "data": encode_block(&block)}]
    })
    .to_string();

    let scanned = scan_json(&ufvk_str, "regtest", &payload);
    assert_eq!(scanned["discovered_notes"], 1, "scan: {scanned}");
    let note = &scanned["notes"][0];
    let recipient = note["recipient"].as_str().expect("recipient").to_owned();
    let rseed = note["rseed"].as_str().expect("rseed").to_owned();
    let witness = note["witness"].as_str().expect("witness").to_owned();
    let anchor = scanned["sapling_anchor"]
        .as_str()
        .expect("anchor")
        .to_owned();
    let note_value = note["value"].as_u64().expect("value");
    assert_eq!(note_value, value);

    let request = serde_json::json!({
        "sapling_build_version": 1,
        "network": "regtest",
        "target_height": 10,
        "fee_zatoshis": fee,
        "seed": TEST_SEED_HEX,
        "account": 0,
        "spend_notes": [{
            "value_zatoshis": note_value,
            "recipient": recipient,
            "rseed": rseed,
            "witness": witness,
            "anchor": anchor,
        }],
        "outputs": [{"address": recipient, "value_zatoshis": value - fee}],
    })
    .to_string();

    let built = build_json(&request);
    assert_eq!(built["status"], "ok", "build should succeed: {built}");
    assert_eq!(built["sapling"]["spends"], 1);
    assert_eq!(built["total_spent_zatoshis"], value);
    assert_eq!(built["fee_zatoshis"], fee);
    assert_eq!(built["proof_validity"], "placeholder");
    assert!(
        !built.to_string().contains(TEST_SEED_HEX),
        "build output must not echo the seed"
    );
}

#[test]
#[cfg(all(feature = "orchard-note-discovery", feature = "ironwood-tx-build"))]
fn scanned_orchard_note_is_directly_migratable_into_ironwood() {
    // ZIP 317 Revision 1: 2 Orchard + 1 Ironwood action = 3 logical actions at 5000 each.
    const CANONICAL_FEE: u64 = 15_000;
    // Canonical ZIP 318 expiry for the first 30-day window (34560 blocks).
    const CANONICAL_EXPIRY: u64 = 2 * 34_560;

    let ufvk = test_ufvk();
    let ufvk_str = ufvk.encode(&TestNetwork);
    let sapling_dfvk = ufvk.sapling().expect("test UFVK has Sapling");
    let value = 1_000_000u64;
    let mut block = fake_compact_block(
        BlockHeight::from_u32(1),
        BlockHash([0; 32]),
        sapling::Nullifier([7; 32]),
        sapling_dfvk,
        Zatoshis::from_u64(7_000).unwrap(),
        false,
        Some((0, 0)),
    );
    push_discoverable_orchard_action(&mut block, &ufvk, value);

    let payload = serde_json::json!({
        "include_orchard_witnesses": true,
        "blocks": [{"height": 1, "data": encode_block(&block)}]
    })
    .to_string();

    let scanned = scan_json(&ufvk_str, "regtest", &payload);
    assert!(scanned.get("error").is_none(), "scan failed: {scanned}");

    let note = scanned["notes"]
        .as_array()
        .expect("notes")
        .iter()
        .find(|n| n["pool"] == "orchard")
        .expect("the Orchard note was discovered");

    let request = serde_json::json!({
        "ironwood_build_version": 1,
        "network": "regtest",
        "target_height": 10,
        "expiry_height": CANONICAL_EXPIRY,
        "ironwood_tree": "",
        "seed": TEST_SEED_HEX,
        "account": 0,
        "orchard_spends": [{
            "value_zatoshis": note["value"],
            "recipient": note["recipient"],
            "rseed": note["rseed"],
            "rho": note["rho"],
            "note_version": note["note_version"],
            "witness": note["witness"],
            "anchor": scanned["orchard_anchor"],
        }],
        "ironwood_output": {"address": note["recipient"]},
    })
    .to_string();

    let built = take_json(zcash_ffi_build_ironwood_transaction(
        cstr(&request).as_ptr(),
    ));
    assert_eq!(built["status"], "ok", "migration should build: {built}");
    assert_eq!(built["version"], "v6");
    assert_eq!(built["proof_validity"], "real");
    assert_eq!(built["zip318_canonical"], true);

    assert_eq!(built["orchard"]["spends"], 1);
    assert_eq!(built["orchard"]["actions"], 2);
    assert_eq!(built["ironwood"]["actions"], 1);
    assert_eq!(built["fee_zatoshis"], CANONICAL_FEE);
    assert_eq!(built["orchard_input_zatoshis"], value);
    assert_eq!(built["ironwood_output_zatoshis"], value - CANONICAL_FEE);
    assert_eq!(built["expiry_height"], CANONICAL_EXPIRY);
    assert_eq!(built["transparent"]["vin"], 0);
    assert_eq!(built["transparent"]["vout"], 0);
    assert_eq!(built["sapling"]["spends"], 0);

    assert!(
        !built.to_string().contains(TEST_SEED_HEX),
        "build output must not echo the seed"
    );

    let with_nullifier_as_rho = request.replace(
        note["rho"].as_str().expect("rho"),
        note["nullifier"].as_str().expect("nullifier"),
    );
    assert_ne!(
        with_nullifier_as_rho, request,
        "the substitution must actually change the request"
    );
    let rejected = take_json(zcash_ffi_build_ironwood_transaction(
        cstr(&with_nullifier_as_rho).as_ptr(),
    ));
    assert_eq!(
        rejected["category"], "witness_anchor_mismatch",
        "rho taken from the nullifier must be caught, not built: {rejected}"
    );
}

#[test]
#[cfg(feature = "orchard-note-discovery")]
fn a_live_staged_chain_block_converts_and_scans() {
    use incrementalmerkletree::frontier::CommitmentTree;
    use orchard::tree::MerkleHashOrchard;
    use zcash_primitives::merkle_tree::read_commitment_tree;

    // Block 102 of a local regtest chain on zebrad 6.2.2 (NU6.3 at 130), carrying a
    // transparent -> Orchard shielding transaction this crate built.
    const FIXTURE: &str = include_str!("fixtures/staged_orchard_block.json");
    let fixture: Value = serde_json::from_str(FIXTURE).unwrap();
    let block_hex = fixture["block_hex"].as_str().unwrap();
    let height = fixture["height"].as_u64().unwrap();
    let value = fixture["orchard_output_zatoshis"].as_u64().unwrap();

    let request = serde_json::json!({
        "compact_block_version": 1,
        "network": "regtest",
        "regtest_nu63_activation_height": 130,
        "prior_orchard_size": 0,
        "blocks": [block_hex],
    })
    .to_string();
    let converted = convert_blocks_json(&request);
    assert_eq!(converted["status"], "ok", "conversion failed: {converted}");
    let blocks = converted["blocks"].as_array().unwrap();
    assert_eq!(blocks.len(), 1);
    assert_eq!(blocks[0]["height"], height);
    assert_eq!(blocks[0]["orchard_actions"], 2);
    assert_eq!(blocks[0]["ironwood_actions"], 0);
    assert_eq!(converted["orchard_commitment_tree_size"], 2);

    let ufvk = test_ufvk();
    let payload = serde_json::json!({
        "include_orchard_witnesses": true,
        "blocks": [{
            "height": height,
            "data": blocks[0]["data"].as_str().unwrap(),
        }],
    })
    .to_string();
    let scanned = scan_json(&ufvk.encode(&TestNetwork), "regtest", &payload);
    assert_eq!(scanned["status"], "ok", "scan failed: {scanned}");

    let notes = scanned["notes"].as_array().unwrap();
    let note = notes
        .iter()
        .find(|n| n["pool"] == "orchard")
        .unwrap_or_else(|| panic!("no Orchard note discovered: {scanned}"));
    assert_eq!(
        note["value"], value,
        "the discovered note must carry the value the builder reported"
    );
    for field in ["recipient", "rseed", "rho", "note_version", "witness"] {
        assert!(
            note[field].is_string(),
            "the converted block must yield {field}: {note}"
        );
    }
    assert_eq!(note["note_version"], "v2");

    let expected_root = {
        let tree_hex = fixture["orchard_tree_after"].as_str().unwrap();
        let tree: CommitmentTree<MerkleHashOrchard, 32> =
            read_commitment_tree(&hex::decode(tree_hex).unwrap()[..]).unwrap();
        hex::encode(orchard::Anchor::from(tree.root()).to_bytes())
    };
    assert_eq!(
        scanned["orchard_anchor"].as_str().unwrap(),
        expected_root,
        "the anchor derived from the converted block must be the root the chain \
         reported at this height"
    );
}

#[test]
fn the_compact_block_adapter_fails_closed_on_a_wrong_activation_height() {
    const FIXTURE: &str = include_str!("fixtures/staged_orchard_block.json");
    let fixture: Value = serde_json::from_str(FIXTURE).unwrap();
    let block_hex = fixture["block_hex"].as_str().unwrap();

    let wrong = serde_json::json!({
        "compact_block_version": 1,
        "network": "regtest",
        "regtest_nu63_activation_height": 2,
        "blocks": [block_hex],
    })
    .to_string();
    let v = convert_blocks_json(&wrong);
    assert_eq!(v["category"], "invalid_block", "{v}");

    let wrong_network = serde_json::json!({
        "compact_block_version": 1,
        "network": "main",
        "blocks": [block_hex],
    })
    .to_string();
    let v = convert_blocks_json(&wrong_network);
    assert_eq!(v["category"], "invalid_block", "{v}");
}

#[test]
fn the_compact_block_adapter_rejects_malformed_requests() {
    for (request, category) in [
        (
            r#"{"compact_block_version":2,"network":"regtest","blocks":[]}"#,
            "unsupported_compact_block_version",
        ),
        (r#"{"network":"simnet","blocks":[]}"#, "unsupported_network"),
        (r#"{"network":"regtest"}"#, "invalid_request"),
        (r#"{"network":"regtest","blocks":["zz"]}"#, "invalid_block"),
        (
            r#"{"network":"main","blocks":[],"regtest_nu63_activation_height":10}"#,
            "unsupported_activation_override",
        ),
        ("[]", "invalid_request"),
    ] {
        let v = convert_blocks_json(request);
        assert_eq!(v["category"], category, "request {request} -> {v}");
    }
}

#[test]
#[cfg(all(feature = "ironwood-note-discovery", feature = "ironwood-tx-build"))]
fn scanned_ironwood_note_is_directly_spendable() {
    let ufvk = test_ufvk();
    let ufvk_str = ufvk.encode(&TestNetwork);
    let sapling_dfvk = ufvk.sapling().expect("test UFVK has Sapling");
    let value = 1_000_000u64;
    let mut block = fake_compact_block(
        BlockHeight::from_u32(1),
        BlockHash([0; 32]),
        sapling::Nullifier([7; 32]),
        sapling_dfvk,
        Zatoshis::from_u64(7_000).unwrap(),
        false,
        Some((0, 0)),
    );
    push_discoverable_orchard_action(&mut block, &ufvk, 500_000);
    push_discoverable_ironwood_action(&mut block, &ufvk, value);

    let payload = serde_json::json!({
        "include_orchard_witnesses": true,
        "blocks": [{"height": 1, "data": encode_block(&block)}]
    })
    .to_string();

    let scanned = scan_json(&ufvk_str, "regtest", &payload);
    assert!(scanned.get("error").is_none(), "scan failed: {scanned}");

    let note = scanned["notes"]
        .as_array()
        .expect("notes")
        .iter()
        .find(|n| n["pool"] == "ironwood")
        .expect("the Ironwood note was discovered");
    assert_eq!(
        note["note_version"], "v3",
        "an Ironwood note carries the ZIP 2005 V3 plaintext"
    );
    let ironwood_anchor = scanned["ironwood_anchor"]
        .as_str()
        .expect("ironwood anchor");
    let orchard_anchor = scanned["orchard_anchor"].as_str().expect("orchard anchor");
    assert_ne!(
        ironwood_anchor, orchard_anchor,
        "two pools, two trees, two anchors"
    );

    let change = 250_000u64;
    let spend_request = |anchor: &str, change: u64| {
        serde_json::json!({
            "ironwood_build_version": 1,
            "network": "regtest",
            "target_height": 10,
            "ironwood_anchor": anchor,
            "seed": TEST_SEED_HEX,
            "account": 0,
            "ironwood_spends": [{
                "value_zatoshis": note["value"],
                "recipient": note["recipient"],
                "rseed": note["rseed"],
                "rho": note["rho"],
                "note_version": note["note_version"],
                "witness": note["witness"],
                "anchor": ironwood_anchor,
            }],
            "ironwood_change_zatoshis": change,
            "ironwood_output": {"address": note["recipient"]},
        })
        .to_string()
    };

    let request = spend_request(ironwood_anchor, change);
    let built = take_json(zcash_ffi_build_ironwood_transaction(
        cstr(&request).as_ptr(),
    ));
    assert_eq!(built["status"], "ok", "the spend should build: {built}");
    assert_eq!(built["version"], "v6");
    assert_eq!(built["consensus_branch_id"], "nu6.3");
    assert_eq!(built["proof_validity"], "real");
    assert_eq!(built["spends_ironwood"], true);
    assert_eq!(
        built["zip318_canonical"], false,
        "spending Ironwood is an ordinary payment, not a ZIP 318 migration"
    );

    assert_eq!(built["ironwood"]["spends"], 1);
    assert_eq!(built["ironwood"]["change_outputs"], 1);
    assert_eq!(built["ironwood_input_zatoshis"], value);
    assert_eq!(built["ironwood_change_zatoshis"], change);
    let fee = built["fee_zatoshis"].as_u64().expect("fee");
    assert_eq!(
        built["ironwood_output_zatoshis"].as_u64().unwrap(),
        value - change - fee
    );
    assert_eq!(built["transparent"]["vin"], 0);
    assert_eq!(built["transparent"]["vout"], 0);
    assert_eq!(built["sapling"]["spends"], 0);
    assert_eq!(built["orchard"]["spends"], 0);

    assert!(
        !built.to_string().contains(TEST_SEED_HEX),
        "build output must not echo the seed"
    );

    let wrong_tree = take_json(zcash_ffi_build_ironwood_transaction(
        cstr(&spend_request(orchard_anchor, change)).as_ptr(),
    ));
    assert_eq!(
        wrong_tree["category"], "ironwood_anchor_mismatch",
        "an Orchard anchor must not root an Ironwood spend: {wrong_tree}"
    );

    let as_v2 = request.replace(r#""note_version":"v3""#, r#""note_version":"v2""#);
    assert_ne!(as_v2, request, "the substitution must change the request");
    let rejected_version = take_json(zcash_ffi_build_ironwood_transaction(cstr(&as_v2).as_ptr()));
    assert_eq!(
        rejected_version["category"], "unsupported_ironwood_note_version",
        "a v2 note must not be spent into the Ironwood bundle: {rejected_version}"
    );

    let with_nullifier_as_rho = request.replace(
        note["rho"].as_str().expect("rho"),
        note["nullifier"].as_str().expect("nullifier"),
    );
    assert_ne!(
        with_nullifier_as_rho, request,
        "the substitution must change the request"
    );
    let rejected_rho = take_json(zcash_ffi_build_ironwood_transaction(
        cstr(&with_nullifier_as_rho).as_ptr(),
    ));
    assert_eq!(
        rejected_rho["category"], "witness_anchor_mismatch",
        "rho taken from the nullifier must be caught, not built: {rejected_rho}"
    );

    let overspent = take_json(zcash_ffi_build_ironwood_transaction(
        cstr(&spend_request(ironwood_anchor, value)).as_ptr(),
    ));
    assert_eq!(
        overspent["category"], "insufficient_funds",
        "change plus fee cannot exceed the note: {overspent}"
    );
}

fn push_action_with_nullifier(block: &mut CompactBlock, pool: &str, nullifier: [u8; 32]) {
    let tx = block.vtx.last_mut().expect("block has a transaction");
    let action = CompactOrchardAction {
        nullifier: nullifier.to_vec(),
        cmx: vec![0; 32],
        ephemeral_key: vec![0; 32],
        ciphertext: vec![0; 52],
    };
    match pool {
        "orchard" => tx.actions.push(action),
        "ironwood" => tx.ironwood_actions.push(action),
        other => panic!("unknown pool {other}"),
    }
    if let Some(meta) = block.chain_metadata.as_mut() {
        match pool {
            "orchard" => meta.orchard_commitment_tree_size += 1,
            "ironwood" => meta.ironwood_commitment_tree_size += 1,
            _ => unreachable!(),
        }
    }
}

fn sapling_block(
    height: u32,
    prev: BlockHash,
    spent_nullifier: [u8; 32],
    value: u64,
    initial_sapling_tree_size: u32,
) -> CompactBlock {
    let ufvk = test_ufvk();
    let sapling_dfvk = ufvk.sapling().expect("test UFVK has Sapling").clone();
    fake_compact_block(
        BlockHeight::from_u32(height),
        prev,
        sapling::Nullifier(spent_nullifier),
        &sapling_dfvk,
        Zatoshis::from_u64(value).unwrap(),
        false,
        Some((initial_sapling_tree_size, 0)),
    )
}

#[test]
fn scan_reports_no_spends_without_watched_nullifiers() {
    let ufvk_str = test_ufvk().encode(&TestNetwork);
    let block = sapling_block(1, BlockHash([0; 32]), [7; 32], 12_345, 0);
    let payload = serde_json::json!({
        "blocks": [{"height": 1, "data": encode_block(&block)}]
    })
    .to_string();

    let out = scan_json(&ufvk_str, "test", &payload);

    assert!(
        out.get("error").is_none(),
        "unexpected scanner error: {out}"
    );
    assert_eq!(out["discovered_notes"], 1);
    assert_eq!(
        out["spends"].as_array().expect("spends array").len(),
        0,
        "a block whose spend was not watched must report nothing: {out}"
    );
}

#[test]
fn scan_reports_a_watched_sapling_nullifier_as_spent() {
    let ufvk_str = test_ufvk().encode(&TestNetwork);
    let block = sapling_block(1, BlockHash([0; 32]), [7; 32], 12_345, 0);
    let spending_tx = hex::encode(&block.vtx[1].txid);
    let payload = serde_json::json!({
        "blocks": [{"height": 1, "data": encode_block(&block)}],
        "watched_nullifiers": {"sapling": [hex::encode([7u8; 32])]},
    })
    .to_string();

    let out = scan_json(&ufvk_str, "test", &payload);

    assert!(
        out.get("error").is_none(),
        "unexpected scanner error: {out}"
    );
    let spends = out["spends"].as_array().expect("spends array");
    assert_eq!(
        spends.len(),
        1,
        "expected exactly one observed spend: {out}"
    );
    assert_eq!(spends[0]["pool"], "sapling");
    assert_eq!(spends[0]["nullifier"], hex::encode([7u8; 32]));
    assert_eq!(spends[0]["height"], 1);
    assert_eq!(spends[0]["tx"], spending_tx);
    assert_eq!(spends[0]["index"], 0);
    assert!(
        spends[0]["note_index"].is_null(),
        "a note this scan never saw cannot be indexed: {out}"
    );
}

#[test]
fn scan_watches_notes_it_discovered_in_the_same_range() {
    let ufvk_str = test_ufvk().encode(&TestNetwork);

    let first = sapling_block(1, BlockHash([0; 32]), [7; 32], 12_345, 0);
    let first_hash = BlockHash(<[u8; 32]>::try_from(first.hash.as_slice()).unwrap());
    let discovered = scan_json(
        &ufvk_str,
        "test",
        &serde_json::json!({"blocks": [{"height": 1, "data": encode_block(&first)}]}).to_string(),
    );
    let nullifier = discovered["notes"][0]["nullifier"]
        .as_str()
        .expect("the scanning key derives the note's nullifier")
        .to_owned();
    let spent = <[u8; 32]>::try_from(hex::decode(&nullifier).unwrap().as_slice()).unwrap();

    let second = sapling_block(
        2,
        first_hash,
        spent,
        6_000,
        first
            .chain_metadata
            .as_ref()
            .expect("block one declares chain metadata")
            .sapling_commitment_tree_size,
    );
    let payload = serde_json::json!({
        "blocks": [
            {"height": 1, "data": encode_block(&first)},
            {"height": 2, "data": encode_block(&second)},
        ]
    })
    .to_string();

    let out = scan_json(&ufvk_str, "test", &payload);

    assert!(
        out.get("error").is_none(),
        "unexpected scanner error: {out}"
    );
    let spends = out["spends"].as_array().expect("spends array");
    assert_eq!(
        spends.len(),
        1,
        "the note discovered in block one is spent in block two: {out}"
    );
    assert_eq!(spends[0]["nullifier"], nullifier);
    assert_eq!(spends[0]["height"], 2);
    assert_eq!(
        spends[0]["note_index"], 0,
        "the spend must point at the note it spent: {out}"
    );
    assert_eq!(out["notes"][0]["nullifier"], nullifier);
}

#[test]
fn a_watched_nullifier_matches_only_its_own_pools_actions() {
    let ufvk_str = test_ufvk().encode(&TestNetwork);
    let shared = [0x2au8; 32];

    let mut block = sapling_block(1, BlockHash([0; 32]), [7; 32], 12_345, 0);
    push_action_with_nullifier(&mut block, "orchard", shared);
    push_action_with_nullifier(&mut block, "ironwood", [0x11u8; 32]);
    push_action_with_nullifier(&mut block, "ironwood", shared);
    let data = encode_block(&block);

    for (pool, expected_index) in [("orchard", 0), ("ironwood", 1)] {
        let payload = serde_json::json!({
            "blocks": [{"height": 1, "data": data}],
            "watched_nullifiers": {pool: [hex::encode(shared)]},
        })
        .to_string();

        let out = scan_json(&ufvk_str, "test", &payload);

        assert!(
            out.get("error").is_none(),
            "unexpected scanner error: {out}"
        );
        let spends = out["spends"].as_array().expect("spends array");
        assert_eq!(
            spends.len(),
            1,
            "watching {pool} must match {pool} actions only: {out}"
        );
        assert_eq!(spends[0]["pool"], pool);
        assert_eq!(
            spends[0]["index"], expected_index,
            "the index is the position within that pool's own actions: {out}"
        );
    }

    let payload = serde_json::json!({
        "blocks": [{"height": 1, "data": data}],
        "watched_nullifiers": {"sapling": [hex::encode(shared)]},
    })
    .to_string();
    let out = scan_json(&ufvk_str, "test", &payload);
    assert_eq!(
        out["spends"].as_array().expect("spends array").len(),
        0,
        "an Orchard-family nullifier is not a Sapling nullifier: {out}"
    );
}

#[test]
fn scan_rejects_malformed_watched_nullifiers() {
    let ufvk_str = test_ufvk().encode(&TestNetwork);

    let cases = [
        r#""orchard""#,
        r#"{"orchid": ["00"]}"#,
        r#"{"orchard": "not-an-array"}"#,
        r#"{"orchard": [7]}"#,
        r#"{"orchard": ["zz"]}"#,
        r#"{"orchard": ["0011"]}"#,
    ];
    for case in cases {
        let payload = format!(r#"{{"blocks":[],"watched_nullifiers":{case}}}"#);
        let out = scan_json(&ufvk_str, "test", &payload);
        assert_eq!(
            out["category"], "invalid_watched_nullifiers",
            "malformed watch list must be refused: {case} -> {out}"
        );
        assert!(
            !out.to_string().contains("orchid") && !out.to_string().contains("zz"),
            "the error must not echo caller input: {out}"
        );
    }
}

/// Built by hand because `fake_compact_block` derives note randomness from `TestNetwork`'s
/// upgrade schedule, which hides regtest-parameter defects.
fn regtest_style_sapling_block(
    height: u32,
    dfvk: &sapling::zip32::DiversifiableFullViewingKey,
    value: u64,
) -> CompactBlock {
    use rand::rngs::OsRng;
    use sapling::note_encryption::{sapling_note_encryption, SaplingDomain};
    use sapling::value::NoteValue;
    use sapling::Rseed;
    use zcash_client_backend::proto::compact_formats::{
        ChainMetadata, CompactSaplingOutput, CompactTx,
    };
    use zcash_note_encryption::Domain;
    use zcash_protocol::memo::MemoBytes;

    let to = dfvk.default_address().1;
    let note = sapling::Note::from_parts(
        to,
        NoteValue::from_raw(value),
        Rseed::AfterZip212([9u8; 32]),
    );
    let mut rng = OsRng;
    let encryptor = sapling_note_encryption(
        Some(dfvk.fvk().ovk),
        note.clone(),
        MemoBytes::empty().into_bytes(),
        &mut rng,
    );
    let enc_ciphertext = encryptor.encrypt_note_plaintext();
    let output = CompactSaplingOutput {
        cmu: note.cmu().to_bytes().to_vec(),
        ephemeral_key: SaplingDomain::epk_bytes(encryptor.epk()).0.to_vec(),
        ciphertext: enc_ciphertext[..52].to_vec(),
    };
    let tx = CompactTx {
        index: 0,
        txid: vec![0u8; 32],
        fee: 0,
        spends: vec![],
        outputs: vec![output],
        actions: vec![],
        ironwood_actions: vec![],
        vin: vec![],
        vout: vec![],
    };
    CompactBlock {
        height: u64::from(height),
        hash: vec![height as u8; 32],
        prev_hash: vec![(height - 1) as u8; 32],
        time: 0,
        header: vec![],
        vtx: vec![tx],
        chain_metadata: Some(ChainMetadata {
            sapling_commitment_tree_size: 1,
            orchard_commitment_tree_size: 0,
            ironwood_commitment_tree_size: 0,
        }),
    }
}

#[test]
fn scan_reads_a_regtest_chain_under_regtest_parameters() {
    let ufvk = test_ufvk();
    let ufvk_str = ufvk.encode(&TestNetwork);
    let dfvk = ufvk.sapling().expect("test UFVK has Sapling");
    let value = 42_000u64;
    let block = regtest_style_sapling_block(133, dfvk, value);
    let payload = serde_json::json!({
        "blocks": [{"height": 133, "data": encode_block(&block)}]
    })
    .to_string();

    let regtest = scan_json(&ufvk_str, "regtest", &payload);
    assert!(regtest.get("error").is_none(), "scanner error: {regtest}");
    assert_eq!(
        regtest["discovered_notes"], 1,
        "a regtest chain's own note must be discoverable: {regtest}"
    );
    assert_eq!(regtest["notes"][0]["value"], value);
    assert_eq!(regtest["notes"][0]["pool"], "sapling");

    let testnet = scan_json(&ufvk_str, "test", &payload);
    assert!(testnet.get("error").is_none(), "scanner error: {testnet}");
    assert_eq!(
        testnet["discovered_notes"], 0,
        "testnet's schedule reads this note as pre-Canopy: {testnet}"
    );
}
