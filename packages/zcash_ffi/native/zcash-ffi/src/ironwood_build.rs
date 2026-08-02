use super::parse_network_type_label;
use super::prover_shims::{BuildRng, NoProver};
use orchard::tree::MerkleHashOrchard;
use rand_chacha::rand_core::SeedableRng;
use rand_chacha::ChaCha20Rng;
use sapling::value::NoteValue;
use sapling::{
    Anchor as SaplingAnchor, IncrementalWitness, MerklePath, Note as SaplingNote, Rseed,
};
use secp256k1::{PublicKey, SecretKey};
use serde_json::{json, Value};
use std::convert::Infallible;
use std::path::Path;
use zcash_keys::address::Address;
use zcash_keys::keys::UnifiedSpendingKey;
use zcash_primitives::merkle_tree::{read_commitment_tree, read_incremental_witness};
use zcash_primitives::transaction::builder::{BuildConfig, Builder, BundlePadding};
use zcash_primitives::transaction::fees::fixed::FeeRule as FixedFeeRule;
use zcash_primitives::transaction::fees::zip317::FeeRule as Zip317FeeRule;
use zcash_primitives::transaction::fees::FeeRule;
use zcash_protocol::consensus::{BlockHeight, Network, NetworkType, NetworkUpgrade, Parameters};
use zcash_protocol::local_consensus::LocalNetwork;
use zcash_protocol::memo::MemoBytes;
use zcash_protocol::value::{Zatoshis, MAX_MONEY};
use zcash_transparent::address::TransparentAddress;
use zcash_transparent::builder::TransparentSigningSet;
use zcash_transparent::bundle::{OutPoint, TxOut};
use zip32::AccountId;

const IRONWOOD_BUILD_VERSION: u64 = 1;

const IRONWOOD_TREE_DEPTH: u8 = orchard::NOTE_COMMITMENT_TREE_DEPTH as u8;

type BuildError = (String, String);

fn err(category: &str, message: &str) -> BuildError {
    (category.to_string(), message.to_string())
}

#[derive(Clone, Copy)]
enum AnchorSource {
    Anchor,
    Tree,
}

impl AnchorSource {
    fn label(self) -> &'static str {
        match self {
            AnchorSource::Anchor => "anchor",
            AnchorSource::Tree => "tree",
        }
    }
}

struct ParsedInput {
    outpoint_hash: [u8; 32],
    vout: u32,
    value: u64,
    secret_key: SecretKey,
}

struct ParsedOutput {
    address: String,
    value: u64,
    memo: MemoBytes,
}

struct ParsedIronwoodOutput {
    address: String,
    value: Option<u64>,
    memo: MemoBytes,
    ovk: Option<orchard::keys::OutgoingViewingKey>,
}

struct ParsedSaplingSpend {
    value: u64,
    recipient: String,
    rseed: [u8; 32],
    witness_bytes: Vec<u8>,
    anchor: [u8; 32],
}

/// V2 (Orchard, ZIP 212) and V3 (Ironwood, ZIP 2005) notes commit differently.
struct ParsedOrchardFamilySpend {
    value: u64,
    recipient: String,
    rseed: [u8; 32],
    rho: [u8; 32],
    note_version: String,
    witness_bytes: Vec<u8>,
    anchor: [u8; 32],
}

fn parse_orchard_family_spends(
    request: &Value,
    field: &str,
    label: &str,
) -> Result<Vec<ParsedOrchardFamilySpend>, BuildError> {
    let mut spends = Vec::new();
    let Some(raw) = request.get(field) else {
        return Ok(spends);
    };
    let raw = raw
        .as_array()
        .ok_or_else(|| err("invalid_request", &format!("{field} must be an array")))?;
    for entry in raw {
        if !entry.is_object() {
            return Err(err(
                "invalid_request",
                &format!("each {field} entry must be a JSON object"),
            ));
        }
        let value = read_zatoshis(entry, "value_zatoshis")?;
        if value == 0 {
            return Err(err(
                "invalid_request",
                &format!("{label} spend value_zatoshis must be positive"),
            ));
        }
        let recipient = entry
            .get("recipient")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                err(
                    "invalid_request",
                    &format!("{label} spend recipient must be a string"),
                )
            })?
            .to_string();
        let rseed = read_hex_32(entry, "rseed", "invalid_request")?;
        let rho = read_hex_32(entry, "rho", "invalid_request")?;
        let note_version = entry
            .get("note_version")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                err(
                    "invalid_request",
                    &format!("{label} spend note_version must be a string ('v2' or 'v3')"),
                )
            })?
            .to_string();
        let witness_hex = entry
            .get("witness")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                err(
                    "invalid_request",
                    &format!("{label} spend witness must be a hex string"),
                )
            })?;
        let witness_bytes = hex::decode(witness_hex.trim()).map_err(|_| {
            err(
                "invalid_request",
                &format!("{label} spend witness is not valid hex"),
            )
        })?;
        let anchor = read_hex_32(entry, "anchor", "invalid_request")?;
        spends.push(ParsedOrchardFamilySpend {
            value,
            recipient,
            rseed,
            rho,
            note_version,
            witness_bytes,
            anchor,
        });
    }
    Ok(spends)
}

struct SaplingParams {
    spend_path: String,
    output_path: String,
}

struct ParsedRequest {
    network: NetworkType,
    target_height: u32,
    fee: Option<u64>,
    anchor: orchard::Anchor,
    anchor_source: AnchorSource,
    anchor_tree_size: Option<u64>,
    rng_seed: Option<[u8; 32]>,
    inputs: Vec<ParsedInput>,
    outputs: Vec<ParsedOutput>,
    ironwood_output: ParsedIronwoodOutput,
    sapling_spends: Vec<ParsedSaplingSpend>,
    /// Non-empty selects the ZIP 318 canonical shape.
    orchard_spends: Vec<ParsedOrchardFamilySpend>,
    ironwood_spends: Vec<ParsedOrchardFamilySpend>,
    orchard_change: Option<u64>,
    ironwood_change: Option<u64>,
    /// Required for a ZIP 318 migration, whose expiry is canonical.
    expiry_height: Option<u32>,
    regtest_nu63_activation_height: Option<u32>,
    seed: Option<Vec<u8>>,
    account: AccountId,
    sapling_params: Option<SaplingParams>,
    quote_only: bool,
}

fn regtest_params(nu6_3: Option<u32>) -> LocalNetwork {
    super::staged_regtest::params(Some(nu6_3.unwrap_or(1)))
}

fn read_zatoshis(value: &Value, field: &str) -> Result<u64, BuildError> {
    let raw = value.get(field).and_then(Value::as_u64).ok_or_else(|| {
        err(
            "invalid_request",
            &format!("{field} must be a non-negative integer"),
        )
    })?;
    if raw > MAX_MONEY {
        return Err(err(
            "invalid_request",
            &format!("{field} exceeds max money"),
        ));
    }
    Ok(raw)
}

fn zatoshis(value: u64, field: &str) -> Result<Zatoshis, BuildError> {
    Zatoshis::from_u64(value)
        .map_err(|_| err("invalid_request", &format!("{field} is out of range")))
}

fn read_hex_32(value: &Value, field: &str, category: &str) -> Result<[u8; 32], BuildError> {
    let s = value
        .get(field)
        .and_then(Value::as_str)
        .ok_or_else(|| err("invalid_request", &format!("{field} must be a hex string")))?;
    let bytes =
        hex::decode(s.trim()).map_err(|_| err(category, &format!("{field} is not valid hex")))?;
    if bytes.len() != 32 {
        return Err(err(category, &format!("{field} must be 32 bytes")));
    }
    let mut out = [0u8; 32];
    out.copy_from_slice(&bytes);
    Ok(out)
}

