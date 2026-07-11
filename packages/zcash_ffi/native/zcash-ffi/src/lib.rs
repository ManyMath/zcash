use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use serde_json::{json, Map, Value};
use zcash_protocol::{
    consensus::{
        BranchId, MainNetwork, Network, NetworkConstants, NetworkType, NetworkUpgrade, Parameters,
        TestNetwork,
    },
    constants,
    value::{COIN, MAX_MONEY},
};

const VERSION: &str = env!("CARGO_PKG_VERSION");
const FFI_RESULT_VERSION: u64 = 1;
const FFI_RESULT_VERSION_KEY: &str = "ffi_result_version";
const FFI_RESULT_STATUS_KEY: &str = "status";
const FFI_RESULT_ERROR_STATUS: &str = "error";
const FFI_RESULT_OK_STATUS: &str = "ok";

#[no_mangle]
pub extern "C" fn zcash_ffi_version() -> *mut c_char {
    CString::new(VERSION).unwrap().into_raw()
}

/// # Safety
///
/// `ptr` is null or an unfreed string from a `zcash_ffi_*` export.
#[no_mangle]
pub unsafe extern "C" fn zcash_ffi_free_string(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    drop(CString::from_raw(ptr));
}

#[derive(Debug, Eq, PartialEq)]
enum FfiStringError {
    Null,
    MalformedUtf8,
}

fn ffi_success_value(value: Value) -> Value {
    let mut object = match value {
        Value::Object(object) => object,
        other => {
            let mut object = Map::new();
            object.insert("value".to_string(), other);
            object
        }
    };
    object.insert(
        FFI_RESULT_VERSION_KEY.to_string(),
        json!(FFI_RESULT_VERSION),
    );
    object.insert(
        FFI_RESULT_STATUS_KEY.to_string(),
        json!(FFI_RESULT_OK_STATUS),
    );
    Value::Object(object)
}

fn ffi_error_value(category: &str, msg: &str) -> Value {
    let mut object = Map::new();
    object.insert(
        FFI_RESULT_VERSION_KEY.to_string(),
        json!(FFI_RESULT_VERSION),
    );
    object.insert(
        FFI_RESULT_STATUS_KEY.to_string(),
        json!(FFI_RESULT_ERROR_STATUS),
    );
    object.insert("category".to_string(), json!(category));
    object.insert("error".to_string(), json!(msg));
    Value::Object(object)
}

fn json_success(value: Value) -> *mut c_char {
    json_value_ptr(ffi_success_value(value))
}

fn json_err(category: &str, msg: &str) -> *mut c_char {
    json_value_ptr(ffi_error_value(category, msg))
}

fn json_value_ptr(value: Value) -> *mut c_char {
    CString::new(value.to_string().replace('\0', ""))
        .unwrap()
        .into_raw()
}

fn c_str_to_str<'a>(ptr: *const c_char) -> Result<&'a str, FfiStringError> {
    if ptr.is_null() {
        return Err(FfiStringError::Null);
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .map_err(|_| FfiStringError::MalformedUtf8)
}

fn parse_network_type_label(label: &str) -> Option<NetworkType> {
    match label {
        "main" | "mainnet" => Some(NetworkType::Main),
        "test" | "testnet" => Some(NetworkType::Test),
        "regtest" => Some(NetworkType::Regtest),
        _ => None,
    }
}

fn network_type_label(net: NetworkType) -> &'static str {
    match net {
        NetworkType::Main => "mainnet",
        NetworkType::Test => "testnet",
        NetworkType::Regtest => "regtest",
    }
}

/// # Safety
///
/// `hex_ptr` is null or a C string, and `out` is null or has room for
/// `out_len` bytes.
#[no_mangle]
pub unsafe extern "C" fn zcash_ffi_hex_decode(
    hex_ptr: *const c_char,
    out: *mut u8,
    out_len: usize,
) -> i64 {
    if hex_ptr.is_null() || out.is_null() {
        return -1;
    }
    let hex_str = match CStr::from_ptr(hex_ptr).to_str() {
        Ok(v) => v,
        Err(_) => return -1,
    };
    let bytes = match hex::decode(hex_str) {
        Ok(v) => v,
        Err(_) => return -1,
    };
    let n = bytes.len().min(out_len);
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), out, n);
    n as i64
}

