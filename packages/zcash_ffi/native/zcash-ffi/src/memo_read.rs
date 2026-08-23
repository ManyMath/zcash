use super::{
    parse_network_type_label, read_full_transaction, staged_regtest, ufvk_for_network_type,
};
use serde_json::{json, Value};
use std::collections::HashMap;
use zcash_client_backend::decrypt_transaction;
use zcash_keys::keys::UnifiedFullViewingKey;
use zcash_primitives::transaction::Transaction;
use zcash_protocol::consensus::{BlockHeight, MainNetwork, NetworkType, Parameters, TestNetwork};

const MEMO_READ_VERSION: u64 = 1;

type MemoError = (String, String);

fn err(category: &str, message: &str) -> MemoError {
    (category.to_string(), message.to_string())
}

pub fn read_note_memo_json(request: &Value) -> Result<Value, MemoError> {
    if !request.is_object() {
        return Err(err("invalid_request", "request must be a JSON object"));
    }
    if let Some(version) = request.get("memo_read_version") {
        match version.as_u64() {
            Some(v) if v == MEMO_READ_VERSION => {}
            _ => {
                return Err(err(
                    "unsupported_memo_read_version",
                    "memo_read_version must be 1",
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

    let activation = match request.get("regtest_nu63_activation_height") {
        None => None,
        Some(v) => {
            if network != NetworkType::Regtest {
                return Err(err(
                    "unsupported_activation_override",
                    "regtest_nu63_activation_height applies to regtest only; on \
                         mainnet and testnet the NU6.3 activation height is consensus",
                ));
            }
            Some(
                v.as_u64()
                    .filter(|h| *h > 0 && *h <= u64::from(u32::MAX))
                    .ok_or_else(|| {
                        err(
                            "invalid_height",
                            "regtest_nu63_activation_height is out of range",
                        )
                    })? as u32,
            )
        }
    };

    let pool = request
        .get("pool")
        .and_then(Value::as_str)
        .ok_or_else(|| err("invalid_request", "pool must be a string"))?;
    if !matches!(pool, "sapling" | "orchard" | "ironwood") {
        return Err(err(
            "invalid_pool",
            "pool must be 'sapling', 'orchard', or 'ironwood'",
        ));
    }

    let output_index = request
        .get("output_index")
        .and_then(Value::as_u64)
        .ok_or_else(|| {
            err(
                "invalid_request",
                "output_index must be a non-negative integer",
            )
        })? as usize;

    let mined_height = match request.get("mined_height") {
        None => None,
        Some(v) => Some(BlockHeight::from_u32(
            v.as_u64()
                .filter(|h| *h <= u64::from(u32::MAX))
                .ok_or_else(|| err("invalid_height", "mined_height is out of range"))?
                as u32,
        )),
    };

    let transaction_hex = request
        .get("transaction")
        .and_then(Value::as_str)
        .ok_or_else(|| err("invalid_request", "transaction must be a hex string"))?;
    let bytes = hex::decode(transaction_hex.trim())
        .map_err(|_| err("invalid_transaction", "transaction is not valid hex"))?;
    let tx = read_full_transaction(&bytes)
        .map_err(|_| err("invalid_transaction", "transaction could not be read"))?;

    let ufvk_raw = request
        .get("ufvk")
        .and_then(Value::as_str)
        .ok_or_else(|| err("invalid_request", "ufvk must be a string"))?;
    let ufvk = ufvor_network(ufvk_raw, network)
        .ok_or_else(|| err("invalid_ufvk", "invalid UFVK for network"))?;

    match network {
        NetworkType::Main => read(&MainNetwork, ufvk, &tx, pool, output_index, mined_height),
        NetworkType::Test => read(&TestNetwork, ufvk, &tx, pool, output_index, mined_height),
        NetworkType::Regtest => read(
            &staged_regtest::params(activation),
            ufvk,
            &tx,
            pool,
            output_index,
            mined_height,
        ),
    }
}

fn ufvor_network(key: &str, network: NetworkType) -> Option<UnifiedFullViewingKey> {
    ufvk_for_network_type(super::normalize_ufvk(key).as_str(), network)
}

fn read<P: Parameters>(
    params: &P,
    ufvk: UnifiedFullViewingKey,
    tx: &Transaction,
    pool: &str,
    output_index: usize,
    mined_height: Option<BlockHeight>,
) -> Result<Value, MemoError> {
    let mut ufvks = HashMap::new();
    ufvks.insert(0u32, ufvk);
    let decrypted = decrypt_transaction(params, mined_height, None, tx, &ufvks);

    let found: Option<(u64, Vec<u8>)> = match pool {
        "sapling" => decrypted
            .sapling_outputs()
            .iter()
            .find(|output| output.index() == output_index)
            .map(|output| {
                (
                    u64::from(output.note_value()),
                    output.memo().as_slice().to_vec(),
                )
            }),
        "orchard" => decrypted
            .orchard_outputs()
            .iter()
            .find(|output| output.index() == output_index)
            .map(|output| {
                (
                    output.note().0.value().inner(),
                    output.memo().as_slice().to_vec(),
                )
            }),
        _ => decrypted
            .ironwood_outputs()
            .iter()
            .find(|output| output.index() == output_index)
            .map(|output| {
                (
                    output.note().0.value().inner(),
                    output.memo().as_slice().to_vec(),
                )
            }),
    };

    let Some((value_zatoshis, memo_bytes)) = found else {
        return Ok(json!({
            "outcome": "not_for_this_key",
            "pool": pool,
            "output_index": output_index,
        }));
    };

    let empty = is_empty_memo(&memo_bytes);
    Ok(json!({
        "outcome": "decrypted",
        "pool": pool,
        "output_index": output_index,
        "value_zatoshis": value_zatoshis,
        "is_empty_memo": empty,
        "memo": if empty { Value::Null } else { json!(hex::encode(&memo_bytes)) },
    }))
}

/// ZIP 302's empty memo: `0xF6` followed by zero padding.
fn is_empty_memo(bytes: &[u8]) -> bool {
    match bytes.split_first() {
        Some((0xF6, rest)) => rest.iter().all(|b| *b == 0),
        None => true,
        _ => bytes.iter().all(|b| *b == 0),
    }
}