/// The anchor is a required caller input and never defaults to the empty tree.
fn resolve_anchor(
    request: &Value,
) -> Result<(orchard::Anchor, AnchorSource, Option<u64>), BuildError> {
    let has_anchor = request.get("ironwood_anchor").is_some();
    let has_tree = request.get("ironwood_tree").is_some();
    match (has_anchor, has_tree) {
        (true, true) => Err(err(
            "conflicting_ironwood_anchor",
            "supply either ironwood_anchor or ironwood_tree, not both",
        )),
        (false, false) => Err(err(
            "missing_ironwood_anchor",
            "an Ironwood anchor is required: supply ironwood_anchor (a known \
                 root of the Ironwood note commitment tree) or ironwood_tree (the \
                 serialized tree from a lightwalletd GetTreeState). There is no \
                 default; an anchor that is not a known root builds and proves \
                 successfully but is rejected by consensus",
        )),
        (true, false) => {
            let bytes = read_hex_32(request, "ironwood_anchor", "invalid_ironwood_anchor")?;
            let anchor = Option::<orchard::Anchor>::from(orchard::Anchor::from_bytes(bytes))
                .ok_or_else(|| {
                    err(
                        "invalid_ironwood_anchor",
                        "ironwood_anchor is not a canonical Pallas base field element",
                    )
                })?;
            Ok((anchor, AnchorSource::Anchor, None))
        }
        (false, true) => {
            let tree_hex = request
                .get("ironwood_tree")
                .and_then(Value::as_str)
                .ok_or_else(|| err("invalid_request", "ironwood_tree must be a hex string"))?
                .trim();
            // An empty string is a tree the caller states is genuinely empty.
            if tree_hex.is_empty() {
                return Ok((orchard::Anchor::empty_tree(), AnchorSource::Tree, Some(0)));
            }
            let bytes = hex::decode(tree_hex)
                .map_err(|_| err("invalid_ironwood_tree", "ironwood_tree is not valid hex"))?;
            let tree =
                read_commitment_tree::<MerkleHashOrchard, _, IRONWOOD_TREE_DEPTH>(&bytes[..])
                    .map_err(|_| {
                        err(
                            "invalid_ironwood_tree",
                            "ironwood_tree is not a serialized Ironwood note commitment tree",
                        )
                    })?;
            let size = tree.size() as u64;
            Ok((
                orchard::Anchor::from(tree.root()),
                AnchorSource::Tree,
                Some(size),
            ))
        }
    }
}

