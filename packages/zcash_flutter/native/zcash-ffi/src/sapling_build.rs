use super::parse_network_type_label;
use super::prover_shims::BuildRng;
use rand_chacha::rand_core::SeedableRng;
use rand_chacha::ChaCha20Rng;
use sapling::prover::mock::{MockOutputProver, MockSpendProver};
use sapling::value::NoteValue;
use sapling::{Anchor, CommitmentTree, IncrementalWitness, MerklePath, Node, Note, Rseed};
use secp256k1::{PublicKey, SecretKey};
use serde_json::{json, Value};
use std::convert::Infallible;
use std::path::Path;
use zcash_keys::address::Address;
use zcash_keys::keys::UnifiedSpendingKey;
use zcash_primitives::merkle_tree::read_incremental_witness;
use zcash_primitives::transaction::builder::{BuildConfig, Builder, BundlePadding};
use zcash_primitives::transaction::fees::fixed::FeeRule as FixedFeeRule;
use zcash_primitives::transaction::fees::zip317::FeeRule as Zip317FeeRule;
use zcash_protocol::consensus::{BlockHeight, Network, NetworkType, Parameters};
use zcash_protocol::local_consensus::LocalNetwork;
use zcash_protocol::memo::MemoBytes;
use zcash_protocol::value::{Zatoshis, MAX_MONEY};
use zcash_transparent::address::TransparentAddress;
use zcash_transparent::builder::TransparentSigningSet;
use zcash_transparent::bundle::{OutPoint, TxOut};
use zip32::AccountId;

const SAPLING_BUILD_VERSION: u64 = 1;

/// Fixed note randomness for placeholder spend notes.
const NOTE_RSEED: [u8; 32] = [11u8; 32];

type BuildError = (String, String);

fn err(category: &str, message: &str) -> BuildError {
    (category.to_string(), message.to_string())
}

struct ProvingConfig {
    real: Option<(String, String)>,
}

fn parse_proving_config(request: &Value) -> Result<ProvingConfig, BuildError> {
    let spend = request.get("spend_params_path").and_then(Value::as_str);
    let output = request.get("output_params_path").and_then(Value::as_str);
    let real = match (spend, output) {
        (Some(s), Some(o)) if !s.is_empty() && !o.is_empty() => {
            Some((s.to_string(), o.to_string()))
        }
        (None, None) => None,
        _ => {
            return Err(err(
                "invalid_request",
                "spend_params_path and output_params_path must be provided \
                     together as non-empty strings",
            ))
        }
    };
    Ok(ProvingConfig { real })
}

