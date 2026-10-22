use super::parse_network_type_label;
use super::prover_shims::{BuildRng, NoProver};
use orchard::tree::MerkleHashOrchard;
use rand_chacha::rand_core::SeedableRng;
use rand_chacha::ChaCha20Rng;
use secp256k1::{PublicKey, SecretKey};
use serde_json::{json, Value};
use zcash_keys::address::Address;
use zcash_primitives::merkle_tree::read_commitment_tree;
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

const ORCHARD_BUILD_VERSION: u64 = 1;

const ORCHARD_TREE_DEPTH: u8 = orchard::NOTE_COMMITMENT_TREE_DEPTH as u8;

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
}

struct ParsedOrchardOutput {
    address: String,
    value: Option<u64>,
    memo: MemoBytes,
    ovk: Option<orchard::keys::OutgoingViewingKey>,
}

struct ParsedRequest {
    network: NetworkType,
    target_height: u32,
    fee: Option<u64>,
    anchor: orchard::Anchor,
    anchor_source: AnchorSource,
    anchor_tree_size: Option<u64>,
    rng_seed: Option<[u8; 32]>,
    expiry_height: Option<u32>,
    regtest_nu63_activation_height: Option<u32>,
    inputs: Vec<ParsedInput>,
    outputs: Vec<ParsedOutput>,
    orchard_output: ParsedOrchardOutput,
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
    let has_anchor = request.get("orchard_anchor").is_some();
    let has_tree = request.get("orchard_tree").is_some();
    match (has_anchor, has_tree) {
        (true, true) => Err(err(
            "conflicting_orchard_anchor",
            "supply either orchard_anchor or orchard_tree, not both",
        )),
        (false, false) => Err(err(
            "missing_orchard_anchor",
            "an Orchard anchor is required: supply orchard_anchor (a known \
                 root of the Orchard note commitment tree) or orchard_tree (the \
                 serialized tree from a lightwalletd GetTreeState). There is no \
                 default; an anchor that is not a known root builds and proves \
                 successfully but is rejected by consensus",
        )),
        (true, false) => {
            let bytes = read_hex_32(request, "orchard_anchor", "invalid_orchard_anchor")?;
            let anchor = Option::<orchard::Anchor>::from(orchard::Anchor::from_bytes(bytes))
                .ok_or_else(|| {
                    err(
                        "invalid_orchard_anchor",
                        "orchard_anchor is not a canonical Pallas base field element",
                    )
                })?;
            Ok((anchor, AnchorSource::Anchor, None))
        }
        (false, true) => {
            let tree_hex = request
                .get("orchard_tree")
                .and_then(Value::as_str)
                .ok_or_else(|| err("invalid_request", "orchard_tree must be a hex string"))?
                .trim();
            if tree_hex.is_empty() {
                return Ok((orchard::Anchor::empty_tree(), AnchorSource::Tree, Some(0)));
            }
            let bytes = hex::decode(tree_hex)
                .map_err(|_| err("invalid_orchard_tree", "orchard_tree is not valid hex"))?;
            let tree = read_commitment_tree::<MerkleHashOrchard, _, ORCHARD_TREE_DEPTH>(&bytes[..])
                .map_err(|_| {
                    err(
                        "invalid_orchard_tree",
                        "orchard_tree is not a serialized Orchard note commitment tree",
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
    if let Some(version) = request.get("orchard_build_version") {
        match version.as_u64() {
            Some(v) if v == ORCHARD_BUILD_VERSION => {}
            _ => {
                return Err(err(
                    "unsupported_orchard_build_version",
                    "orchard_build_version must be 1",
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

    let raw_inputs = request
        .get("inputs")
        .and_then(Value::as_array)
        .ok_or_else(|| err("invalid_request", "inputs must be an array"))?;
    if raw_inputs.is_empty() {
        return Err(err("invalid_request", "inputs must not be empty"));
    }
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
            outputs.push(ParsedOutput { address, value });
        }
    }

    let raw_orchard = request
        .get("orchard_output")
        .filter(|v| v.is_object())
        .ok_or_else(|| err("invalid_request", "orchard_output must be a JSON object"))?;
    let orchard_address = raw_orchard
        .get("address")
        .and_then(Value::as_str)
        .ok_or_else(|| err("invalid_request", "orchard_output address must be a string"))?
        .to_string();
    let orchard_value = match raw_orchard.get("value_zatoshis") {
        None => None,
        Some(_) => Some(read_zatoshis(raw_orchard, "value_zatoshis")?),
    };
    let memo = match raw_orchard.get("memo") {
        None => MemoBytes::empty(),
        Some(v) => {
            let memo_hex = v
                .as_str()
                .ok_or_else(|| err("invalid_memo", "orchard_output memo must be a hex string"))?;
            let bytes = hex::decode(memo_hex.trim())
                .map_err(|_| err("invalid_memo", "orchard_output memo is not valid hex"))?;
            if bytes.len() > 512 {
                return Err(err("invalid_memo", "memo must be at most 512 bytes"));
            }
            MemoBytes::from_bytes(&bytes).map_err(|_| err("invalid_memo", "memo is invalid"))?
        }
    };
    let ovk = match raw_orchard.get("outgoing_viewing_key") {
        None => None,
        Some(_) => Some(orchard::keys::OutgoingViewingKey::from(read_hex_32(
            raw_orchard,
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
        expiry_height,
        regtest_nu63_activation_height,
        inputs,
        outputs,
        orchard_output: ParsedOrchardOutput {
            address: orchard_address,
            value: orchard_value,
            memo,
            ovk,
        },
    })
}

pub fn build_orchard_transaction_json(request: &Value) -> Result<Value, BuildError> {
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
    let height = BlockHeight::from_u32(req.target_height);

    // ZIP 258: no value may enter the Orchard pool once NU6.3 is active.
    if params.is_nu_active(NetworkUpgrade::Nu6_3, height) {
        return Err(err(
            "orchard_pool_closed",
            "NU6.3 is active at target_height: no value may enter the Orchard \
                 pool after activation (ZIP 258 requires valueBalanceOrchard >= 0) \
                 and an Orchard V3 bundle disables cross-address transfers, so no \
                 Orchard output can be created. Shield into Ironwood instead",
        ));
    }
    if !params.is_nu_active(NetworkUpgrade::Nu6_2, height) {
        return Err(err(
            "orchard_circuit_pre_nu6_2",
            "target_height is before NU6.2 on this network. The Orchard \
                 protocol revision below NU6.2 uses the historical unsound circuit, \
                 which upstream reconstructs for verification only and does not \
                 prove against; build at a height at or after NU6.2 activation",
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

type PopulatedBuilder<P> = (Builder<P, ()>, TransparentSigningSet);

fn populate<P: Parameters + Copy>(
    params: P,
    req: &ParsedRequest,
    orchard_value: Zatoshis,
) -> Result<PopulatedBuilder<P>, BuildError> {
    // Padded: `UNPADDED` is only for a ZIP 318 migration, whose shape is already public.
    let build_config = BuildConfig::Standard {
        sapling_anchor: None,
        orchard_anchor: Some(req.anchor),
        ironwood_anchor: None,
        orchard_padding: BundlePadding::DEFAULT,
        ironwood_padding: BundlePadding::DEFAULT,
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
        let to = transparent_output_address(&params, &output.address)?;
        builder
            .add_transparent_output(&to, zatoshis(output.value, "value_zatoshis")?)
            .map_err(|_| err("invalid_output", "could not add transparent output"))?;
    }

    let recipient = orchard_recipient(&params, &req.orchard_output.address)?;
    builder
        .add_orchard_output::<std::convert::Infallible>(
            req.orchard_output.ovk.clone(),
            recipient,
            orchard_value,
            req.orchard_output.memo.clone(),
        )
        .map_err(map_add_output_error)?;

    Ok((builder, signing_set))
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
    let total_input: u64 = req
        .inputs
        .iter()
        .try_fold(0u64, |acc, i| acc.checked_add(i.value))
        .ok_or_else(|| err("invalid_request", "total input value overflows"))?;
    let output_total: u64 = req
        .outputs
        .iter()
        .try_fold(0u64, |acc, o| acc.checked_add(o.value))
        .ok_or_else(|| err("invalid_request", "total output value overflows"))?;

    let (probe, _) = populate(params, req, Zatoshis::ZERO)?;
    let fee = probe
        .get_fee(fee_rule)
        .map_err(|_| err("fee_failed", "could not compute the transaction fee"))?;
    let fee_zatoshis = u64::from(fee);
    drop(probe);

    let orchard_value = match req.orchard_output.value {
        Some(v) => v,
        None => total_input
            .checked_sub(output_total)
            .and_then(|v| v.checked_sub(fee_zatoshis))
            .ok_or_else(|| {
                err(
                    "insufficient_funds",
                    "inputs do not cover the transparent outputs plus fee",
                )
            })?,
    };
    if orchard_value == 0 {
        return Err(err(
            "invalid_request",
            "the Orchard output value must be positive",
        ));
    }

    let (builder, signing_set) = populate(params, req, zatoshis(orchard_value, "value_zatoshis")?)?;
    let rng = match req.rng_seed {
        Some(seed) => BuildRng::Deterministic(Box::new(ChaCha20Rng::from_seed(seed))),
        None => BuildRng::os(),
    };

    let result = builder
        .build(&signing_set, &[], &[], rng, &NoProver, &NoProver, fee_rule)
        .map_err(map_build_error)?;
    let tx = result.transaction();

    let mut raw = Vec::new();
    tx.write(&mut raw).map_err(|_| {
        err(
            "serialize_failed",
            "could not serialize the built transaction",
        )
    })?;

    let orchard_actions = tx.orchard_bundle().map_or(0, |b| b.actions().len());
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
        "orchard_anchor": hex::encode(req.anchor.to_bytes()),
        "orchard_anchor_source": req.anchor_source.label(),
        "orchard_anchor_tree_size": req.anchor_tree_size,
        "transparent": {
            "vin": transparent_vin,
            "vout": transparent_vout,
        },
        "orchard": {
            "actions": orchard_actions,
            "outputs": 1,
        },
        "total_input_zatoshis": total_input,
        "non_orchard_output_zatoshis": output_total,
        "orchard_output_zatoshis": orchard_value,
        "rng": if req.rng_seed.is_some() { "deterministic" } else { "os" },
    }))
}

fn orchard_recipient<P: Parameters>(
    params: &P,
    address: &str,
) -> Result<orchard::Address, BuildError> {
    match Address::decode(params, address) {
        Some(Address::Unified(ua)) => ua.orchard().copied().ok_or_else(|| {
            err(
                "missing_orchard_receiver",
                "the Orchard recipient must be a Unified Address with an Orchard \
                     receiver",
            )
        }),
        Some(Address::Sapling(_)) | Some(Address::Transparent(_)) | Some(Address::Tex(_)) => {
            Err(err(
                "unsupported_orchard_recipient",
                "the Orchard output must be paid to a Unified Address with an \
                     Orchard receiver; Sapling and transparent addresses cannot \
                     receive Orchard funds",
            ))
        }
        None => Err(err(
            "invalid_output_address",
            "the Orchard recipient address is invalid for the network",
        )),
    }
}

fn transparent_output_address<P: Parameters>(
    params: &P,
    address: &str,
) -> Result<TransparentAddress, BuildError> {
    match Address::decode(params, address) {
        Some(Address::Transparent(t)) => Ok(t),
        Some(Address::Tex(hash)) => Ok(TransparentAddress::PublicKeyHash(hash)),
        Some(Address::Sapling(_)) | Some(Address::Unified(_)) => Err(err(
            "unsupported_shielded_output",
            "the outputs array accepts transparent destinations only; the \
                 Orchard destination belongs in orchard_output",
        )),
        None => Err(err(
            "invalid_output_address",
            "output address is invalid for the network",
        )),
    }
}

/// `CrossAddressDisabled` is the ZIP 258 one-way exit, so it maps to `orchard_pool_closed`.
fn map_add_output_error(
    error: zcash_primitives::transaction::builder::Error<std::convert::Infallible>,
) -> BuildError {
    use orchard::builder::OutputError;
    use zcash_primitives::transaction::builder::Error;
    match error {
        Error::OrchardBuilderNotAvailable => err(
            "orchard_builder_unavailable",
            "no Orchard bundle is configured for this transaction",
        ),
        Error::OrchardRecipient(OutputError::CrossAddressDisabled) => err(
            "orchard_pool_closed",
            "this consensus branch disables cross-address transfers in the \
                 Orchard pool, so no Orchard output can be created",
        ),
        _ => err("invalid_output", "could not add the Orchard output"),
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
            "inputs exceed outputs plus fee; supply a transparent change output \
                 or omit orchard_output.value_zatoshis to shield the remainder",
        ),
        _ => err("build_failed", "could not build the Orchard transaction"),
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
    let sk = SecretKey::from_secret_bytes([0x11u8; 32]).expect("test key");
    let pk = PublicKey::from_secret_key(&sk);
    Address::Transparent(TransparentAddress::from_pubkey(&pk)).encode(&regtest_params(None))
}

/// Test-only: an arbitrary Orchard tree and its root, serialized like lightwalletd's
/// `GetTreeState.orchardTree`.
#[cfg(test)]
pub(crate) fn test_tree_fixture(leaves: u8) -> (String, String) {
    use zcash_primitives::merkle_tree::write_commitment_tree;
    const EMPTY_TREE_HEX: &str = "000000";
    let mut tree = read_commitment_tree::<MerkleHashOrchard, _, ORCHARD_TREE_DEPTH>(
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