fn parse_request(request: &Value) -> Result<ParsedRequest, BuildError> {
    if !request.is_object() {
        return Err(err("invalid_request", "request must be a JSON object"));
    }
    if let Some(version) = request.get("ironwood_build_version") {
        match version.as_u64() {
            Some(v) if v == IRONWOOD_BUILD_VERSION => {}
            _ => {
                return Err(err(
                    "unsupported_ironwood_build_version",
                    "ironwood_build_version must be 1",
                ))
            }
        }
    }

    let network_label = request
        .get("network")
        .and_then(Value::as_str)
        .ok_or_else(|| err("invalid_request", "network must be a string"))?;
    let network = parse_network_type_label(network_label).ok_or_else(|| {
        err(
            "unsupported_network",
            "network must be 'main', 'test', or 'regtest'",
        )
    })?;

    let target_height = request
        .get("target_height")
        .and_then(Value::as_u64)
        .ok_or_else(|| {
            err(
                "invalid_request",
                "target_height must be a non-negative integer",
            )
        })?;
    if target_height == 0 || target_height > u64::from(u32::MAX) {
        return Err(err("invalid_height", "target_height is out of range"));
    }
    let target_height = target_height as u32;

    // None: the builder computes the ZIP 317 fee.
    let fee = match request.get("fee_zatoshis") {
        None => None,
        Some(_) => Some(read_zatoshis(request, "fee_zatoshis")?),
    };

    let (anchor, anchor_source, anchor_tree_size) = resolve_anchor(request)?;

    // A seed makes a broadcastable build reproducible, so only test builds accept it.
    let rng_seed = match request.get("rng_seed") {
        None => None,
        #[cfg(any(test, feature = "deterministic-build-rng"))]
        Some(_) => Some(read_hex_32(request, "rng_seed", "invalid_rng_seed")?),
        #[cfg(not(any(test, feature = "deterministic-build-rng")))]
        Some(_) => {
            return Err(err(
                "rng_seed_not_permitted",
                "rng_seed makes a broadcastable build reproducible and is refused \
                     outside a library compiled with the deterministic-build-rng feature",
            ))
        }
    };

    let empty = Vec::new();
    let raw_inputs = match request.get("inputs") {
        None => &empty,
        Some(v) => v
            .as_array()
            .ok_or_else(|| err("invalid_request", "inputs must be an array"))?,
    };
    let mut inputs = Vec::with_capacity(raw_inputs.len());
    for input in raw_inputs {
        if !input.is_object() {
            return Err(err("invalid_request", "each input must be a JSON object"));
        }
        let txid = read_hex_32(input, "txid", "invalid_txid")?;
        let vout = input
            .get("vout")
            .and_then(Value::as_u64)
            .filter(|v| *v <= u64::from(u32::MAX))
            .ok_or_else(|| err("invalid_request", "vout must be a u32"))? as u32;
        let value = read_zatoshis(input, "value_zatoshis")?;
        if value == 0 {
            return Err(err(
                "invalid_request",
                "input value_zatoshis must be positive",
            ));
        }
        let sk_bytes = read_hex_32(input, "secret_key", "invalid_secret_key")?;
        let secret_key = SecretKey::from_slice(&sk_bytes).map_err(|_| {
            err(
                "invalid_secret_key",
                "secret_key is not a valid secp256k1 key",
            )
        })?;
        // OutPoint hash is the txid in internal (reversed display) byte order.
        let mut outpoint_hash = txid;
        outpoint_hash.reverse();
        inputs.push(ParsedInput {
            outpoint_hash,
            vout,
            value,
            secret_key,
        });
    }

    let mut outputs = Vec::new();
    if let Some(raw) = request.get("outputs") {
        let raw = raw
            .as_array()
            .ok_or_else(|| err("invalid_request", "outputs must be an array"))?;
        for output in raw {
            if !output.is_object() {
                return Err(err("invalid_request", "each output must be a JSON object"));
            }
            let address = output
                .get("address")
                .and_then(Value::as_str)
                .ok_or_else(|| err("invalid_request", "output address must be a string"))?
                .to_string();
            let value = read_zatoshis(output, "value_zatoshis")?;
            if value == 0 {
                return Err(err(
                    "invalid_request",
                    "output value_zatoshis must be positive",
                ));
            }
            outputs.push(ParsedOutput {
                address,
                value,
                memo: read_memo(output)?,
            });
        }
    }

    // ZIP 258 does not restrict Sapling; ZIP 318's canonical shape does not apply here.
    let mut sapling_spends = Vec::new();
    if let Some(raw) = request.get("sapling_spends") {
        let raw = raw
            .as_array()
            .ok_or_else(|| err("invalid_request", "sapling_spends must be an array"))?;
        for entry in raw {
            if !entry.is_object() {
                return Err(err(
                    "invalid_request",
                    "each sapling_spends entry must be a JSON object",
                ));
            }
            let value = read_zatoshis(entry, "value_zatoshis")?;
            if value == 0 {
                return Err(err(
                    "invalid_request",
                    "sapling spend value_zatoshis must be positive",
                ));
            }
            let recipient = entry
                .get("recipient")
                .and_then(Value::as_str)
                .ok_or_else(|| {
                    err(
                        "invalid_request",
                        "sapling spend recipient must be a string",
                    )
                })?
                .to_string();
            let rseed = read_hex_32(entry, "rseed", "invalid_request")?;
            let witness_hex = entry
                .get("witness")
                .and_then(Value::as_str)
                .ok_or_else(|| {
                    err(
                        "invalid_request",
                        "sapling spend witness must be a hex string",
                    )
                })?;
            let witness_bytes = hex::decode(witness_hex.trim())
                .map_err(|_| err("invalid_request", "sapling spend witness is not valid hex"))?;
            let anchor = read_hex_32(entry, "anchor", "invalid_request")?;
            sapling_spends.push(ParsedSaplingSpend {
                value,
                recipient,
                rseed,
                witness_bytes,
                anchor,
            });
        }
    }

    let orchard_spends = parse_orchard_family_spends(request, "orchard_spends", "orchard")?;
    let ironwood_spends = parse_orchard_family_spends(request, "ironwood_spends", "ironwood")?;

    let orchard_change = match request.get("orchard_change_zatoshis") {
        None => None,
        Some(_) => Some(read_zatoshis(request, "orchard_change_zatoshis")?),
    };
    let ironwood_change = match request.get("ironwood_change_zatoshis") {
        None => None,
        Some(_) => Some(read_zatoshis(request, "ironwood_change_zatoshis")?),
    };

    let regtest_nu63_activation_height =
        super::staged_regtest::read_activation_height(request, network)?;

    let expiry_height = match request.get("expiry_height") {
        None => None,
        Some(v) => {
            let h = v
                .as_u64()
                .filter(|h| *h > 0 && *h <= u64::from(u32::MAX))
                .ok_or_else(|| err("invalid_height", "expiry_height is out of range"))?;
            Some(h as u32)
        }
    };

    if inputs.is_empty()
        && sapling_spends.is_empty()
        && orchard_spends.is_empty()
        && ironwood_spends.is_empty()
    {
        return Err(err(
            "invalid_request",
            "supply at least one input source: transparent inputs, sapling_spends, \
                 orchard_spends, or ironwood_spends",
        ));
    }

    let seed = match request.get("seed") {
        None => None,
        Some(v) => {
            let seed_hex = v
                .as_str()
                .ok_or_else(|| err("invalid_request", "seed must be a hex string"))?;
            let bytes = hex::decode(seed_hex.trim())
                .map_err(|_| err("invalid_seed", "seed is not valid hex"))?;
            if bytes.len() < 32 {
                return Err(err("invalid_seed", "seed must be at least 32 bytes"));
            }
            Some(bytes)
        }
    };
    let account_index = request
        .get("account")
        .map(|v| {
            v.as_u64()
                .filter(|a| *a <= u64::from(u32::MAX))
                .ok_or_else(|| err("invalid_request", "account must be a u32"))
        })
        .transpose()?
        .unwrap_or(0) as u32;
    let account = AccountId::try_from(account_index)
        .map_err(|_| err("invalid_request", "account index is out of range"))?;

    let sapling_params = match (
        request.get("spend_params_path").and_then(Value::as_str),
        request.get("output_params_path").and_then(Value::as_str),
    ) {
        (Some(s), Some(o)) if !s.is_empty() && !o.is_empty() => Some(SaplingParams {
            spend_path: s.to_string(),
            output_path: o.to_string(),
        }),
        (None, None) => None,
        _ => {
            return Err(err(
                "invalid_request",
                "spend_params_path and output_params_path must be provided together \
                     as non-empty strings",
            ))
        }
    };

    if !orchard_spends.is_empty() {
        check_zip318_canonical_shape(
            &orchard_spends,
            &inputs,
            &outputs,
            &sapling_spends,
            &ironwood_spends,
            seed.is_some(),
            expiry_height,
        )?;
    } else if orchard_change.is_some() {
        return Err(err(
            "orchard_change_without_spend",
            "orchard_change_zatoshis is only accepted alongside an Orchard spend; \
                 value may never enter the Orchard pool (ZIP 258 requires \
                 valueBalanceOrchard >= 0)",
        ));
    }

    if !ironwood_spends.is_empty() && seed.is_none() {
        return Err(err(
            "invalid_request",
            "spending Ironwood notes requires a seed to derive the spend authority",
        ));
    }
    if ironwood_spends.is_empty() && ironwood_change.is_some() {
        return Err(err(
            "ironwood_change_without_spend",
            "ironwood_change_zatoshis is only accepted alongside an Ironwood spend; \
                 without one there is nothing to return, and the Ironwood output \
                 already receives the remainder",
        ));
    }

    if !sapling_spends.is_empty() {
        if seed.is_none() {
            return Err(err(
                "invalid_request",
                "spending Sapling notes requires a seed to derive the spend authority",
            ));
        }
        if sapling_params.is_none() {
            return Err(err(
                "sapling_params_required",
                "spending Sapling notes requires the caller-supplied Sapling MPC \
                     proving parameters (spend_params_path and output_params_path). \
                     There is no placeholder-proof fallback on this path: a migration \
                     transaction that cannot be broadcast is not a useful result",
            ));
        }
    }

    let raw_ironwood = request
        .get("ironwood_output")
        .filter(|v| v.is_object())
        .ok_or_else(|| err("invalid_request", "ironwood_output must be a JSON object"))?;
    let ironwood_address = raw_ironwood
        .get("address")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            err(
                "invalid_request",
                "ironwood_output address must be a string",
            )
        })?
        .to_string();
    let ironwood_value = match raw_ironwood.get("value_zatoshis") {
        None => None,
        Some(_) => Some(read_zatoshis(raw_ironwood, "value_zatoshis")?),
    };
    let memo = match raw_ironwood.get("memo") {
        None => MemoBytes::empty(),
        Some(v) => {
            let memo_hex = v
                .as_str()
                .ok_or_else(|| err("invalid_memo", "ironwood_output memo must be a hex string"))?;
            let bytes = hex::decode(memo_hex.trim())
                .map_err(|_| err("invalid_memo", "ironwood_output memo is not valid hex"))?;
            if bytes.len() > 512 {
                return Err(err("invalid_memo", "memo must be at most 512 bytes"));
            }
            MemoBytes::from_bytes(&bytes).map_err(|_| err("invalid_memo", "memo is invalid"))?
        }
    };
    let ovk = match raw_ironwood.get("outgoing_viewing_key") {
        None => None,
        Some(_) => Some(orchard::keys::OutgoingViewingKey::from(read_hex_32(
            raw_ironwood,
            "outgoing_viewing_key",
            "invalid_outgoing_viewing_key",
        )?)),
    };

    Ok(ParsedRequest {
        network,
        target_height,
        fee,
        anchor,
        anchor_source,
        anchor_tree_size,
        rng_seed,
        inputs,
        outputs,
        ironwood_output: ParsedIronwoodOutput {
            address: ironwood_address,
            value: ironwood_value,
            memo,
            ovk,
        },
        sapling_spends,
        orchard_spends,
        ironwood_spends,
        orchard_change,
        ironwood_change,
        expiry_height,
        regtest_nu63_activation_height,
        seed,
        account,
        sapling_params,
        quote_only: request
            .get("quote_only")
            .and_then(Value::as_bool)
            .unwrap_or(false),
    })
}

/// Checks the ZIP 318 shape; denomination, anchor and expiry are the caller's to check.
fn check_zip318_canonical_shape(
    orchard_spends: &[ParsedOrchardFamilySpend],
    inputs: &[ParsedInput],
    outputs: &[ParsedOutput],
    sapling_spends: &[ParsedSaplingSpend],
    ironwood_spends: &[ParsedOrchardFamilySpend],
    has_seed: bool,
    expiry_height: Option<u32>,
) -> Result<(), BuildError> {
    if orchard_spends.len() != 1 {
        return Err(err(
            "non_canonical_orchard_migration",
            "a ZIP 318 migration transaction has exactly one Orchard spend; \
                 migrate a larger balance as a schedule of canonical transactions, \
                 not as one transaction with several spends",
        ));
    }
    if !inputs.is_empty() || !outputs.is_empty() {
        return Err(err(
            "non_canonical_orchard_migration",
            "a ZIP 318 migration transaction has no transparent inputs or \
                 outputs and no outputs other than the Ironwood one",
        ));
    }
    if !sapling_spends.is_empty() {
        return Err(err(
            "non_canonical_orchard_migration",
            "a ZIP 318 migration transaction spends from no pool other than \
                 Orchard; migrate Sapling notes in their own transaction (Path B)",
        ));
    }
    if !ironwood_spends.is_empty() {
        return Err(err(
            "non_canonical_orchard_migration",
            "a ZIP 318 migration transaction spends from no pool other than \
                 Orchard, and that includes Ironwood. Funding a migration from the \
                 pool it migrates into would add an action to a bundle whose action \
                 count is the anonymity set, and would link the migrated note to \
                 funds already there — spend Ironwood in its own transaction",
        ));
    }
    if !has_seed {
        return Err(err(
            "invalid_request",
            "spending Orchard notes requires a seed to derive the spend authority",
        ));
    }
    if expiry_height.is_none() {
        return Err(err(
            "missing_canonical_expiry_height",
            "a ZIP 318 migration transaction requires an explicit expiry_height. \
                 The builder's default (target_height + 40) is wallet-specific, and \
                 the canonical expiry — the most recent multiple of EXPIRY_MODULUS at \
                 or below the broadcast height, plus two more — is what makes the \
                 expiry field stop separating wallets. There is no default here for \
                 the same reason there is none for the anchor",
        ));
    }
    Ok(())
}

