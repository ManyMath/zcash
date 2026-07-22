use super::parse_network_type_label;
use super::prover_shims::{NoProver, ZeroRng};
use secp256k1::{PublicKey, SecretKey};
use serde_json::{json, Value};
use zcash_keys::address::Address;
use zcash_primitives::transaction::builder::{BuildConfig, Builder, BundlePadding};
use zcash_primitives::transaction::fees::fixed::FeeRule as FixedFeeRule;
use zcash_protocol::consensus::{BlockHeight, Network, NetworkType, Parameters};
use zcash_protocol::local_consensus::LocalNetwork;
use zcash_protocol::value::{Zatoshis, MAX_MONEY};
use zcash_transparent::address::TransparentAddress;
use zcash_transparent::builder::TransparentSigningSet;
use zcash_transparent::bundle::{OutPoint, TxOut};

const TRANSPARENT_BUILD_VERSION: u64 = 1;

type BuildError = (String, String);

fn err(category: &str, message: &str) -> BuildError {
    (category.to_string(), message.to_string())
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

pub fn build_transparent_transaction_json(request: &Value) -> Result<Value, BuildError> {
    if !request.is_object() {
        return Err(err("invalid_request", "request must be a JSON object"));
    }
    if let Some(version) = request.get("transparent_build_version") {
        match version.as_u64() {
            Some(v) if v == TRANSPARENT_BUILD_VERSION => {}
            _ => {
                return Err(err(
                    "unsupported_transparent_build_version",
                    "transparent_build_version must be 1",
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

    let fee = read_zatoshis(request, "fee_zatoshis")?;

    let inputs = request
        .get("inputs")
        .and_then(Value::as_array)
        .ok_or_else(|| err("invalid_request", "inputs must be an array"))?;
    let outputs = request
        .get("outputs")
        .and_then(Value::as_array)
        .ok_or_else(|| err("invalid_request", "outputs must be an array"))?;
    if inputs.is_empty() {
        return Err(err("invalid_request", "inputs must not be empty"));
    }
    if outputs.is_empty() {
        return Err(err("invalid_request", "outputs must not be empty"));
    }

    match network {
        NetworkType::Main => build_generic(
            Network::MainNetwork,
            network,
            target_height,
            fee,
            inputs,
            outputs,
        ),
        NetworkType::Test => build_generic(
            Network::TestNetwork,
            network,
            target_height,
            fee,
            inputs,
            outputs,
        ),
        NetworkType::Regtest => build_generic(
            regtest_params(),
            network,
            target_height,
            fee,
            inputs,
            outputs,
        ),
    }
}

pub(crate) fn regtest_params() -> LocalNetwork {
    LocalNetwork {
        overwinter: Some(BlockHeight::from_u32(1)),
        sapling: Some(BlockHeight::from_u32(1)),
        blossom: Some(BlockHeight::from_u32(1)),
        heartwood: Some(BlockHeight::from_u32(1)),
        canopy: Some(BlockHeight::from_u32(1)),
        nu5: Some(BlockHeight::from_u32(1)),
        nu6: None,
        nu6_1: None,
        nu6_2: None,
        nu6_3: None,
    }
}

#[cfg(test)]
pub(crate) fn regtest_nu63_params() -> LocalNetwork {
    LocalNetwork {
        overwinter: Some(BlockHeight::from_u32(1)),
        sapling: Some(BlockHeight::from_u32(1)),
        blossom: Some(BlockHeight::from_u32(1)),
        heartwood: Some(BlockHeight::from_u32(1)),
        canopy: Some(BlockHeight::from_u32(1)),
        nu5: Some(BlockHeight::from_u32(1)),
        nu6: Some(BlockHeight::from_u32(1)),
        nu6_1: Some(BlockHeight::from_u32(1)),
        nu6_2: Some(BlockHeight::from_u32(1)),
        nu6_3: Some(BlockHeight::from_u32(1)),
    }
}

fn zatoshis(value: u64, field: &str) -> Result<Zatoshis, BuildError> {
    Zatoshis::from_u64(value)
        .map_err(|_| err("invalid_request", &format!("{field} is out of range")))
}

pub(crate) fn build_generic<P: Parameters + Copy>(
    params: P,
    network: NetworkType,
    target_height: u32,
    fee: u64,
    inputs: &[Value],
    outputs: &[Value],
) -> Result<Value, BuildError> {
    let build_config = BuildConfig::Standard {
        sapling_anchor: None,
        orchard_anchor: None,
        ironwood_anchor: None,
        orchard_padding: BundlePadding::DEFAULT,
        ironwood_padding: BundlePadding::DEFAULT,
    };
    let mut builder = Builder::new(params, BlockHeight::from_u32(target_height), build_config);
    let mut signing_set = TransparentSigningSet::new();

    let mut total_input: u64 = 0;
    for input in inputs {
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
        let pubkey: PublicKey = signing_set.add_key(secret_key);

        let coin = TxOut::new(
            zatoshis(value, "value_zatoshis")?,
            TransparentAddress::from_pubkey(&pubkey).script().into(),
        );
        // OutPoint hash is the txid in internal (reversed display) byte order.
        let mut outpoint_hash = txid;
        outpoint_hash.reverse();
        builder
            .add_transparent_p2pkh_input(pubkey, OutPoint::new(outpoint_hash, vout), coin)
            .map_err(|_| err("invalid_input", "could not add transparent input"))?;
        total_input = total_input
            .checked_add(value)
            .ok_or_else(|| err("invalid_request", "total input value overflows"))?;
    }

    let mut total_output: u64 = 0;
    for output in outputs {
        if !output.is_object() {
            return Err(err("invalid_request", "each output must be a JSON object"));
        }
        let address = output
            .get("address")
            .and_then(Value::as_str)
            .ok_or_else(|| err("invalid_request", "output address must be a string"))?;
        let value = read_zatoshis(output, "value_zatoshis")?;
        if value == 0 {
            return Err(err(
                "invalid_request",
                "output value_zatoshis must be positive",
            ));
        }
        let transparent = transparent_output_address(&params, address)?;
        builder
            .add_transparent_output(&transparent, zatoshis(value, "value_zatoshis")?)
            .map_err(|_| err("invalid_output", "could not add transparent output"))?;
        total_output = total_output
            .checked_add(value)
            .ok_or_else(|| err("invalid_request", "total output value overflows"))?;
    }

    let fee_rule = FixedFeeRule::non_standard(zatoshis(fee, "fee_zatoshis")?);
    let result = builder
        .build(
            &signing_set,
            &[],
            &[],
            ZeroRng,
            &NoProver,
            &NoProver,
            &fee_rule,
        )
        .map_err(map_build_error)?;
    let tx = result.transaction();

    let mut raw = Vec::new();
    tx.write(&mut raw).map_err(|_| {
        err(
            "serialize_failed",
            "could not serialize the built transaction",
        )
    })?;

    Ok(json!({
        "network": super::network_type_label(network),
        "transaction": hex::encode(&raw),
        "txid": tx.txid().to_string(),
        "version": super::tx_version_label(tx.version()),
        "expiry_height": u32::from(tx.expiry_height()),
        "fee_zatoshis": fee,
        "transparent": {
            "vin": inputs.len(),
            "vout": outputs.len(),
        },
        "total_input_zatoshis": total_input,
        "total_output_zatoshis": total_output,
    }))
}

/// A ZIP 320 TEX address is taken as its P2PKH address.
fn transparent_output_address<P: Parameters>(
    params: &P,
    address: &str,
) -> Result<TransparentAddress, BuildError> {
    match Address::decode(params, address) {
            Some(Address::Transparent(t)) => Ok(t),
            Some(Address::Tex(hash)) => Ok(TransparentAddress::PublicKeyHash(hash)),
            Some(Address::Sapling(_)) | Some(Address::Unified(_)) => Err(err(
                "unsupported_shielded_output",
                "transparent build supports transparent outputs only; shielded outputs are not supported",
            )),
            None => Err(err("invalid_output_address", "output address is invalid for the network")),
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
            "inputs exceed outputs plus fee; transparent build requires an exact balance",
        ),
        _ => err(
            "build_failed",
            "could not build the transparent transaction",
        ),
    }
}