fn load_real_params(
    spend_path: &str,
    output_path: &str,
) -> Result<zcash_proofs::ZcashParameters, BuildError> {
    let spend = Path::new(spend_path).to_path_buf();
    let output = Path::new(output_path).to_path_buf();
    if !spend.is_file() {
        return Err(err(
            "params_not_found",
            "the Sapling spend parameter file was not found",
        ));
    }
    if !output.is_file() {
        return Err(err(
            "params_not_found",
            "the Sapling output parameter file was not found",
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

fn regtest_params(nu6_3: Option<u32>) -> LocalNetwork {
    super::staged_regtest::params(nu6_3)
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

fn read_hex32(value: &Value, field: &str) -> Result<[u8; 32], BuildError> {
    let s = value
        .get(field)
        .and_then(Value::as_str)
        .ok_or_else(|| err("invalid_request", &format!("{field} must be a hex string")))?;
    let bytes = hex::decode(s.trim())
        .map_err(|_| err("invalid_request", &format!("{field} is not valid hex")))?;
    if bytes.len() != 32 {
        return Err(err("invalid_request", &format!("{field} must be 32 bytes")));
    }
    let mut out = [0u8; 32];
    out.copy_from_slice(&bytes);
    Ok(out)
}

struct ParsedInput {
    outpoint_hash: [u8; 32],
    vout: u32,
    value: u64,
    secret_key: SecretKey,
}

fn read_hex32_as(value: &Value, field: &str, category: &str) -> Result<[u8; 32], BuildError> {
    let s = value
        .get(field)
        .and_then(Value::as_str)
        .ok_or_else(|| err(category, &format!("{field} must be a hex string")))?;
    let bytes =
        hex::decode(s.trim()).map_err(|_| err(category, &format!("{field} is not valid hex")))?;
    if bytes.len() != 32 {
        return Err(err(category, &format!("{field} must be 32 bytes")));
    }
    let mut out = [0u8; 32];
    out.copy_from_slice(&bytes);
    Ok(out)
}

fn parse_inputs(request: &Value) -> Result<Vec<ParsedInput>, BuildError> {
    let raw = match request.get("inputs") {
        None => return Ok(Vec::new()),
        Some(v) => v
            .as_array()
            .ok_or_else(|| err("invalid_request", "inputs must be an array"))?,
    };
    let mut inputs = Vec::with_capacity(raw.len());
    for input in raw {
        if !input.is_object() {
            return Err(err("invalid_request", "each input must be a JSON object"));
        }
        let txid = read_hex32_as(input, "txid", "invalid_txid")?;
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
        let sk_bytes = read_hex32_as(input, "secret_key", "invalid_secret_key")?;
        let secret_key = SecretKey::from_secret_bytes(sk_bytes).map_err(|_| {
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
    Ok(inputs)
}

struct ParsedOutput {
    address: String,
    value: Option<u64>,
    memo: MemoBytes,
}

type PopulatedBuilder<P> = (Builder<P, ()>, TransparentSigningSet);

#[allow(clippy::too_many_arguments)]
fn populate<P: Parameters + Copy>(
    params: P,
    target_height: u32,
    anchor: Anchor,
    fvk: &sapling::keys::FullViewingKey,
    ovk: sapling::keys::OutgoingViewingKey,
    prepared: &[(Note, MerklePath)],
    inputs: &[ParsedInput],
    outputs: &[ParsedOutput],
    remainder_value: u64,
) -> Result<PopulatedBuilder<P>, BuildError> {
    let build_config = BuildConfig::Standard {
        sapling_anchor: Some(anchor),
        orchard_anchor: None,
        ironwood_anchor: None,
        orchard_padding: BundlePadding::DEFAULT,
        ironwood_padding: BundlePadding::DEFAULT,
    };
    let mut builder = Builder::new(params, BlockHeight::from_u32(target_height), build_config);

    for (note, path) in prepared {
        builder
            .add_sapling_spend::<Infallible>(fvk.clone(), note.clone(), path.clone())
            .map_err(map_add_spend_error)?;
    }

    let mut signing_set = TransparentSigningSet::new();
    for input in inputs {
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

    for output in outputs {
        let value = zatoshis(output.value.unwrap_or(remainder_value), "value_zatoshis")?;
        match Address::decode(&params, &output.address) {
            Some(Address::Transparent(t)) => {
                builder
                    .add_transparent_output(&t, value)
                    .map_err(|_| err("invalid_output", "could not add transparent output"))?;
            }
            Some(Address::Tex(hash)) => {
                let t = zcash_transparent::address::TransparentAddress::PublicKeyHash(hash);
                builder
                    .add_transparent_output(&t, value)
                    .map_err(|_| err("invalid_output", "could not add transparent output"))?;
            }
            Some(Address::Sapling(pa)) => {
                builder
                    .add_sapling_output::<Infallible>(Some(ovk), *pa, value, output.memo.clone())
                    .map_err(|_| err("invalid_output", "could not add Sapling output"))?;
            }
            Some(Address::Unified(_)) => {
                return Err(err(
                    "unsupported_shielded_output",
                    "Sapling build supports transparent and Sapling outputs only; \
                         Orchard and Unified outputs are not supported",
                ))
            }
            None => {
                return Err(err(
                    "invalid_output_address",
                    "output address is invalid for the network",
                ))
            }
        }
    }
    Ok((builder, signing_set))
}

fn entry_has_real_fields(entry: &Value) -> bool {
    ["rseed", "recipient", "witness", "anchor"]
        .iter()
        .any(|k| entry.get(k).is_some())
}

pub fn build_sapling_transaction_json(request: &Value) -> Result<Value, BuildError> {
    if !request.is_object() {
        return Err(err("invalid_request", "request must be a JSON object"));
    }
    if let Some(version) = request.get("sapling_build_version") {
        match version.as_u64() {
            Some(v) if v == SAPLING_BUILD_VERSION => {}
            _ => {
                return Err(err(
                    "unsupported_sapling_build_version",
                    "sapling_build_version must be 1",
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

    // None: the builder quotes the ZIP 317 fee.
    let fee = match request.get("fee_zatoshis") {
        None => None,
        Some(_) => Some(read_zatoshis(request, "fee_zatoshis")?),
    };
    let quote_only = match request.get("quote_only") {
        None => false,
        Some(v) => v
            .as_bool()
            .ok_or_else(|| err("invalid_request", "quote_only must be a boolean"))?,
    };
    let rng_seed = match request.get("rng_seed") {
        None => None,
        Some(_) => Some(read_hex32_as(request, "rng_seed", "invalid_rng_seed")?),
    };

    let seed_hex = request
        .get("seed")
        .and_then(Value::as_str)
        .ok_or_else(|| err("invalid_request", "seed must be a hex string"))?;
    let seed =
        hex::decode(seed_hex.trim()).map_err(|_| err("invalid_seed", "seed is not valid hex"))?;
    if seed.len() < 32 {
        return Err(err("invalid_seed", "seed must be at least 32 bytes"));
    }

    let account_index = request
        .get("account")
        .map(|v| v.as_u64().filter(|n| *n <= u64::from(u32::MAX)).ok_or(()))
        .unwrap_or(Ok(0))
        .map_err(|_| err("invalid_request", "account must be a u32"))?
        as u32;
    let account = AccountId::try_from(account_index)
        .map_err(|_| err("invalid_request", "account is out of range"))?;

    let empty = Vec::new();
    let spend_notes = match request.get("spend_notes") {
        None => &empty,
        Some(v) => v
            .as_array()
            .ok_or_else(|| err("invalid_request", "spend_notes must be an array"))?,
    };
    let inputs = parse_inputs(request)?;
    if spend_notes.is_empty() && inputs.is_empty() {
        return Err(err(
            "invalid_request",
            "a build must spend something: supply spend_notes, inputs, or both",
        ));
    }
    let outputs = request
        .get("outputs")
        .and_then(Value::as_array)
        .ok_or_else(|| err("invalid_request", "outputs must be an array"))?;
    if outputs.is_empty() {
        return Err(err("invalid_request", "outputs must not be empty"));
    }

    let proving = parse_proving_config(request)?;
    let nu63_activation = super::staged_regtest::read_activation_height(request, network)?;

    match network {
        NetworkType::Main => build_generic(
            Network::MainNetwork,
            network,
            &seed,
            account,
            target_height,
            fee,
            quote_only,
            rng_seed,
            spend_notes,
            &inputs,
            outputs,
            &proving,
        ),
        NetworkType::Test => build_generic(
            Network::TestNetwork,
            network,
            &seed,
            account,
            target_height,
            fee,
            quote_only,
            rng_seed,
            spend_notes,
            &inputs,
            outputs,
            &proving,
        ),
        NetworkType::Regtest => build_generic(
            regtest_params(nu63_activation),
            network,
            &seed,
            account,
            target_height,
            fee,
            quote_only,
            rng_seed,
            spend_notes,
            &inputs,
            outputs,
            &proving,
        ),
    }
}

#[allow(clippy::too_many_arguments)]
fn build_generic<P: Parameters + Copy>(
    params: P,
    network: NetworkType,
    seed: &[u8],
    account: AccountId,
    target_height: u32,
    fee: Option<u64>,
    quote_only: bool,
    rng_seed: Option<[u8; 32]>,
    spend_notes: &[Value],
    inputs: &[ParsedInput],
    outputs: &[Value],
    proving: &ProvingConfig,
) -> Result<Value, BuildError> {
    let usk = UnifiedSpendingKey::from_seed(&params, seed, account).map_err(|_| {
        err(
            "derivation_error",
            "could not derive a spending key from the seed",
        )
    })?;
    let extsk = usk.sapling().clone();
    let dfvk = extsk.to_diversifiable_full_viewing_key();
    let fvk = dfvk.fvk().clone();
    let ovk = dfvk.fvk().ovk;
    let to = dfvk.default_address().1;

    let use_real_notes = !spend_notes.is_empty() && entry_has_real_fields(&spend_notes[0]);
    let mut prepared: Vec<(Note, MerklePath)> = Vec::with_capacity(spend_notes.len());
    let mut total_spent: u64 = 0;
    let anchor: Anchor;

    if spend_notes.is_empty() {
        anchor = Anchor::empty_tree();
    } else if use_real_notes {
        let mut anchor_bytes: Option<[u8; 32]> = None;
        for entry in spend_notes {
            if !entry.is_object() {
                return Err(err(
                    "invalid_request",
                    "each spend note must be a JSON object",
                ));
            }
            if !entry_has_real_fields(entry) {
                return Err(err(
                    "invalid_request",
                    "all spend notes must be the same kind (all real or all synthesized)",
                ));
            }
            let value = read_zatoshis(entry, "value_zatoshis")?;
            if value == 0 {
                return Err(err(
                    "invalid_request",
                    "spend note value_zatoshis must be positive",
                ));
            }

            let recipient = entry
                .get("recipient")
                .and_then(Value::as_str)
                .ok_or_else(|| err("invalid_request", "spend note recipient must be a string"))?;
            let pa = match Address::decode(&params, recipient) {
                Some(Address::Sapling(pa)) => pa,
                _ => {
                    return Err(err(
                        "invalid_request",
                        "spend note recipient must be a Sapling address for the network",
                    ))
                }
            };
            if fvk.vk.to_payment_address(*pa.diversifier()) != Some(*pa) {
                return Err(err(
                    "note_not_spendable",
                    "spend note recipient is not spendable by the account viewing key",
                ));
            }

            let rseed = Rseed::AfterZip212(read_hex32(entry, "rseed")?);
            let note = pa.create_note(NoteValue::from_raw(value), rseed);

            let witness_hex = entry
                .get("witness")
                .and_then(Value::as_str)
                .ok_or_else(|| err("invalid_request", "spend note witness must be a hex string"))?;
            let witness_bytes = hex::decode(witness_hex.trim())
                .map_err(|_| err("invalid_request", "spend note witness is not valid hex"))?;
            let witness: IncrementalWitness = read_incremental_witness(&witness_bytes[..])
                .map_err(|_| err("invalid_request", "spend note witness is malformed"))?;

            let this_anchor = read_hex32(entry, "anchor")?;
            if witness.root().to_bytes() != this_anchor {
                return Err(err(
                    "witness_anchor_mismatch",
                    "spend note witness is not rooted at the supplied anchor",
                ));
            }
            match anchor_bytes {
                None => anchor_bytes = Some(this_anchor),
                Some(existing) if existing != this_anchor => {
                    return Err(err(
                        "anchor_mismatch",
                        "all spend notes in one build must share the same anchor",
                    ))
                }
                Some(_) => {}
            }

            let path = witness
                .path()
                .ok_or_else(|| err("invalid_request", "spend note witness has no Merkle path"))?;
            prepared.push((note, path));
            total_spent = total_spent
                .checked_add(value)
                .ok_or_else(|| err("invalid_request", "total spent value overflows"))?;
        }
        let bytes = anchor_bytes.expect("spend_notes is non-empty");
        anchor = Option::from(Anchor::from_bytes(bytes))
            .ok_or_else(|| err("invalid_request", "anchor is not a valid Sapling tree root"))?;
    } else {
        let mut tree = CommitmentTree::empty();
        let mut witnesses: Vec<IncrementalWitness> = Vec::with_capacity(spend_notes.len());
        let mut notes = Vec::with_capacity(spend_notes.len());
        for entry in spend_notes {
            if !entry.is_object() {
                return Err(err(
                    "invalid_request",
                    "each spend note must be a JSON object",
                ));
            }
            if entry_has_real_fields(entry) {
                return Err(err(
                    "invalid_request",
                    "all spend notes must be the same kind (all real or all synthesized)",
                ));
            }
            let value = read_zatoshis(entry, "value_zatoshis")?;
            if value == 0 {
                return Err(err(
                    "invalid_request",
                    "spend note value_zatoshis must be positive",
                ));
            }
            let note = to.create_note(NoteValue::from_raw(value), Rseed::AfterZip212(NOTE_RSEED));
            let node = Node::from_cmu(&note.cmu());
            tree.append(node)
                .map_err(|_| err("build_failed", "could not extend the note-commitment tree"))?;
            for witness in witnesses.iter_mut() {
                witness
                    .append(node)
                    .map_err(|_| err("build_failed", "could not update a note witness"))?;
            }
            let witness = IncrementalWitness::from_tree(tree.clone())
                .ok_or_else(|| err("build_failed", "could not witness a spend note"))?;
            witnesses.push(witness);
            notes.push(note);
            total_spent = total_spent
                .checked_add(value)
                .ok_or_else(|| err("invalid_request", "total spent value overflows"))?;
        }
        anchor = witnesses[0].root().into();
        for (note, witness) in notes.into_iter().zip(witnesses.into_iter()) {
            let path = witness
                .path()
                .ok_or_else(|| err("build_failed", "could not compute a Merkle path"))?;
            prepared.push((note, path));
        }
    }

    let mut parsed_outputs: Vec<ParsedOutput> = Vec::with_capacity(outputs.len());
    let mut remainder_outputs = 0usize;
    let mut stated_output_total: u64 = 0;
    for output in outputs {
        if !output.is_object() {
            return Err(err("invalid_request", "each output must be a JSON object"));
        }
        let address = output
            .get("address")
            .and_then(Value::as_str)
            .ok_or_else(|| err("invalid_request", "output address must be a string"))?
            .to_string();
        let value = match output.get("value_zatoshis") {
            None => {
                remainder_outputs += 1;
                None
            }
            Some(_) => {
                let v = read_zatoshis(output, "value_zatoshis")?;
                if v == 0 {
                    return Err(err(
                        "invalid_request",
                        "output value_zatoshis must be positive",
                    ));
                }
                stated_output_total = stated_output_total
                    .checked_add(v)
                    .ok_or_else(|| err("invalid_request", "total output value overflows"))?;
                Some(v)
            }
        };
        parsed_outputs.push(ParsedOutput {
            address,
            value,
            memo: read_memo(output)?,
        });
    }
    if remainder_outputs > 1 {
        return Err(err(
            "invalid_request",
            "at most one output may omit value_zatoshis; two remainders have \
                 no single answer",
        ));
    }

    let mut total_transparent_input: u64 = 0;
    for input in inputs {
        total_transparent_input = total_transparent_input
            .checked_add(input.value)
            .ok_or_else(|| err("invalid_request", "total input value overflows"))?;
    }
    let total_input = total_transparent_input
        .checked_add(total_spent)
        .ok_or_else(|| err("invalid_request", "total input value overflows"))?;

    let (probe, _) = populate(
        params,
        target_height,
        anchor,
        &fvk,
        ovk,
        &prepared,
        inputs,
        &parsed_outputs,
        0,
    )?;
    let fee_zatoshis = match fee {
        Some(stated) => stated,
        None => u64::from(
            probe
                .get_fee(&Zip317FeeRule::standard())
                .map_err(|_| err("fee_failed", "could not compute the transaction fee"))?,
        ),
    };
    drop(probe);

    let max_output = total_input
        .checked_sub(stated_output_total)
        .and_then(|v| v.checked_sub(fee_zatoshis));

    if quote_only {
        return Ok(json!({
            "quote_only": true,
            "network": super::network_type_label(network),
            "fee_zatoshis": fee_zatoshis,
            "fee_rule": if fee.is_some() { "fixed" } else { "zip317" },
            "consensus_branch_id": super::branch_id_label(
                zcash_protocol::consensus::BranchId::for_height(
                    &params,
                    BlockHeight::from_u32(target_height),
                ),
            ),
            "total_input_zatoshis": total_input,
            "stated_output_zatoshis": stated_output_total,
            "max_output_zatoshis": max_output,
            "sapling_spends": prepared.len(),
            "transparent_inputs": inputs.len(),
            "outputs": parsed_outputs.len(),
        }));
    }

    let remainder_value = if remainder_outputs == 0 {
        0
    } else {
        let value = max_output.ok_or_else(|| {
            err(
                "insufficient_funds",
                "inputs do not cover the stated outputs plus fee",
            )
        })?;
        if value == 0 {
            return Err(err(
                "insufficient_funds",
                "nothing is left for the remainder output after the fee",
            ));
        }
        value
    };
    let total_output = stated_output_total
        .checked_add(remainder_value)
        .ok_or_else(|| err("invalid_request", "total output value overflows"))?;

    let (builder, signing_set) = populate(
        params,
        target_height,
        anchor,
        &fvk,
        ovk,
        &prepared,
        inputs,
        &parsed_outputs,
        remainder_value,
    )?;

    // Pin the quote as a fixed fee so the build matches it.
    let fee_rule = FixedFeeRule::non_standard(zatoshis(fee_zatoshis, "fee_zatoshis")?);
    let rng = match rng_seed {
        Some(seed) => BuildRng::Deterministic(Box::new(ChaCha20Rng::from_seed(seed))),
        None => BuildRng::os(),
    };

    let (result, proof_validity) = match &proving.real {
        Some((spend_path, output_path)) => {
            let zp = load_real_params(spend_path, output_path)?;
            let result = builder
                .build(
                    &signing_set,
                    &[extsk],
                    &[],
                    rng,
                    &zp.spend_params,
                    &zp.output_params,
                    &fee_rule,
                )
                .map_err(map_build_error)?;
            (result, "real")
        }
        None => {
            let result = builder
                .build(
                    &signing_set,
                    &[extsk],
                    &[],
                    rng,
                    &MockSpendProver,
                    &MockOutputProver,
                    &fee_rule,
                )
                .map_err(map_build_error)?;
            (result, "placeholder")
        }
    };
    let tx = result.transaction();

    let mut raw = Vec::new();
    tx.write(&mut raw).map_err(|_| {
        err(
            "serialize_failed",
            "could not serialize the built transaction",
        )
    })?;

    let sapling_spends = tx
        .sapling_bundle()
        .map(|b| b.shielded_spends().len())
        .unwrap_or(0);
    let sapling_outputs = tx
        .sapling_bundle()
        .map(|b| b.shielded_outputs().len())
        .unwrap_or(0);
    let transparent_vin = tx.transparent_bundle().map(|b| b.vin.len()).unwrap_or(0);
    let transparent_vout = tx.transparent_bundle().map(|b| b.vout.len()).unwrap_or(0);

    Ok(json!({
        "network": super::network_type_label(network),
        "transaction": hex::encode(&raw),
        "txid": tx.txid().to_string(),
        "version": super::tx_version_label(tx.version()),
        "expiry_height": u32::from(tx.expiry_height()),
        "fee_zatoshis": fee_zatoshis,
        "fee_rule": if fee.is_some() { "fixed" } else { "zip317" },
        "rng": if rng_seed.is_some() { "deterministic" } else { "os" },
        "consensus_branch_id": super::branch_id_label(tx.consensus_branch_id()),
        "proof_validity": proof_validity,
        "transparent": {
            "vin": transparent_vin,
            "vout": transparent_vout,
            "input_zatoshis": total_transparent_input,
        },
        "sapling": {
            "spends": sapling_spends,
            "outputs": sapling_outputs,
        },
        "total_spent_zatoshis": total_spent,
        "total_output_zatoshis": total_output,
    }))
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

fn map_add_spend_error(
    error: zcash_primitives::transaction::builder::Error<Infallible>,
) -> BuildError {
    use zcash_primitives::transaction::builder::Error;
    match error {
        Error::SaplingBuild(sapling::builder::Error::AnchorMismatch) => err(
            "witness_anchor_mismatch",
            "spend note witness does not witness the supplied note against the anchor",
        ),
        _ => err("invalid_input", "could not add a Sapling spend"),
    }
}

fn map_build_error<FE: std::fmt::Display>(
    error: zcash_primitives::transaction::builder::Error<FE>,
) -> BuildError {
    use zcash_primitives::transaction::builder::Error;
    match error {
        Error::InsufficientFunds(_) => err(
            "insufficient_funds",
            "spent notes do not cover outputs plus fee",
        ),
        Error::ChangeRequired(_) => err(
            "change_required",
            "spent notes exceed outputs plus fee; this build requires an exact balance",
        ),
        _ => err("build_failed", "could not build the Sapling transaction"),
    }
}

/// Test-only: a real note to the account's default Sapling address, with a single-leaf witness.
#[cfg(test)]
pub(crate) fn real_note_fixture(
    seed: &[u8],
    account_index: u32,
    value: u64,
    rseed: [u8; 32],
) -> (String, String, String, String) {
    use zcash_primitives::merkle_tree::write_incremental_witness;
    let params = regtest_params(None);
    let account = AccountId::try_from(account_index).expect("account index");
    let usk = UnifiedSpendingKey::from_seed(&params, seed, account).expect("derive usk");
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
    let recipient = Address::Sapling(Box::new(to)).encode(&params);
    (
        recipient,
        hex::encode(rseed),
        hex::encode(witness_bytes),
        hex::encode(anchor),
    )
}