pub fn build_ironwood_transaction_json(request: &Value) -> Result<Value, BuildError> {
    let parsed = parse_request(request)?;
    match parsed.network {
        NetworkType::Main => build_for_params(Network::MainNetwork, &parsed),
        NetworkType::Test => build_for_params(Network::TestNetwork, &parsed),
        NetworkType::Regtest => build_for_params(
            regtest_params(parsed.regtest_nu63_activation_height),
            &parsed,
        ),
    }
}

fn build_for_params<P: Parameters + Copy>(
    params: P,
    req: &ParsedRequest,
) -> Result<Value, BuildError> {
    if !params.is_nu_active(
        NetworkUpgrade::Nu6_3,
        BlockHeight::from_u32(req.target_height),
    ) {
        return Err(err(
            "ironwood_not_active",
            "NU6.3 (Ironwood) is not active at target_height on this network; \
                 no Ironwood bundle can be built before activation",
        ));
    }
    match req.fee {
        Some(fee) => {
            let fee_rule = FixedFeeRule::non_standard(zatoshis(fee, "fee_zatoshis")?);
            build_with_fee_rule(params, req, &fee_rule, "fixed")
        }
        None => build_with_fee_rule(params, req, &Zip317FeeRule::standard(), "zip317"),
    }
}

fn populate<P: Parameters + Copy>(
    params: P,
    req: &ParsedRequest,
    ironwood_value: Zatoshis,
) -> Result<PopulatedBuilder<P>, BuildError> {
    let sapling = decode_sapling_spends(params, req)?;
    let orchard = decode_orchard_spends(params, req)?;
    let ironwood = decode_ironwood_spends(params, req)?;
    let build_config = BuildConfig::Standard {
        sapling_anchor: sapling.as_ref().map(|s| s.anchor),
        orchard_anchor: orchard.as_ref().map(|o| o.anchor),
        ironwood_anchor: Some(req.anchor),
        orchard_padding: BundlePadding::DEFAULT,
        ironwood_padding: if orchard.is_some() {
            BundlePadding::UNPADDED
        } else {
            BundlePadding::DEFAULT
        },
    };
    let mut builder = Builder::new(
        params,
        BlockHeight::from_u32(req.target_height),
        build_config,
    );
    if let Some(expiry) = req.expiry_height {
        builder = builder.with_expiry_height(BlockHeight::from_u32(expiry));
    }
    let mut signing_set = TransparentSigningSet::new();
    let mut sapling_keys = Vec::new();
    let mut sapling_ovk = None;
    let mut orchard_keys = Vec::new();

    if let Some(orchard) = orchard {
        for (note, path) in orchard.notes {
            builder
                .add_orchard_spend::<Infallible>(orchard.fvk.clone(), note, path)
                .map_err(map_add_orchard_spend_error)?;
        }
        // No ZIP 326 same-address output here: `build_bundle` already adds it per spend.
        if let Some(change) = req.orchard_change {
            if change > 0 {
                builder
                    .add_orchard_change_output::<Infallible>(
                        orchard.fvk.clone(),
                        Some(orchard.internal_ovk.clone()),
                        orchard.change_address,
                        zatoshis(change, "orchard_change_zatoshis")?,
                        MemoBytes::empty(),
                    )
                    .map_err(|_| {
                        err("invalid_output", "could not add the Orchard change output")
                    })?;
            }
        }
        orchard_keys.push(orchard.ask);
    }

    if let Some(ironwood) = ironwood {
        for (note, path) in ironwood.notes {
            builder
                .add_ironwood_spend::<Infallible>(ironwood.fvk.clone(), note, path)
                .map_err(map_add_ironwood_spend_error)?;
        }
        if let Some(change) = req.ironwood_change {
            if change > 0 {
                builder
                    .add_ironwood_output::<Infallible>(
                        Some(ironwood.internal_ovk.clone()),
                        ironwood.change_address,
                        zatoshis(change, "ironwood_change_zatoshis")?,
                        MemoBytes::empty(),
                    )
                    .map_err(|_| {
                        err("invalid_output", "could not add the Ironwood change output")
                    })?;
            }
        }
        orchard_keys.push(ironwood.ask);
    }

    if let Some(sapling) = sapling {
        for (note, path) in sapling.notes {
            builder
                .add_sapling_spend::<Infallible>(sapling.fvk.clone(), note, path)
                .map_err(map_add_spend_error)?;
        }
        sapling_ovk = Some(sapling.ovk);
        sapling_keys.push(sapling.extsk);
    }

    for input in &req.inputs {
        let pubkey: PublicKey = signing_set.add_key(input.secret_key);
        let coin = TxOut::new(
            zatoshis(input.value, "value_zatoshis")?,
            TransparentAddress::from_pubkey(&pubkey).script().into(),
        );
        builder
            .add_transparent_p2pkh_input(
                pubkey,
                OutPoint::new(input.outpoint_hash, input.vout),
                coin,
            )
            .map_err(|_| err("invalid_input", "could not add transparent input"))?;
    }

    for output in &req.outputs {
        match decode_output_address(&params, &output.address)? {
            OutputDestination::Transparent(to) => builder
                .add_transparent_output(&to, zatoshis(output.value, "value_zatoshis")?)
                .map_err(|_| err("invalid_output", "could not add transparent output"))?,
            OutputDestination::Sapling(pa) => {
                let ovk = sapling_ovk.ok_or_else(|| {
                    err(
                        "sapling_output_without_spend",
                        "a Sapling output is only accepted as change from a Sapling \
                             spend; this build spends no Sapling notes",
                    )
                })?;
                builder
                    .add_sapling_output::<Infallible>(
                        Some(ovk),
                        pa,
                        zatoshis(output.value, "value_zatoshis")?,
                        output.memo.clone(),
                    )
                    .map_err(|_| err("invalid_output", "could not add Sapling output"))?;
            }
        }
    }

    let recipient = ironwood_recipient(&params, &req.ironwood_output.address)?;
    builder
        .add_ironwood_output::<std::convert::Infallible>(
            req.ironwood_output.ovk.clone(),
            recipient,
            ironwood_value,
            req.ironwood_output.memo.clone(),
        )
        .map_err(|_| err("invalid_output", "could not add the Ironwood output"))?;

    Ok((builder, signing_set, sapling_keys, orchard_keys))
}

type SaplingSpendKey = sapling::zip32::ExtendedSpendingKey;
type OrchardSpendKey = orchard::keys::SpendAuthorizingKey;

type PopulatedBuilder<P> = (
    Builder<P, ()>,
    TransparentSigningSet,
    Vec<SaplingSpendKey>,
    Vec<OrchardSpendKey>,
);

struct PreparedSapling {
    extsk: SaplingSpendKey,
    fvk: sapling::keys::FullViewingKey,
    ovk: sapling::keys::OutgoingViewingKey,
    anchor: SaplingAnchor,
    notes: Vec<(SaplingNote, MerklePath)>,
}