pub const ADDR_TYPE_UNKNOWN: i32 = 0;
pub const ADDR_TYPE_TRANSPARENT: i32 = 1;
pub const ADDR_TYPE_SAPLING: i32 = 2;
pub const ADDR_TYPE_UNIFIED: i32 = 3;

fn network_constants_json(network: NetworkType) -> Value {
    json!({
        "network": network_type_label(network),
        "network_kind": network_type_label(network),
        "coin_type": network.coin_type(),
        "zatoshis_per_zec": COIN,
        "max_money_zatoshis": MAX_MONEY,
        "coinbase_maturity_blocks": zcash_protocol::consensus::COINBASE_MATURITY_BLOCKS,
        "address_prefixes": {
            "sapling_payment_address_hrp": network.hrp_sapling_payment_address(),
            "sapling_extended_spending_key_hrp": network.hrp_sapling_extended_spending_key(),
            "sapling_extended_full_viewing_key_hrp": network.hrp_sapling_extended_full_viewing_key(),
            "tex_address_hrp": network.hrp_tex_address(),
            "unified_address_hrp": network.hrp_unified_address(),
            "unified_full_viewing_key_hrp": network.hrp_unified_fvk(),
            "unified_incoming_viewing_key_hrp": network.hrp_unified_ivk(),
            "sprout_address_b58_prefix": network.b58_sprout_address_prefix(),
            "transparent_pubkey_address_b58_prefix": network.b58_pubkey_address_prefix(),
            "transparent_script_address_b58_prefix": network.b58_script_address_prefix(),
            "transparent_secret_key_b58_prefix": network.b58_secret_key_prefix(),
        },
        "activation_heights": activation_heights_json(network),
    })
}

fn activation_heights_json(network: NetworkType) -> Vec<Value> {
    match network {
        NetworkType::Main => activation_heights_for_params(&MainNetwork),
        NetworkType::Test => activation_heights_for_params(&TestNetwork),
        NetworkType::Regtest => Vec::new(),
    }
}

fn activation_heights_for_params<P: Parameters>(params: &P) -> Vec<Value> {
    [
        NetworkUpgrade::Overwinter,
        NetworkUpgrade::Sapling,
        NetworkUpgrade::Blossom,
        NetworkUpgrade::Heartwood,
        NetworkUpgrade::Canopy,
        NetworkUpgrade::Nu5,
        NetworkUpgrade::Nu6,
        NetworkUpgrade::Nu6_1,
    ]
    .into_iter()
    .filter_map(|upgrade| {
        params.activation_height(upgrade).map(|height| {
            let branch_id = BranchId::for_height(params, height);
            json!({
                "name": upgrade.to_string(),
                "activation_height": u32::from(height),
                "branch_id": format!("{:08x}", u32::from(branch_id)),
            })
        })
    })
    .collect()
}

#[no_mangle]
pub extern "C" fn zcash_ffi_network_constants(network_ptr: *const c_char) -> *mut c_char {
    let network_label = match c_str_to_str(network_ptr) {
        Ok(s) => s,
        Err(FfiStringError::Null) => return json_err("null_pointer", "null network pointer"),
        Err(FfiStringError::MalformedUtf8) => {
            return json_err("malformed_utf8", "network is not valid UTF-8")
        }
    };
    let network = match parse_network_type_label(network_label) {
        Some(network) => network,
        None => {
            return json_err(
                "unsupported_network",
                "network must be 'main', 'test', or 'regtest'",
            )
        }
    };

    json_success(network_constants_json(network))
}

#[cfg(test)]
mod tests;