fn decode_sapling_spends<P: Parameters + Copy>(
    params: P,
    req: &ParsedRequest,
) -> Result<Option<PreparedSapling>, BuildError> {
    if req.sapling_spends.is_empty() {
        return Ok(None);
    }
    let seed = req.seed.as_ref().ok_or_else(|| {
        err(
            "invalid_request",
            "a seed is required to spend Sapling notes",
        )
    })?;
    let usk = UnifiedSpendingKey::from_seed(&params, seed, req.account).map_err(|_| {
        err(
            "derivation_error",
            "could not derive a spending key from the seed",
        )
    })?;
    let extsk = usk.sapling().clone();
    let dfvk = extsk.to_diversifiable_full_viewing_key();
    let fvk = dfvk.fvk().clone();
    let ovk = dfvk.fvk().ovk;

    let mut notes = Vec::with_capacity(req.sapling_spends.len());
    let mut anchor_bytes: Option<[u8; 32]> = None;
    for spend in &req.sapling_spends {
        let pa = match Address::decode(&params, &spend.recipient) {
            Some(Address::Sapling(pa)) => pa,
            _ => {
                return Err(err(
                    "invalid_request",
                    "sapling spend recipient must be a Sapling address for the network",
                ))
            }
        };
        if fvk.vk.to_payment_address(*pa.diversifier()) != Some(pa) {
            return Err(err(
                "note_not_spendable",
                "sapling spend recipient is not spendable by the account viewing key",
            ));
        }
        let note = pa.create_note(
            NoteValue::from_raw(spend.value),
            Rseed::AfterZip212(spend.rseed),
        );
        let witness: IncrementalWitness = read_incremental_witness(&spend.witness_bytes[..])
            .map_err(|_| err("invalid_request", "sapling spend witness is malformed"))?;
        if witness.root().to_bytes() != spend.anchor {
            return Err(err(
                "witness_anchor_mismatch",
                "sapling spend witness is not rooted at the supplied anchor",
            ));
        }
        match anchor_bytes {
            None => anchor_bytes = Some(spend.anchor),
            Some(existing) if existing != spend.anchor => {
                return Err(err(
                    "anchor_mismatch",
                    "all Sapling spends in one build must share the same anchor",
                ))
            }
            Some(_) => {}
        }
        let path = witness.path().ok_or_else(|| {
            err(
                "invalid_request",
                "sapling spend witness has no Merkle path",
            )
        })?;
        notes.push((note, path));
    }

    let bytes = anchor_bytes.expect("sapling_spends is non-empty");
    let anchor = Option::<SaplingAnchor>::from(SaplingAnchor::from_bytes(bytes))
        .ok_or_else(|| err("invalid_request", "sapling anchor is not a valid tree root"))?;
    Ok(Some(PreparedSapling {
        extsk,
        fvk,
        ovk,
        anchor,
        notes,
    }))
}

struct PreparedOrchard {
    ask: OrchardSpendKey,
    fvk: orchard::keys::FullViewingKey,
    change_address: orchard::Address,
    internal_ovk: orchard::keys::OutgoingViewingKey,
    anchor: orchard::Anchor,
    notes: Vec<(orchard::Note, orchard::tree::MerklePath)>,
}

fn decode_orchard_spends<P: Parameters + Copy>(
    params: P,
    req: &ParsedRequest,
) -> Result<Option<PreparedOrchard>, BuildError> {
    use incrementalmerkletree::witness::IncrementalWitness;
    use orchard::keys::{FullViewingKey, Scope, SpendAuthorizingKey};
    use orchard::note::{ExtractedNoteCommitment, Note, NoteVersion, RandomSeed, Rho};
    use orchard::value::NoteValue as OrchardNoteValue;

    if req.orchard_spends.is_empty() {
        return Ok(None);
    }
    let seed = req.seed.as_ref().ok_or_else(|| {
        err(
            "invalid_request",
            "a seed is required to spend Orchard notes",
        )
    })?;
    let usk = UnifiedSpendingKey::from_seed(&params, seed, req.account).map_err(|_| {
        err(
            "derivation_error",
            "could not derive a spending key from the seed",
        )
    })?;
    let sk = usk.orchard();
    let ask = SpendAuthorizingKey::from(sk);
    let fvk = FullViewingKey::from(sk);

    let mut notes = Vec::with_capacity(req.orchard_spends.len());
    let mut anchor_bytes: Option<[u8; 32]> = None;
    for spend in &req.orchard_spends {
        let version = match spend.note_version.as_str() {
            "v2" => NoteVersion::V2,
            "v3" => {
                return Err(err(
                    "unsupported_orchard_note_version",
                    "a v3 note is an Ironwood note, not an Orchard one: it is \
                         already in the destination pool, so there is nothing to \
                         migrate. The two pools share an action shape but have \
                         separate commitment trees and nullifier sets",
                ))
            }
            _ => {
                return Err(err(
                    "invalid_request",
                    "orchard spend note_version must be 'v2' or 'v3'",
                ))
            }
        };

        let recipient = match Address::decode(&params, &spend.recipient) {
            Some(Address::Unified(ua)) => ua.orchard().copied().ok_or_else(|| {
                err(
                    "invalid_request",
                    "orchard spend recipient must carry an Orchard receiver",
                )
            })?,
            _ => {
                return Err(err(
                    "invalid_request",
                    "orchard spend recipient must be a Unified Address with an \
                         Orchard receiver, for the request network",
                ))
            }
        };
        if fvk.scope_for_address(&recipient).is_none() {
            return Err(err(
                "note_not_spendable",
                "orchard spend recipient is not an address of the account viewing key",
            ));
        }

        let rho = Option::<Rho>::from(Rho::from_bytes(&spend.rho)).ok_or_else(|| {
            err(
                "invalid_request",
                "orchard spend rho is not a canonical value",
            )
        })?;
        let rseed = Option::<RandomSeed>::from(RandomSeed::from_bytes(spend.rseed, &rho))
            .ok_or_else(|| {
                err(
                    "invalid_request",
                    "orchard spend rseed does not belong to the supplied rho",
                )
            })?;
        let note = Option::<Note>::from(Note::from_parts(
            recipient,
            OrchardNoteValue::from_raw(spend.value),
            rho,
            rseed,
            version,
        ))
        .ok_or_else(|| {
            err(
                "invalid_request",
                "the orchard spend note components do not form a valid note",
            )
        })?;

        let witness: IncrementalWitness<MerkleHashOrchard, IRONWOOD_TREE_DEPTH> =
            read_incremental_witness(&spend.witness_bytes[..])
                .map_err(|_| err("invalid_request", "orchard spend witness is malformed"))?;
        let path = witness.path().ok_or_else(|| {
            err(
                "invalid_request",
                "orchard spend witness has no Merkle path",
            )
        })?;
        let path = orchard::tree::MerklePath::from(path);

        let anchor = Option::<orchard::Anchor>::from(orchard::Anchor::from_bytes(spend.anchor))
            .ok_or_else(|| {
                err(
                    "invalid_request",
                    "orchard spend anchor is not a canonical tree root",
                )
            })?;
        let cmx = ExtractedNoteCommitment::from(note.commitment());
        if path.root(cmx) != anchor {
            return Err(err(
                "witness_anchor_mismatch",
                "the orchard spend witness does not witness this note against the \
                     supplied anchor",
            ));
        }
        match anchor_bytes {
            None => anchor_bytes = Some(spend.anchor),
            Some(existing) if existing != spend.anchor => {
                return Err(err(
                    "anchor_mismatch",
                    "all Orchard spends in one build must share the same anchor",
                ))
            }
            Some(_) => {}
        }
        notes.push((note, path));
    }

    let bytes = anchor_bytes.expect("orchard_spends is non-empty");
    let anchor = Option::<orchard::Anchor>::from(orchard::Anchor::from_bytes(bytes))
        .ok_or_else(|| err("invalid_request", "orchard anchor is not a valid tree root"))?;
    Ok(Some(PreparedOrchard {
        ask,
        change_address: fvk.address_at(0u32, Scope::Internal),
        internal_ovk: fvk.to_ovk(Scope::Internal),
        fvk,
        anchor,
        notes,
    }))
}

/// Ironwood spends are ordinary payments; the ZIP 318 shape is Orchard-only.
fn decode_ironwood_spends<P: Parameters + Copy>(
    params: P,
    req: &ParsedRequest,
) -> Result<Option<PreparedOrchard>, BuildError> {
    use incrementalmerkletree::witness::IncrementalWitness;
    use orchard::keys::{FullViewingKey, Scope, SpendAuthorizingKey};
    use orchard::note::{ExtractedNoteCommitment, Note, NoteVersion, RandomSeed, Rho};
    use orchard::value::NoteValue as OrchardNoteValue;

    if req.ironwood_spends.is_empty() {
        return Ok(None);
    }
    let seed = req.seed.as_ref().ok_or_else(|| {
        err(
            "invalid_request",
            "a seed is required to spend Ironwood notes",
        )
    })?;
    let usk = UnifiedSpendingKey::from_seed(&params, seed, req.account).map_err(|_| {
        err(
            "derivation_error",
            "could not derive a spending key from the seed",
        )
    })?;
    // ZIP 229 adds no key type: the Orchard spending key spends both pools.
    let sk = usk.orchard();
    let ask = SpendAuthorizingKey::from(sk);
    let fvk = FullViewingKey::from(sk);

    let mut notes = Vec::with_capacity(req.ironwood_spends.len());
    for spend in &req.ironwood_spends {
        let version = match spend.note_version.as_str() {
            "v3" => NoteVersion::V3,
            "v2" => {
                return Err(err(
                    "unsupported_ironwood_note_version",
                    "a v2 note is an Orchard note, not an Ironwood one. Spending it \
                         here would place it in the Ironwood bundle, against a tree and \
                         a nullifier set it has never been part of; move it with a ZIP \
                         318 migration (orchard_spends) instead",
                ))
            }
            _ => {
                return Err(err(
                    "invalid_request",
                    "ironwood spend note_version must be 'v2' or 'v3'",
                ))
            }
        };

        let recipient = match Address::decode(&params, &spend.recipient) {
            Some(Address::Unified(ua)) => ua.orchard().copied().ok_or_else(|| {
                err(
                    "invalid_request",
                    "ironwood spend recipient must carry an Orchard receiver",
                )
            })?,
            _ => {
                return Err(err(
                    "invalid_request",
                    "ironwood spend recipient must be a Unified Address with an \
                         Orchard receiver, for the request network",
                ))
            }
        };
        if fvk.scope_for_address(&recipient).is_none() {
            return Err(err(
                "note_not_spendable",
                "ironwood spend recipient is not an address of the account viewing key",
            ));
        }

        let rho = Option::<Rho>::from(Rho::from_bytes(&spend.rho)).ok_or_else(|| {
            err(
                "invalid_request",
                "ironwood spend rho is not a canonical value",
            )
        })?;
        let rseed = Option::<RandomSeed>::from(RandomSeed::from_bytes(spend.rseed, &rho))
            .ok_or_else(|| {
                err(
                    "invalid_request",
                    "ironwood spend rseed does not belong to the supplied rho",
                )
            })?;
        let note = Option::<Note>::from(Note::from_parts(
            recipient,
            OrchardNoteValue::from_raw(spend.value),
            rho,
            rseed,
            version,
        ))
        .ok_or_else(|| {
            err(
                "invalid_request",
                "the ironwood spend note components do not form a valid note",
            )
        })?;

        let witness: IncrementalWitness<MerkleHashOrchard, IRONWOOD_TREE_DEPTH> =
            read_incremental_witness(&spend.witness_bytes[..])
                .map_err(|_| err("invalid_request", "ironwood spend witness is malformed"))?;
        let path = witness.path().ok_or_else(|| {
            err(
                "invalid_request",
                "ironwood spend witness has no Merkle path",
            )
        })?;
        let path = orchard::tree::MerklePath::from(path);

        let anchor = Option::<orchard::Anchor>::from(orchard::Anchor::from_bytes(spend.anchor))
            .ok_or_else(|| {
                err(
                    "invalid_request",
                    "ironwood spend anchor is not a canonical tree root",
                )
            })?;
        let cmx = ExtractedNoteCommitment::from(note.commitment());
        if path.root(cmx) != anchor {
            return Err(err(
                "witness_anchor_mismatch",
                "the ironwood spend witness does not witness this note against the \
                     supplied anchor",
            ));
        }
        if anchor != req.anchor {
            return Err(err(
                "ironwood_anchor_mismatch",
                "an ironwood spend is witnessed against a different anchor than the \
                     transaction's ironwood_anchor; the spend's witness and the \
                     transaction's anchor must come from one state of one tree",
            ));
        }
        notes.push((note, path));
    }

    Ok(Some(PreparedOrchard {
        ask,
        change_address: fvk.address_at(0u32, Scope::Internal),
        internal_ovk: fvk.to_ovk(Scope::Internal),
        fvk,
        anchor: req.anchor,
        notes,
    }))
}

fn load_sapling_params(p: &SaplingParams) -> Result<zcash_proofs::ZcashParameters, BuildError> {
    let spend = Path::new(&p.spend_path).to_path_buf();
    let output = Path::new(&p.output_path).to_path_buf();
    if !spend.is_file() || !output.is_file() {
        return Err(err(
            "params_not_found",
            "a Sapling parameter file was not found",
        ));
    }
    let previous_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(|_| {}));
    let loaded = std::panic::catch_unwind(|| zcash_proofs::load_parameters(&spend, &output, None));
    std::panic::set_hook(previous_hook);
    loaded.map_err(|_| {
        err(
            "params_invalid",
            "the Sapling parameters failed size/hash verification",
        )
    })
}

fn map_add_spend_error(
    error: zcash_primitives::transaction::builder::Error<Infallible>,
) -> BuildError {
    use zcash_primitives::transaction::builder::Error;
    match error {
        Error::SaplingBuild(sapling::builder::Error::AnchorMismatch) => err(
            "witness_anchor_mismatch",
            "a Sapling spend witness does not witness the supplied note against the anchor",
        ),
        _ => err("invalid_input", "could not add a Sapling spend"),
    }
}

fn map_add_ironwood_spend_error(
    error: zcash_primitives::transaction::builder::Error<Infallible>,
) -> BuildError {
    use zcash_primitives::transaction::builder::Error;
    match error {
        Error::IronwoodBuilderNotAvailable => err(
            "ironwood_builder_unavailable",
            "no Ironwood bundle is configured for this transaction",
        ),
        _ => err("invalid_input", "could not add an Ironwood spend"),
    }
}

fn map_add_orchard_spend_error(
    error: zcash_primitives::transaction::builder::Error<Infallible>,
) -> BuildError {
    use zcash_primitives::transaction::builder::Error;
    match error {
        Error::OrchardBuilderNotAvailable => err(
            "orchard_builder_unavailable",
            "no Orchard bundle is configured for this transaction",
        ),
        _ => err("invalid_input", "could not add an Orchard spend"),
    }
}

fn build_with_fee_rule<P: Parameters + Copy, FR: FeeRule>(
    params: P,
    req: &ParsedRequest,
    fee_rule: &FR,
    fee_rule_label: &str,
) -> Result<Value, BuildError>
where
    FR::Error: std::fmt::Display,
{
    let transparent_input_total: u64 = req
        .inputs
        .iter()
        .try_fold(0u64, |acc, i| acc.checked_add(i.value))
        .ok_or_else(|| err("invalid_request", "total input value overflows"))?;
    let sapling_input_total: u64 = req
        .sapling_spends
        .iter()
        .try_fold(0u64, |acc, sp| acc.checked_add(sp.value))
        .ok_or_else(|| err("invalid_request", "total input value overflows"))?;
    let orchard_input_total: u64 = req
        .orchard_spends
        .iter()
        .try_fold(0u64, |acc, sp| acc.checked_add(sp.value))
        .ok_or_else(|| err("invalid_request", "total input value overflows"))?;
    let ironwood_input_total: u64 = req
        .ironwood_spends
        .iter()
        .try_fold(0u64, |acc, sp| acc.checked_add(sp.value))
        .ok_or_else(|| err("invalid_request", "total input value overflows"))?;
    let total_input = transparent_input_total
        .checked_add(sapling_input_total)
        .and_then(|v| v.checked_add(orchard_input_total))
        .and_then(|v| v.checked_add(ironwood_input_total))
        .ok_or_else(|| err("invalid_request", "total input value overflows"))?;
    // ZIP 258: `valueBalanceOrchard >= 0`, so Orchard change cannot exceed what was spent.
    let orchard_change_total = req.orchard_change.unwrap_or(0);
    if orchard_change_total > orchard_input_total {
        return Err(err(
            "invalid_request",
            "orchard change exceeds the value spent from Orchard; no new value \
                 may enter the Orchard pool (ZIP 258)",
        ));
    }
    let ironwood_change_total = req.ironwood_change.unwrap_or(0);
    let output_total: u64 = req
        .outputs
        .iter()
        .try_fold(0u64, |acc, o| acc.checked_add(o.value))
        .and_then(|v| v.checked_add(orchard_change_total))
        .and_then(|v| v.checked_add(ironwood_change_total))
        .ok_or_else(|| err("invalid_request", "total output value overflows"))?;

    let (probe, _, _, _) = populate(params, req, Zatoshis::ZERO)?;
    let fee = probe
        .get_fee(fee_rule)
        .map_err(|_| err("fee_failed", "could not compute the transaction fee"))?;
    let fee_zatoshis = u64::from(fee);
    drop(probe);

    let max_ironwood_output = total_input
        .checked_sub(output_total)
        .and_then(|v| v.checked_sub(fee_zatoshis));

    if req.quote_only {
        return Ok(json!({
            "quote_only": true,
            "network": super::network_type_label(req.network),
            "fee_zatoshis": fee_zatoshis,
            "fee_rule": fee_rule_label,
            "consensus_branch_id": super::branch_id_label(zcash_protocol::consensus::BranchId::for_height(
                &params,
                BlockHeight::from_u32(req.target_height),
            )),
            "total_input_zatoshis": total_input,
            "non_ironwood_output_zatoshis": output_total,
            "max_ironwood_output_zatoshis": max_ironwood_output,
            "ironwood_spends": req.ironwood_spends.len(),
            "orchard_spends": req.orchard_spends.len(),
            "sapling_spends": req.sapling_spends.len(),
            "transparent_inputs": req.inputs.len(),
        }));
    }

    let ironwood_value = match req.ironwood_output.value {
        Some(v) => v,
        None => max_ironwood_output.ok_or_else(|| {
            err(
                "insufficient_funds",
                "inputs do not cover the transparent outputs plus fee",
            )
        })?,
    };
    if ironwood_value == 0 {
        return Err(err(
            "invalid_request",
            "the Ironwood output value must be positive",
        ));
    }

    let (builder, signing_set, sapling_keys, orchard_keys) =
        populate(params, req, zatoshis(ironwood_value, "value_zatoshis")?)?;
    let rng = match req.rng_seed {
        Some(seed) => BuildRng::Deterministic(Box::new(ChaCha20Rng::from_seed(seed))),
        None => BuildRng::Os(rand_core::OsRng),
    };

    let result = match &req.sapling_params {
        Some(p) if !req.sapling_spends.is_empty() => {
            let zp = load_sapling_params(p)?;
            builder.build(
                &signing_set,
                &sapling_keys,
                &orchard_keys,
                rng,
                &zp.spend_params,
                &zp.output_params,
                fee_rule,
            )
        }
        _ => builder.build(
            &signing_set,
            &sapling_keys,
            &orchard_keys,
            rng,
            &NoProver,
            &NoProver,
            fee_rule,
        ),
    }
    .map_err(map_build_error)?;
    let tx = result.transaction();

    let mut raw = Vec::new();
    tx.write(&mut raw).map_err(|_| {
        err(
            "serialize_failed",
            "could not serialize the built transaction",
        )
    })?;

    let ironwood_actions = tx.ironwood_bundle().map_or(0, |b| b.actions().len());
    let orchard_actions = tx.orchard_bundle().map_or(0, |b| b.actions().len());
    let sapling_spends = tx.sapling_bundle().map_or(0, |b| b.shielded_spends().len());
    let sapling_outputs = tx
        .sapling_bundle()
        .map_or(0, |b| b.shielded_outputs().len());
    let transparent_vin = tx.transparent_bundle().map_or(0, |b| b.vin.len());
    let transparent_vout = tx.transparent_bundle().map_or(0, |b| b.vout.len());

    Ok(json!({
        "network": super::network_type_label(req.network),
        "transaction": hex::encode(&raw),
        "txid": tx.txid().to_string(),
        "version": super::tx_version_label(tx.version()),
        "expiry_height": u32::from(tx.expiry_height()),
        "fee_zatoshis": fee_zatoshis,
        "fee_rule": fee_rule_label,
        "consensus_branch_id": super::branch_id_label(tx.consensus_branch_id()),
        "proof_validity": "real",
        "ironwood_anchor": hex::encode(req.anchor.to_bytes()),
        "ironwood_anchor_source": req.anchor_source.label(),
        "ironwood_anchor_tree_size": req.anchor_tree_size,
        "transparent": {
            "vin": transparent_vin,
            "vout": transparent_vout,
        },
        "sapling": {
            "spends": sapling_spends,
            "outputs": sapling_outputs,
        },
        "orchard": {
            "spends": req.orchard_spends.len(),
            "actions": orchard_actions,
            "change_outputs": usize::from(orchard_change_total > 0),
        },
        "ironwood": {
            "spends": req.ironwood_spends.len(),
            "actions": ironwood_actions,
            "outputs": 1 + usize::from(ironwood_change_total > 0),
            "change_outputs": usize::from(ironwood_change_total > 0),
        },
        "zip318_canonical": !req.orchard_spends.is_empty(),
        "total_input_zatoshis": total_input,
        "transparent_input_zatoshis": transparent_input_total,
        "sapling_input_zatoshis": sapling_input_total,
        "orchard_input_zatoshis": orchard_input_total,
        "orchard_change_zatoshis": orchard_change_total,
        "ironwood_input_zatoshis": ironwood_input_total,
        "ironwood_change_zatoshis": ironwood_change_total,
        "spends_ironwood": !req.ironwood_spends.is_empty(),
        "non_ironwood_output_zatoshis": output_total,
        "ironwood_output_zatoshis": ironwood_value,
        "rng": if req.rng_seed.is_some() { "deterministic" } else { "os" },
    }))
}

fn ironwood_recipient<P: Parameters>(
    params: &P,
    address: &str,
) -> Result<orchard::Address, BuildError> {
    match Address::decode(params, address) {
        Some(Address::Unified(ua)) => ua.orchard().copied().ok_or_else(|| {
            err(
                "missing_orchard_receiver",
                "the Ironwood recipient must be a Unified Address with an Orchard \
                     receiver; Ironwood reuses the Orchard receiver (ZIP 229)",
            )
        }),
        Some(Address::Sapling(_)) | Some(Address::Transparent(_)) | Some(Address::Tex(_)) => {
            Err(err(
                "unsupported_ironwood_recipient",
                "the Ironwood output must be paid to a Unified Address with an \
                     Orchard receiver; Sapling and transparent addresses cannot receive \
                     Ironwood funds",
            ))
        }
        None => Err(err(
            "invalid_output_address",
            "the Ironwood recipient address is invalid for the network",
        )),
    }
}

enum OutputDestination {
    Transparent(TransparentAddress),
    Sapling(sapling::PaymentAddress),
}

fn decode_output_address<P: Parameters>(
    params: &P,
    address: &str,
) -> Result<OutputDestination, BuildError> {
    match Address::decode(params, address) {
        Some(Address::Transparent(t)) => Ok(OutputDestination::Transparent(t)),
        Some(Address::Tex(hash)) => Ok(OutputDestination::Transparent(
            TransparentAddress::PublicKeyHash(hash),
        )),
        Some(Address::Sapling(pa)) => Ok(OutputDestination::Sapling(pa)),
        Some(Address::Unified(_)) => Err(err(
            "unsupported_shielded_output",
            "the outputs array accepts transparent and Sapling destinations; the \
                 Ironwood destination belongs in ironwood_output",
        )),
        None => Err(err(
            "invalid_output_address",
            "output address is invalid for the network",
        )),
    }
}

fn read_memo(output: &Value) -> Result<MemoBytes, BuildError> {
    match output.get("memo").and_then(Value::as_str) {
        None => Ok(MemoBytes::empty()),
        Some(memo_hex) => {
            let bytes = hex::decode(memo_hex.trim())
                .map_err(|_| err("invalid_memo", "memo is not valid hex"))?;
            if bytes.len() > 512 {
                return Err(err("invalid_memo", "memo must be at most 512 bytes"));
            }
            MemoBytes::from_bytes(&bytes).map_err(|_| err("invalid_memo", "memo is invalid"))
        }
    }
}

fn map_build_error<FE: std::fmt::Display>(
    error: zcash_primitives::transaction::builder::Error<FE>,
) -> BuildError {
    use zcash_primitives::transaction::builder::Error;
    match error {
        Error::InsufficientFunds(_) => {
            err("insufficient_funds", "inputs do not cover outputs plus fee")
        }
        Error::ChangeRequired(_) => err(
            "change_required",
            "inputs exceed outputs plus fee; supply a transparent change output or \
                 omit ironwood_output.value_zatoshis to send the remainder to Ironwood",
        ),
        Error::IronwoodBuilderNotAvailable => err(
            "ironwood_not_active",
            "the builder produced no Ironwood bundle for this target height",
        ),
        _ => err("build_failed", "could not build the Ironwood transaction"),
    }
}

#[cfg(test)]
pub(crate) fn test_regtest_unified_address(seed: &[u8]) -> String {
    use zcash_keys::keys::{ReceiverRequirement, UnifiedAddressRequest, UnifiedSpendingKey};
    let params = regtest_params(None);
    let usk =
        UnifiedSpendingKey::from_seed(&params, seed, zip32::AccountId::ZERO).expect("derive usk");
    let (ua, _) = usk
        .to_unified_full_viewing_key()
        .find_address(
            zip32::DiversifierIndex::from(0u32),
            UnifiedAddressRequest::unsafe_custom(
                ReceiverRequirement::Allow,
                ReceiverRequirement::Require,
                ReceiverRequirement::Allow,
            ),
        )
        .expect("derive unified address");
    ua.encode(&params)
}

#[cfg(test)]
pub(crate) fn test_regtest_transparent_address() -> String {
    use secp256k1::Secp256k1;
    let sk = SecretKey::from_slice(&[0x11u8; 32]).expect("test key");
    let pk = PublicKey::from_secret_key(&Secp256k1::new(), &sk);
    Address::Transparent(TransparentAddress::from_pubkey(&pk)).encode(&regtest_params(None))
}

#[cfg(test)]
pub(crate) fn test_sapling_note_fixture(
    seed: &[u8],
    value: u64,
    rseed: [u8; 32],
) -> (String, String, String, String) {
    use sapling::{CommitmentTree, Node};
    use zcash_primitives::merkle_tree::write_incremental_witness;
    let params = regtest_params(None);
    let usk = UnifiedSpendingKey::from_seed(&params, seed, AccountId::ZERO).expect("derive usk");
    let dfvk = usk.sapling().to_diversifiable_full_viewing_key();
    let to = dfvk.default_address().1;
    let note = to.create_note(NoteValue::from_raw(value), Rseed::AfterZip212(rseed));
    let mut tree = CommitmentTree::empty();
    tree.append(Node::from_cmu(&note.cmu()))
        .expect("append leaf");
    let witness = IncrementalWitness::from_tree(tree).expect("witness leaf");
    let anchor = witness.root().to_bytes();
    let mut witness_bytes = Vec::new();
    write_incremental_witness(&witness, &mut witness_bytes).expect("serialize witness");
    (
        Address::Sapling(to).encode(&params),
        hex::encode(rseed),
        hex::encode(witness_bytes),
        hex::encode(anchor),
    )
}

#[cfg(test)]
pub(crate) fn test_orchard_note_fixture(
    seed: &[u8],
    value: u64,
    nonce: u8,
    account_scope_internal: bool,
) -> (String, String, String, String, String) {
    use incrementalmerkletree::witness::IncrementalWitness;
    use orchard::keys::{FullViewingKey, Scope};
    use orchard::note::{ExtractedNoteCommitment, Note, NoteVersion, RandomSeed, Rho};
    use orchard::value::NoteValue as OrchardNoteValue;
    use zcash_address::unified::{Encoding, Receiver};
    use zcash_primitives::merkle_tree::write_incremental_witness;

    let params = regtest_params(None);
    let usk = UnifiedSpendingKey::from_seed(&params, seed, AccountId::ZERO).expect("derive usk");
    let fvk = FullViewingKey::from(usk.orchard());
    let scope = if account_scope_internal {
        Scope::Internal
    } else {
        Scope::External
    };
    let recipient = fvk.address_at(0u32, scope);

    let (rho_bytes, rho, rseed) = (0u8..=255)
        .find_map(|i| {
            let mut rho_bytes = [0u8; 32];
            rho_bytes[0] = nonce;
            rho_bytes[1] = i;
            let rho = Option::<Rho>::from(Rho::from_bytes(&rho_bytes))?;
            let rseed = Option::<RandomSeed>::from(RandomSeed::from_bytes([nonce ^ i; 32], &rho))?;
            Some((rho_bytes, rho, rseed))
        })
        .expect("a valid (rho, rseed) pair exists");
    let rseed_bytes = *rseed.as_bytes();

    let note = Option::<Note>::from(Note::from_parts(
        recipient,
        OrchardNoteValue::from_raw(value),
        rho,
        rseed,
        NoteVersion::V2,
    ))
    .expect("the fixture parts form a valid note");

    const EMPTY_TREE_HEX: &str = "000000";
    let mut tree = read_commitment_tree::<MerkleHashOrchard, _, IRONWOOD_TREE_DEPTH>(
        &hex::decode(EMPTY_TREE_HEX).unwrap()[..],
    )
    .expect("empty tree");
    let cmx = ExtractedNoteCommitment::from(note.commitment());
    tree.append(MerkleHashOrchard::from_cmx(&cmx))
        .expect("append leaf");
    let witness: IncrementalWitness<MerkleHashOrchard, IRONWOOD_TREE_DEPTH> =
        IncrementalWitness::from_tree(tree.clone()).expect("witness leaf");
    let mut witness_bytes = Vec::new();
    write_incremental_witness(&witness, &mut witness_bytes).expect("serialize witness");

    let recipient_ua = zcash_address::unified::Address::try_from_items(vec![Receiver::Orchard(
        recipient.to_raw_address_bytes(),
    )])
    .expect("a single Orchard receiver is a valid Unified Address")
    .encode(&NetworkType::Regtest);

    (
        recipient_ua,
        hex::encode(rseed_bytes),
        hex::encode(rho_bytes),
        hex::encode(witness_bytes),
        hex::encode(tree.root().to_bytes()),
    )
}

/// Test-only: an arbitrary Ironwood tree and its root, serialized like lightwalletd's
/// `GetTreeState.ironwoodTree`.
#[cfg(test)]
pub(crate) fn test_tree_fixture(leaves: u8) -> (String, String) {
    use zcash_primitives::merkle_tree::write_commitment_tree;
    const EMPTY_TREE_HEX: &str = "000000";
    let mut tree = read_commitment_tree::<MerkleHashOrchard, _, IRONWOOD_TREE_DEPTH>(
        &hex::decode(EMPTY_TREE_HEX).unwrap()[..],
    )
    .expect("empty tree");
    for i in 0..leaves {
        let mut repr = [0u8; 32];
        repr[0] = i.wrapping_add(1);
        let leaf = Option::<MerkleHashOrchard>::from(MerkleHashOrchard::from_bytes(&repr))
            .expect("canonical leaf");
        tree.append(leaf).expect("append leaf");
    }
    let mut bytes = Vec::new();
    write_commitment_tree(&tree, &mut bytes).expect("serialize tree");
    (
        hex::encode(bytes),
        hex::encode(orchard::Anchor::from(tree.root()).to_bytes()),
    )
}
