use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use serde_json::{json, Map, Value};
use zcash_address::{
    unified::{self, Container},
    ConversionError, ToAddress, TryFromAddress, ZcashAddress,
};
use zcash_keys::{
    address::{Address, UnifiedAddress},
    encoding::{
        decode_extended_full_viewing_key, decode_extended_spending_key,
        encode_extended_spending_key, encode_payment_address,
    },
    keys::{ReceiverRequirement, UnifiedAddressRequest, UnifiedFullViewingKey, UnifiedSpendingKey},
};
use zcash_primitives::transaction::{Transaction, TxVersion};
use zcash_protocol::{
    consensus::{
        BranchId, MainNetwork, Network, NetworkConstants, NetworkType, NetworkUpgrade, Parameters,
        TestNetwork,
    },
    constants,
    value::{COIN, MAX_MONEY},
};
use zcash_script::script::{self, Evaluable};
use zcash_transparent::address::TransparentAddress;
use zcash_transparent::keys::{AccountPrivKey, IncomingViewingKey, NonHardenedChildIndex};
use zip32::{AccountId, DiversifierIndex};

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

fn parse_network_label(label: &str) -> Option<Network> {
    match label {
        "main" | "mainnet" => Some(Network::MainNetwork),
        "test" | "testnet" | "regtest" => Some(Network::TestNetwork),
        _ => None,
    }
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

/// # Safety
///
/// `header_ptr` is null or points to `header_len` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn zcash_ffi_solve_equihash(
    header_ptr: *const u8,
    header_len: usize,
) -> *mut c_char {
    if header_ptr.is_null() {
        return json_err("null_pointer", "null header pointer");
    }
    let header = std::slice::from_raw_parts(header_ptr, header_len);

    let mut counter: u64 = 0;
    const MAX_TRIES: u64 = 1_000_000;
    let solutions = equihash::tromp::solve_200_9::<32>(header, || {
        if counter >= MAX_TRIES {
            return None;
        }
        let mut nonce = [0u8; 32];
        nonce[..8].copy_from_slice(&counter.to_le_bytes());
        counter += 1;
        Some(nonce)
    });

    if solutions.is_empty() {
        return json_err(
            "solver_exhausted",
            "no equihash solution found within nonce budget",
        );
    }

    let matched = counter.saturating_sub(1);
    let mut nonce_bytes = [0u8; 32];
    nonce_bytes[..8].copy_from_slice(&matched.to_le_bytes());

    json_success(json!({
        "nonce": hex::encode(nonce_bytes),
        "solution": hex::encode(&solutions[0]),
    }))
}

pub const ADDR_TYPE_UNKNOWN: i32 = 0;
pub const ADDR_TYPE_TRANSPARENT: i32 = 1;
pub const ADDR_TYPE_SAPLING: i32 = 2;
pub const ADDR_TYPE_UNIFIED: i32 = 3;

#[derive(Debug)]
struct DecodedAddress {
    network: NetworkType,
    receiver_type: &'static str,
    pool: &'static str,
    transparent_kind: Option<&'static str>,
    has_sprout: bool,
    has_orchard: bool,
    has_sapling: bool,
    has_transparent: bool,
    unknown_receivers: usize,
    total_receivers: usize,
}

#[derive(Debug)]
struct UnifiedReceiverInventory {
    network: NetworkType,
    receivers: Vec<UnifiedReceiverInventoryEntry>,
}

#[derive(Debug)]
struct UnifiedReceiverInventoryEntry {
    index: usize,
    kind: &'static str,
    pool: &'static str,
}

#[derive(Debug)]
struct TransparentAddressClassification {
    network: NetworkType,
    address: TransparentAddress,
}

#[derive(Debug)]
struct TransparentClassification {
    network: Option<NetworkType>,
    input_type: &'static str,
    kind: &'static str,
    pool: &'static str,
    is_standard: bool,
    is_transparent: bool,
    script_size: usize,
}

impl TransparentClassification {
    fn from_transparent_address(
        network: Option<NetworkType>,
        input_type: &'static str,
        address: TransparentAddress,
    ) -> Self {
        let kind = match address {
            TransparentAddress::PublicKeyHash(_) => "p2pkh",
            TransparentAddress::ScriptHash(_) => "p2sh",
        };

        Self {
            network,
            input_type,
            kind,
            pool: "transparent",
            is_standard: true,
            is_transparent: true,
            script_size: address.script().to_bytes().len(),
        }
    }

    fn non_standard_script(script_size: usize) -> Self {
        Self {
            network: None,
            input_type: "script",
            kind: "non_standard",
            pool: "unknown",
            is_standard: false,
            is_transparent: false,
            script_size,
        }
    }

    fn into_json(self) -> Value {
        let mut object = Map::new();
        if let Some(network) = self.network {
            object.insert("network".to_string(), json!(network_type_label(network)));
        }
        object.insert("input_type".to_string(), json!(self.input_type));
        object.insert("kind".to_string(), json!(self.kind));
        object.insert("pool".to_string(), json!(self.pool));
        object.insert("standard".to_string(), json!(self.is_standard));
        object.insert("transparent".to_string(), json!(self.is_transparent));
        object.insert("script_size".to_string(), json!(self.script_size));
        Value::Object(object)
    }
}

impl TryFromAddress for TransparentAddressClassification {
    type Error = &'static str;

    fn try_from_sprout(
        _net: NetworkType,
        _data: [u8; 64],
    ) -> Result<Self, ConversionError<Self::Error>> {
        Err(ConversionError::User("not_transparent_address"))
    }

    fn try_from_sapling(
        _net: NetworkType,
        _data: [u8; 43],
    ) -> Result<Self, ConversionError<Self::Error>> {
        Err(ConversionError::User("not_transparent_address"))
    }

    fn try_from_unified(
        _net: NetworkType,
        _data: unified::Address,
    ) -> Result<Self, ConversionError<Self::Error>> {
        Err(ConversionError::User("not_transparent_address"))
    }

    fn try_from_transparent_p2pkh(
        net: NetworkType,
        data: [u8; 20],
    ) -> Result<Self, ConversionError<Self::Error>> {
        Ok(Self {
            network: net,
            address: TransparentAddress::PublicKeyHash(data),
        })
    }

    fn try_from_transparent_p2sh(
        net: NetworkType,
        data: [u8; 20],
    ) -> Result<Self, ConversionError<Self::Error>> {
        Ok(Self {
            network: net,
            address: TransparentAddress::ScriptHash(data),
        })
    }

    fn try_from_tex(
        _net: NetworkType,
        _data: [u8; 20],
    ) -> Result<Self, ConversionError<Self::Error>> {
        Err(ConversionError::User("not_transparent_address"))
    }
}

impl UnifiedReceiverInventory {
    fn into_json(self) -> Value {
        let mut orchard = 0usize;
        let mut sapling = 0usize;
        let mut transparent = 0usize;
        let mut p2pkh = 0usize;
        let mut p2sh = 0usize;
        let mut unknown = 0usize;

        for receiver in &self.receivers {
            match receiver.kind {
                "orchard" => orchard += 1,
                "sapling" => sapling += 1,
                "p2pkh" => {
                    transparent += 1;
                    p2pkh += 1;
                }
                "p2sh" => {
                    transparent += 1;
                    p2sh += 1;
                }
                "unknown" => unknown += 1,
                _ => {}
            }
        }

        json!({
            "network": network_type_label(self.network),
            "address_type": "unified",
            "receiver_count": self.receivers.len(),
            "receivers": self.receivers.into_iter().map(|receiver| {
                json!({
                    "index": receiver.index,
                    "kind": receiver.kind,
                    "pool": receiver.pool,
                })
            }).collect::<Vec<_>>(),
            "counts": {
                "orchard": orchard,
                "sapling": sapling,
                "transparent": transparent,
                "p2pkh": p2pkh,
                "p2sh": p2sh,
                "unknown": unknown,
                "total": orchard + sapling + transparent + unknown,
            }
        })
    }
}

impl TryFromAddress for UnifiedReceiverInventory {
    type Error = &'static str;

    fn try_from_sprout(
        _net: NetworkType,
        _data: [u8; 64],
    ) -> Result<Self, ConversionError<Self::Error>> {
        Err(ConversionError::User("not_unified_address"))
    }

    fn try_from_sapling(
        _net: NetworkType,
        _data: [u8; 43],
    ) -> Result<Self, ConversionError<Self::Error>> {
        Err(ConversionError::User("not_unified_address"))
    }

    fn try_from_unified(
        net: NetworkType,
        data: unified::Address,
    ) -> Result<Self, ConversionError<Self::Error>> {
        let receivers = data
            .items_as_parsed()
            .iter()
            .enumerate()
            .map(|(index, receiver)| {
                let (kind, pool) = match receiver {
                    unified::Receiver::Orchard(_) => ("orchard", "orchard"),
                    unified::Receiver::Sapling(_) => ("sapling", "sapling"),
                    unified::Receiver::P2pkh(_) => ("p2pkh", "transparent"),
                    unified::Receiver::P2sh(_) => ("p2sh", "transparent"),
                    unified::Receiver::Unknown { .. } => ("unknown", "unknown"),
                };
                UnifiedReceiverInventoryEntry { index, kind, pool }
            })
            .collect();

        Ok(Self {
            network: net,
            receivers,
        })
    }

    fn try_from_transparent_p2pkh(
        _net: NetworkType,
        _data: [u8; 20],
    ) -> Result<Self, ConversionError<Self::Error>> {
        Err(ConversionError::User("not_unified_address"))
    }

    fn try_from_transparent_p2sh(
        _net: NetworkType,
        _data: [u8; 20],
    ) -> Result<Self, ConversionError<Self::Error>> {
        Err(ConversionError::User("not_unified_address"))
    }

    fn try_from_tex(
        _net: NetworkType,
        _data: [u8; 20],
    ) -> Result<Self, ConversionError<Self::Error>> {
        Err(ConversionError::User("not_unified_address"))
    }
}

impl DecodedAddress {
    fn single(
        network: NetworkType,
        receiver_type: &'static str,
        pool: &'static str,
        transparent_kind: Option<&'static str>,
    ) -> Self {
        Self {
            network,
            receiver_type,
            pool,
            transparent_kind,
            has_sprout: receiver_type == "sprout",
            has_orchard: receiver_type == "orchard",
            has_sapling: receiver_type == "sapling",
            has_transparent: pool == "transparent",
            unknown_receivers: 0,
            total_receivers: 1,
        }
    }

    fn into_json(self) -> Value {
        json!({
            "network": network_type_label(self.network),
            "receiver_type": self.receiver_type,
            "pool": self.pool,
            "receivers": {
                "sprout": self.has_sprout,
                "orchard": self.has_orchard,
                "sapling": self.has_sapling,
                "transparent": self.has_transparent,
                "transparent_kind": self.transparent_kind,
                "unknown": self.unknown_receivers,
                "total": self.total_receivers,
            }
        })
    }
}

impl TryFromAddress for DecodedAddress {
    type Error = &'static str;

    fn try_from_sprout(
        net: NetworkType,
        _data: [u8; 64],
    ) -> Result<Self, ConversionError<Self::Error>> {
        Ok(Self::single(net, "sprout", "sprout", None))
    }

    fn try_from_sapling(
        net: NetworkType,
        _data: [u8; 43],
    ) -> Result<Self, ConversionError<Self::Error>> {
        Ok(Self::single(net, "sapling", "sapling", None))
    }

    fn try_from_unified(
        net: NetworkType,
        data: unified::Address,
    ) -> Result<Self, ConversionError<Self::Error>> {
        let mut has_orchard = false;
        let mut has_sapling = false;
        let mut transparent_kind = None;
        let mut unknown_receivers = 0usize;

        for receiver in data.items_as_parsed() {
            match receiver {
                unified::Receiver::Orchard(_) => has_orchard = true,
                unified::Receiver::Sapling(_) => has_sapling = true,
                unified::Receiver::P2pkh(_) => transparent_kind = Some("p2pkh"),
                unified::Receiver::P2sh(_) => transparent_kind = Some("p2sh"),
                unified::Receiver::Unknown { .. } => unknown_receivers += 1,
            }
        }

        let has_transparent = transparent_kind.is_some();
        let known_pool_count =
            usize::from(has_orchard) + usize::from(has_sapling) + usize::from(has_transparent);
        let pool = if known_pool_count == 1 && unknown_receivers == 0 {
            if has_orchard {
                "orchard"
            } else if has_sapling {
                "sapling"
            } else {
                "transparent"
            }
        } else {
            "mixed"
        };

        Ok(Self {
            network: net,
            receiver_type: "unified",
            pool,
            transparent_kind,
            has_sprout: false,
            has_orchard,
            has_sapling,
            has_transparent,
            unknown_receivers,
            total_receivers: data.items_as_parsed().len(),
        })
    }

    fn try_from_transparent_p2pkh(
        net: NetworkType,
        _data: [u8; 20],
    ) -> Result<Self, ConversionError<Self::Error>> {
        Ok(Self::single(net, "p2pkh", "transparent", Some("p2pkh")))
    }

    fn try_from_transparent_p2sh(
        net: NetworkType,
        _data: [u8; 20],
    ) -> Result<Self, ConversionError<Self::Error>> {
        Ok(Self::single(net, "p2sh", "transparent", Some("p2sh")))
    }

    fn try_from_tex(
        net: NetworkType,
        _data: [u8; 20],
    ) -> Result<Self, ConversionError<Self::Error>> {
        Ok(Self::single(net, "tex", "transparent", Some("tex")))
    }
}

fn classify_zaddr(s: &str) -> i32 {
    let Ok(zaddr) = s.parse::<ZcashAddress>() else {
        return ADDR_TYPE_UNKNOWN;
    };
    let addr = Address::decode(&MainNetwork, s).or_else(|| Address::decode(&TestNetwork, s));
    match addr {
        Some(Address::Transparent(_)) => ADDR_TYPE_TRANSPARENT,
        Some(Address::Sapling(_)) => ADDR_TYPE_SAPLING,
        Some(Address::Unified(_)) => ADDR_TYPE_UNIFIED,
        _ => {
            if zaddr.is_transparent_only() {
                ADDR_TYPE_TRANSPARENT
            } else {
                ADDR_TYPE_UNKNOWN
            }
        }
    }
}

#[no_mangle]
pub extern "C" fn zcash_ffi_decode_address(
    addr_ptr: *const c_char,
    network_ptr: *const c_char,
) -> *mut c_char {
    let addr_str = match c_str_to_str(addr_ptr) {
        Ok(s) => s,
        Err(FfiStringError::Null) => return json_err("null_pointer", "null address pointer"),
        Err(FfiStringError::MalformedUtf8) => {
            return json_err("malformed_utf8", "address is not valid UTF-8")
        }
    };
    let network_label = match c_str_to_str(network_ptr) {
        Ok(s) => s,
        Err(FfiStringError::Null) => return json_err("null_pointer", "null network pointer"),
        Err(FfiStringError::MalformedUtf8) => {
            return json_err("malformed_utf8", "network is not valid UTF-8")
        }
    };
    let expected_network = match parse_network_type_label(network_label) {
        Some(n) => n,
        None => {
            return json_err(
                "unsupported_network",
                "network must be 'main', 'test', or 'regtest'",
            )
        }
    };

    let zaddr = match ZcashAddress::try_from_encoded(addr_str) {
        Ok(zaddr) => zaddr,
        Err(_) => return json_err("invalid_address", "invalid Zcash address"),
    };

    match zaddr.convert_if_network::<DecodedAddress>(expected_network) {
        Ok(decoded) => json_success(decoded.into_json()),
        Err(ConversionError::IncorrectNetwork { .. }) => {
            json_err("wrong_network", "address is not valid for expected network")
        }
        Err(ConversionError::Unsupported(_)) => {
            json_err("unsupported_address", "address type is unsupported")
        }
        Err(ConversionError::User(_)) => json_err("invalid_address", "invalid Zcash address"),
    }
}

#[no_mangle]
pub extern "C" fn zcash_ffi_unified_address_receivers(
    addr_ptr: *const c_char,
    network_ptr: *const c_char,
) -> *mut c_char {
    let addr_str = match c_str_to_str(addr_ptr) {
        Ok(s) => s,
        Err(FfiStringError::Null) => return json_err("null_pointer", "null address pointer"),
        Err(FfiStringError::MalformedUtf8) => {
            return json_err("malformed_utf8", "address is not valid UTF-8")
        }
    };
    let network_label = match c_str_to_str(network_ptr) {
        Ok(s) => s,
        Err(FfiStringError::Null) => return json_err("null_pointer", "null network pointer"),
        Err(FfiStringError::MalformedUtf8) => {
            return json_err("malformed_utf8", "network is not valid UTF-8")
        }
    };
    let expected_network = match parse_network_type_label(network_label) {
        Some(n) => n,
        None => {
            return json_err(
                "unsupported_network",
                "network must be 'main', 'test', or 'regtest'",
            )
        }
    };

    let zaddr = match ZcashAddress::try_from_encoded(addr_str) {
        Ok(zaddr) => zaddr,
        Err(_) => return json_err("invalid_address", "invalid Zcash address"),
    };

    match zaddr.convert_if_network::<UnifiedReceiverInventory>(expected_network) {
        Ok(inventory) => json_success(inventory.into_json()),
        Err(ConversionError::IncorrectNetwork { .. }) => {
            json_err("wrong_network", "address is not valid for expected network")
        }
        Err(ConversionError::User("not_unified_address")) => {
            json_err("not_unified_address", "address is not a Unified Address")
        }
        Err(ConversionError::Unsupported(_)) | Err(ConversionError::User(_)) => {
            json_err("unsupported_address", "address type is unsupported")
        }
    }
}

#[no_mangle]
pub extern "C" fn zcash_ffi_classify_transparent_address(
    addr_ptr: *const c_char,
    network_ptr: *const c_char,
) -> *mut c_char {
    let addr_str = match c_str_to_str(addr_ptr) {
        Ok(s) => s,
        Err(FfiStringError::Null) => return json_err("null_pointer", "null address pointer"),
        Err(FfiStringError::MalformedUtf8) => {
            return json_err("malformed_utf8", "address is not valid UTF-8")
        }
    };
    let network_label = match c_str_to_str(network_ptr) {
        Ok(s) => s,
        Err(FfiStringError::Null) => return json_err("null_pointer", "null network pointer"),
        Err(FfiStringError::MalformedUtf8) => {
            return json_err("malformed_utf8", "network is not valid UTF-8")
        }
    };
    let expected_network = match parse_network_type_label(network_label) {
        Some(n) => n,
        None => {
            return json_err(
                "unsupported_network",
                "network must be 'main', 'test', or 'regtest'",
            )
        }
    };

    let zaddr = match ZcashAddress::try_from_encoded(addr_str) {
        Ok(zaddr) => zaddr,
        Err(_) => return json_err("invalid_address", "invalid Zcash address"),
    };

    match zaddr.convert_if_network::<TransparentAddressClassification>(expected_network) {
        Ok(classification) => json_success(
            TransparentClassification::from_transparent_address(
                Some(classification.network),
                "address",
                classification.address,
            )
            .into_json(),
        ),
        Err(ConversionError::IncorrectNetwork { .. }) => {
            json_err("wrong_network", "address is not valid for expected network")
        }
        Err(ConversionError::User("not_transparent_address")) => {
            json_err("not_transparent_address", "address is not transparent")
        }
        Err(ConversionError::Unsupported(_)) | Err(ConversionError::User(_)) => {
            json_err("unsupported_address", "address type is unsupported")
        }
    }
}

#[no_mangle]
pub extern "C" fn zcash_ffi_classify_transparent_script(
    script_hex_ptr: *const c_char,
) -> *mut c_char {
    let script_hex = match c_str_to_str(script_hex_ptr) {
        Ok(s) => s,
        Err(FfiStringError::Null) => return json_err("null_pointer", "null script pointer"),
        Err(FfiStringError::MalformedUtf8) => {
            return json_err("malformed_utf8", "script is not valid UTF-8")
        }
    };

    let bytes = match hex::decode(script_hex) {
        Ok(bytes) => bytes,
        Err(_) => return json_err("invalid_hex", "script must be hex encoded"),
    };

    let script = match script::FromChain::parse(&script::Code(bytes.clone())) {
        Ok(script) => script,
        Err(_) => return json_err("invalid_script", "script bytes are not parseable"),
    };

    match TransparentAddress::from_script_from_chain(&script) {
        Some(address) => json_success(
            TransparentClassification::from_transparent_address(None, "script", address)
                .into_json(),
        ),
        None => {
            json_success(TransparentClassification::non_standard_script(bytes.len()).into_json())
        }
    }
}

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

/// 0 unknown, 1 transparent, 2 Sapling, 3 unified.
#[no_mangle]
pub extern "C" fn zcash_ffi_address_type(addr_ptr: *const c_char) -> i32 {
    match c_str_to_str(addr_ptr) {
        Ok(s) => classify_zaddr(s),
        Err(_) => ADDR_TYPE_UNKNOWN,
    }
}

#[no_mangle]
pub extern "C" fn zcash_ffi_is_transparent_address(addr_ptr: *const c_char) -> bool {
    zcash_ffi_address_type(addr_ptr) == ADDR_TYPE_TRANSPARENT
}

#[no_mangle]
pub extern "C" fn zcash_ffi_is_shielded_address(addr_ptr: *const c_char) -> bool {
    let t = zcash_ffi_address_type(addr_ptr);
    t == ADDR_TYPE_SAPLING || t == ADDR_TYPE_UNIFIED
}

#[no_mangle]
pub extern "C" fn zcash_ffi_mnemonic_from_entropy(entropy_ptr: *const c_char) -> *mut c_char {
    let entropy_hex = match c_str_to_str(entropy_ptr) {
        Ok(s) => s,
        Err(FfiStringError::Null) => return json_err("null_pointer", "null entropy pointer"),
        Err(FfiStringError::MalformedUtf8) => {
            return json_err("malformed_utf8", "entropy is not valid UTF-8")
        }
    };
    let entropy = match hex::decode(entropy_hex.trim()) {
        Ok(b) => b,
        Err(_) => return json_err("invalid_hex", "entropy is not valid hex"),
    };
    match bip0039::Mnemonic::<bip0039::English>::from_entropy(entropy) {
        Ok(mnemonic) => json_success(json!({
            "phrase": mnemonic.phrase(),
            "word_count": mnemonic.phrase().split(' ').count(),
        })),
        Err(_) => json_err(
            "invalid_entropy",
            "entropy must be 16, 20, 24, 28 or 32 bytes",
        ),
    }
}

/// `passphrase` is the optional BIP 39 passphrase, empty for none.
#[no_mangle]
pub extern "C" fn zcash_ffi_mnemonic_to_seed(
    phrase_ptr: *const c_char,
    passphrase_ptr: *const c_char,
) -> *mut c_char {
    let phrase = match c_str_to_str(phrase_ptr) {
        Ok(s) => s,
        Err(FfiStringError::Null) => return json_err("null_pointer", "null phrase pointer"),
        Err(FfiStringError::MalformedUtf8) => {
            return json_err("malformed_utf8", "phrase is not valid UTF-8")
        }
    };
    let passphrase = match c_str_to_str(passphrase_ptr) {
        Ok(s) => s,
        Err(FfiStringError::Null) => return json_err("null_pointer", "null passphrase pointer"),
        Err(FfiStringError::MalformedUtf8) => {
            return json_err("malformed_utf8", "passphrase is not valid UTF-8")
        }
    };
    match bip0039::Mnemonic::<bip0039::English>::from_phrase(phrase) {
        Ok(mnemonic) => json_success(json!({
            "seed": hex::encode(mnemonic.to_seed(passphrase)),
            "word_count": mnemonic.phrase().split(' ').count(),
        })),
        Err(bip0039::Error::BadWordCount(count)) => json_err(
            "invalid_mnemonic_word_count",
            &format!("a phrase has 12, 15, 18, 21 or 24 words, not {count}"),
        ),
        Err(bip0039::Error::UnknownWord(_)) => json_err(
            "invalid_mnemonic_word",
            "the phrase contains a word that is not in the BIP 39 English list",
        ),
        Err(bip0039::Error::InvalidChecksum) => json_err(
            "invalid_mnemonic_checksum",
            "the phrase's checksum does not match; a word is wrong or out of order",
        ),
        Err(_) => json_err("invalid_mnemonic", "the phrase is not a BIP 39 mnemonic"),
    }
}

#[no_mangle]
pub extern "C" fn zcash_ffi_seed_to_account_ufvk(
    seed_ptr: *const c_char,
    network_ptr: *const c_char,
    account_index: u32,
) -> *mut c_char {
    let seed_hex = match c_str_to_str(seed_ptr) {
        Ok(s) => s,
        Err(FfiStringError::Null) => return json_err("null_pointer", "null seed pointer"),
        Err(FfiStringError::MalformedUtf8) => {
            return json_err("malformed_utf8", "seed is not valid UTF-8")
        }
    };
    let seed_bytes = match hex::decode(seed_hex) {
        Ok(b) => b,
        Err(_) => return json_err("invalid_hex", "seed is not valid hex"),
    };
    if seed_bytes.len() < 32 {
        return json_err("invalid_seed", "seed must be at least 32 bytes");
    }
    let network_label = match c_str_to_str(network_ptr) {
        Ok(s) => s,
        Err(FfiStringError::Null) => return json_err("null_pointer", "null network pointer"),
        Err(FfiStringError::MalformedUtf8) => {
            return json_err("malformed_utf8", "network is not valid UTF-8")
        }
    };
    let net = match parse_network_label(network_label) {
        Some(n) => n,
        None => {
            return json_err(
                "unsupported_network",
                "network must be 'main', 'test', or 'regtest'",
            )
        }
    };
    let account_id = match AccountId::try_from(account_index) {
        Ok(id) => id,
        Err(_) => return json_err("invalid_account", "account_index out of range"),
    };

    let ufvk_str = match derive_ufvk_str(&seed_bytes, &net, account_id) {
        Ok(s) => s,
        Err(e) => return json_err("derivation_error", &e),
    };

    json_success(json!({ "ufvk": ufvk_str }))
}

#[no_mangle]
pub extern "C" fn zcash_ffi_seed_to_account_metadata(
    seed_ptr: *const c_char,
    network_ptr: *const c_char,
    account_index: u32,
) -> *mut c_char {
    let seed_hex = match c_str_to_str(seed_ptr) {
        Ok(s) => s,
        Err(FfiStringError::Null) => return json_err("null_pointer", "null seed pointer"),
        Err(FfiStringError::MalformedUtf8) => {
            return json_err("malformed_utf8", "seed is not valid UTF-8")
        }
    };
    let seed_bytes = match hex::decode(seed_hex) {
        Ok(b) => b,
        Err(_) => return json_err("invalid_hex", "seed is not valid hex"),
    };
    if seed_bytes.len() < 32 {
        return json_err("invalid_seed", "seed must be at least 32 bytes");
    }
    let network_label = match c_str_to_str(network_ptr) {
        Ok(s) => s,
        Err(FfiStringError::Null) => return json_err("null_pointer", "null network pointer"),
        Err(FfiStringError::MalformedUtf8) => {
            return json_err("malformed_utf8", "network is not valid UTF-8")
        }
    };
    let network_type = match parse_network_type_label(network_label) {
        Some(n) => n,
        None => {
            return json_err(
                "unsupported_network",
                "network must be 'main', 'test', or 'regtest'",
            )
        }
    };
    let net = match parse_network_label(network_label) {
        Some(n) => n,
        None => {
            return json_err(
                "unsupported_network",
                "network must be 'main', 'test', or 'regtest'",
            )
        }
    };
    let account_id = match AccountId::try_from(account_index) {
        Ok(id) => id,
        Err(_) => return json_err("invalid_account", "account_index out of range"),
    };

    match derive_account_metadata_json(&seed_bytes, &net, network_type, account_id, account_index) {
        Ok(value) => json_success(value),
        Err(e) => json_err("derivation_error", &e),
    }
}

#[no_mangle]
pub extern "C" fn zcash_ffi_seed_to_viewing_keys(
    seed_ptr: *const c_char,
    network_ptr: *const c_char,
    account_index: u32,
) -> *mut c_char {
    let seed_hex = match c_str_to_str(seed_ptr) {
        Ok(s) => s,
        Err(FfiStringError::Null) => return json_err("null_pointer", "null seed pointer"),
        Err(FfiStringError::MalformedUtf8) => {
            return json_err("malformed_utf8", "seed is not valid UTF-8")
        }
    };
    let seed_bytes = match hex::decode(seed_hex) {
        Ok(b) => b,
        Err(_) => return json_err("invalid_hex", "seed is not valid hex"),
    };
    if seed_bytes.len() < 32 {
        return json_err("invalid_seed", "seed must be at least 32 bytes");
    }
    let network_label = match c_str_to_str(network_ptr) {
        Ok(s) => s,
        Err(FfiStringError::Null) => return json_err("null_pointer", "null network pointer"),
        Err(FfiStringError::MalformedUtf8) => {
            return json_err("malformed_utf8", "network is not valid UTF-8")
        }
    };
    let network_type = match parse_network_type_label(network_label) {
        Some(n) => n,
        None => {
            return json_err(
                "unsupported_network",
                "network must be 'main', 'test', or 'regtest'",
            )
        }
    };
    let net = match parse_network_label(network_label) {
        Some(n) => n,
        None => {
            return json_err(
                "unsupported_network",
                "network must be 'main', 'test', or 'regtest'",
            )
        }
    };
    let regtest_hrp = network_label == "regtest";
    let account_id = match AccountId::try_from(account_index) {
        Ok(id) => id,
        Err(_) => return json_err("invalid_account", "account_index out of range"),
    };

    match derive_viewing_keys_json(
        &seed_bytes,
        &net,
        network_type,
        account_id,
        account_index,
        regtest_hrp,
    ) {
        Ok(value) => json_success(value),
        Err(e) => json_err("derivation_error", &e),
    }
}

fn derive_ufvk_str(seed: &[u8], net: &Network, account: AccountId) -> Result<String, String> {
    let usk = match net {
        Network::MainNetwork => UnifiedSpendingKey::from_seed(&MainNetwork, seed, account),
        Network::TestNetwork => UnifiedSpendingKey::from_seed(&TestNetwork, seed, account),
    }
    .map_err(|e| format!("key derivation error: {:?}", e))?;
    let ufvk = usk.to_unified_full_viewing_key();
    Ok(match net {
        Network::MainNetwork => ufvk.encode(&MainNetwork),
        Network::TestNetwork => ufvk.encode(&TestNetwork),
    })
}

fn derive_account_metadata_json(
    seed: &[u8],
    net: &Network,
    network_type: NetworkType,
    account: AccountId,
    account_index: u32,
) -> Result<Value, String> {
    let usk = match net {
        Network::MainNetwork => UnifiedSpendingKey::from_seed(&MainNetwork, seed, account),
        Network::TestNetwork => UnifiedSpendingKey::from_seed(&TestNetwork, seed, account),
    }
    .map_err(|e| format!("key derivation error: {:?}", e))?;
    let ufvk = usk.to_unified_full_viewing_key();
    let ufvk_str = match net {
        Network::MainNetwork => ufvk.encode(&MainNetwork),
        Network::TestNetwork => ufvk.encode(&TestNetwork),
    };
    let transparent_xpub = ufvk
        .transparent()
        .map(|account_pub_key| encode_transparent_xpub(account_pub_key, net, account_index))
        .transpose()?;

    let receiver_kinds = account_receiver_kinds_json(&ufvk);

    Ok(json!({
        "network": network_type_label(network_type),
        "account_index": account_index,
        "ufvk": ufvk_str,
        "transparent_account_xpub": transparent_xpub,
        "receivers": {
            "orchard": ufvk.orchard().is_some(),
            "sapling": ufvk.sapling().is_some(),
            "transparent": ufvk.transparent().is_some(),
            "p2pkh": ufvk.transparent().is_some(),
            "p2sh": false,
            "unknown": 0,
            "total": receiver_kinds.len(),
        },
        "receiver_kinds": receiver_kinds,
    }))
}

fn account_receiver_kinds_json(ufvk: &UnifiedFullViewingKey) -> Vec<Value> {
    let mut receiver_kinds = Vec::new();
    if ufvk.orchard().is_some() {
        receiver_kinds.push(json!({"kind": "orchard", "pool": "orchard"}));
    }
    if ufvk.sapling().is_some() {
        receiver_kinds.push(json!({"kind": "sapling", "pool": "sapling"}));
    }
    if ufvk.transparent().is_some() {
        receiver_kinds.push(json!({"kind": "p2pkh", "pool": "transparent"}));
    }
    receiver_kinds
}

fn derive_viewing_keys_json(
    seed: &[u8],
    net: &Network,
    network_type: NetworkType,
    account: AccountId,
    account_index: u32,
    regtest_hrp: bool,
) -> Result<Value, String> {
    let usk = match net {
        Network::MainNetwork => UnifiedSpendingKey::from_seed(&MainNetwork, seed, account),
        Network::TestNetwork => UnifiedSpendingKey::from_seed(&TestNetwork, seed, account),
    }
    .map_err(|e| format!("key derivation error: {:?}", e))?;
    let ufvk = usk.to_unified_full_viewing_key();

    let transparent = match ufvk.transparent() {
        Some(account_pub_key) => {
            let external_ivk = account_pub_key
                .derive_external_ivk()
                .map_err(|e| format!("external ivk derivation error: {:?}", e))?;
            let internal_ivk = account_pub_key
                .derive_internal_ivk()
                .map_err(|e| format!("internal ivk derivation error: {:?}", e))?;
            let (default_addr, default_index) = external_ivk.default_address();
            let default_addr_str = match net {
                Network::MainNetwork => Address::Transparent(default_addr).encode(&MainNetwork),
                Network::TestNetwork => Address::Transparent(default_addr).encode(&TestNetwork),
            };
            json!({
                "available": true,
                "external_ivk": hex::encode(external_ivk.serialize()),
                "internal_ivk": hex::encode(internal_ivk.serialize()),
                "default_external_address": default_addr_str,
                "default_external_index": default_index.index(),
            })
        }
        None => json!({ "available": false }),
    };

    let sapling = match ufvk.sapling() {
        Some(dfvk) => {
            let (div_index, payment_address) = dfvk.default_address();
            let default_addr_str = if regtest_hrp {
                encode_payment_address(
                    constants::regtest::HRP_SAPLING_PAYMENT_ADDRESS,
                    &payment_address,
                )
            } else {
                let addr = Address::Sapling(payment_address);
                match net {
                    Network::MainNetwork => addr.encode(&MainNetwork),
                    Network::TestNetwork => addr.encode(&TestNetwork),
                }
            };
            let div_index_u64 = u64::try_from(div_index)
                .map_err(|_| "default diversifier index exceeds supported range".to_string())?;
            json!({
                "available": true,
                "default_address": default_addr_str,
                "default_diversifier_index": div_index_u64,
            })
        }
        None => json!({ "available": false }),
    };

    Ok(json!({
        "network": network_type_label(network_type),
        "account_index": account_index,
        "transparent": transparent,
        "sapling": sapling,
        "orchard": {
            "available": ufvk.orchard().is_some(),
        },
    }))
}

/// Never echoes the key.
#[no_mangle]
pub extern "C" fn zcash_ffi_validate_key(
    key_ptr: *const c_char,
    network_ptr: *const c_char,
    key_type_ptr: *const c_char,
) -> *mut c_char {
    let key_str = match c_str_to_str(key_ptr) {
        Ok(s) => s,
        Err(FfiStringError::Null) => return json_err("null_pointer", "null key pointer"),
        Err(FfiStringError::MalformedUtf8) => {
            return json_err("malformed_utf8", "key is not valid UTF-8")
        }
    };
    let network_label = match c_str_to_str(network_ptr) {
        Ok(s) => s,
        Err(FfiStringError::Null) => return json_err("null_pointer", "null network pointer"),
        Err(FfiStringError::MalformedUtf8) => {
            return json_err("malformed_utf8", "network is not valid UTF-8")
        }
    };
    let network_type = match parse_network_type_label(network_label) {
        Some(n) => n,
        None => {
            return json_err(
                "unsupported_network",
                "network must be 'main', 'test', or 'regtest'",
            )
        }
    };
    let key_type_label = match c_str_to_str(key_type_ptr) {
        Ok(s) => s,
        Err(FfiStringError::Null) => return json_err("null_pointer", "null key_type pointer"),
        Err(FfiStringError::MalformedUtf8) => {
            return json_err("malformed_utf8", "key_type is not valid UTF-8")
        }
    };

    let key_str = key_str.trim();
    let validation = match key_type_label {
        "ufvk" => validate_ufvk_key(key_str, network_type),
        "sapling_extended_full_viewing_key" => validate_sapling_key(key_str, network_type, false),
        "sapling_extended_spending_key" => validate_sapling_key(key_str, network_type, true),
        "transparent_xpub" => validate_transparent_xpub_key(key_str, network_type),
        _ => {
            return json_err(
                "unsupported_key_type",
                "key_type must be 'ufvk', 'sapling_extended_full_viewing_key', \
                 'sapling_extended_spending_key', or 'transparent_xpub'",
            )
        }
    };

    json_success(validation)
}

fn validation_result(key_type: &str, network_type: NetworkType, body: Value) -> Value {
    let mut obj = Map::new();
    obj.insert("key_type".to_string(), json!(key_type));
    obj.insert(
        "network".to_string(),
        json!(network_type_label(network_type)),
    );
    if let Value::Object(extra) = body {
        for (k, v) in extra {
            obj.insert(k, v);
        }
    }
    Value::Object(obj)
}

fn ufvk_for_network_type(key: &str, network_type: NetworkType) -> Option<UnifiedFullViewingKey> {
    match network_type {
        NetworkType::Main => UnifiedFullViewingKey::decode(&MainNetwork, key).ok(),
        NetworkType::Test | NetworkType::Regtest => {
            UnifiedFullViewingKey::decode(&TestNetwork, key).ok()
        }
    }
}

fn validate_ufvk_key(key: &str, network_type: NetworkType) -> Value {
    if let Some(ufvk) = ufvk_for_network_type(key, network_type) {
        return validation_result(
            "ufvk",
            network_type,
            json!({
                "valid": true,
                "components": {
                    "orchard": ufvk.orchard().is_some(),
                    "sapling": ufvk.sapling().is_some(),
                    "transparent": ufvk.transparent().is_some(),
                },
            }),
        );
    }
    let other = match network_type {
        NetworkType::Main => UnifiedFullViewingKey::decode(&TestNetwork, key).is_ok(),
        NetworkType::Test | NetworkType::Regtest => {
            UnifiedFullViewingKey::decode(&MainNetwork, key).is_ok()
        }
    };
    let reason = if other { "wrong_network" } else { "invalid" };
    validation_result(
        "ufvk",
        network_type,
        json!({ "valid": false, "reason": reason }),
    )
}

fn sapling_hrps(network_type: NetworkType, spending: bool) -> &'static str {
    match (network_type, spending) {
        (NetworkType::Main, true) => constants::mainnet::HRP_SAPLING_EXTENDED_SPENDING_KEY,
        (NetworkType::Test, true) => constants::testnet::HRP_SAPLING_EXTENDED_SPENDING_KEY,
        (NetworkType::Regtest, true) => constants::regtest::HRP_SAPLING_EXTENDED_SPENDING_KEY,
        (NetworkType::Main, false) => constants::mainnet::HRP_SAPLING_EXTENDED_FULL_VIEWING_KEY,
        (NetworkType::Test, false) => constants::testnet::HRP_SAPLING_EXTENDED_FULL_VIEWING_KEY,
        (NetworkType::Regtest, false) => constants::regtest::HRP_SAPLING_EXTENDED_FULL_VIEWING_KEY,
    }
}

fn sapling_key_decodes(hrp: &str, key: &str, spending: bool) -> bool {
    if spending {
        decode_extended_spending_key(hrp, key).is_ok()
    } else {
        decode_extended_full_viewing_key(hrp, key).is_ok()
    }
}

fn validate_sapling_key(key: &str, network_type: NetworkType, spending: bool) -> Value {
    let key_type = if spending {
        "sapling_extended_spending_key"
    } else {
        "sapling_extended_full_viewing_key"
    };
    let hrp = sapling_hrps(network_type, spending);
    if sapling_key_decodes(hrp, key, spending) {
        return validation_result(key_type, network_type, json!({ "valid": true }));
    }
    let other_networks = [NetworkType::Main, NetworkType::Test, NetworkType::Regtest];
    let wrong_network = other_networks.iter().any(|&other| {
        other != network_type && sapling_key_decodes(sapling_hrps(other, spending), key, spending)
    });
    let reason = if wrong_network {
        "wrong_network"
    } else {
        "invalid"
    };
    validation_result(
        key_type,
        network_type,
        json!({ "valid": false, "reason": reason }),
    )
}

const XPUB_VERSION_MAIN: [u8; 4] = [0x04, 0x88, 0xB2, 0x1E];
const XPUB_VERSION_TEST: [u8; 4] = [0x04, 0x35, 0x87, 0xCF];

fn expected_xpub_version(network_type: NetworkType) -> [u8; 4] {
    match network_type {
        NetworkType::Main => XPUB_VERSION_MAIN,
        NetworkType::Test | NetworkType::Regtest => XPUB_VERSION_TEST,
    }
}

fn validate_transparent_xpub_key(key: &str, network_type: NetworkType) -> Value {
    let decoded = match bs58::decode(key).with_check(None).into_vec() {
        Ok(b) if b.len() == 78 => b,
        _ => {
            return validation_result(
                "transparent_xpub",
                network_type,
                json!({ "valid": false, "reason": "invalid" }),
            )
        }
    };
    let version = [decoded[0], decoded[1], decoded[2], decoded[3]];
    let payload = &decoded[4..];
    let mut key_data = [0u8; 65];
    key_data[..32].copy_from_slice(&payload[9..41]);
    key_data[32..].copy_from_slice(&payload[41..74]);
    let key_data_ok = zcash_transparent::keys::AccountPubKey::deserialize(&key_data).is_ok();

    if !key_data_ok {
        return validation_result(
            "transparent_xpub",
            network_type,
            json!({ "valid": false, "reason": "invalid" }),
        );
    }
    if version != expected_xpub_version(network_type) {
        let reason = if version == XPUB_VERSION_MAIN || version == XPUB_VERSION_TEST {
            "wrong_network"
        } else {
            "invalid"
        };
        return validation_result(
            "transparent_xpub",
            network_type,
            json!({ "valid": false, "reason": reason }),
        );
    }
    validation_result("transparent_xpub", network_type, json!({ "valid": true }))
}

#[no_mangle]
pub extern "C" fn zcash_ffi_seed_to_sapling_spending_key(
    seed_ptr: *const c_char,
    network_ptr: *const c_char,
    account_index: u32,
) -> *mut c_char {
    let seed_hex = match c_str_to_str(seed_ptr) {
        Ok(s) => s,
        Err(FfiStringError::Null) => return json_err("null_pointer", "null seed pointer"),
        Err(FfiStringError::MalformedUtf8) => {
            return json_err("malformed_utf8", "seed is not valid UTF-8")
        }
    };
    let seed_bytes = match hex::decode(seed_hex) {
        Ok(b) => b,
        Err(_) => return json_err("invalid_hex", "seed is not valid hex"),
    };
    if seed_bytes.len() < 32 {
        return json_err("invalid_seed", "seed must be at least 32 bytes");
    }
    let network_name = match c_str_to_str(network_ptr) {
        Ok(s) => s,
        Err(FfiStringError::Null) => return json_err("null_pointer", "null network pointer"),
        Err(FfiStringError::MalformedUtf8) => {
            return json_err("malformed_utf8", "network is not valid UTF-8")
        }
    };
    let net = match parse_network_label(network_name) {
        Some(n) => n,
        None => {
            return json_err(
                "unsupported_network",
                "network must be 'main', 'test', or 'regtest'",
            )
        }
    };
    let account_id = match AccountId::try_from(account_index) {
        Ok(id) => id,
        Err(_) => return json_err("invalid_account", "account_index out of range"),
    };
    let hrp = match network_name {
        "main" | "mainnet" => constants::mainnet::HRP_SAPLING_EXTENDED_SPENDING_KEY,
        "test" | "testnet" => constants::testnet::HRP_SAPLING_EXTENDED_SPENDING_KEY,
        "regtest" => constants::regtest::HRP_SAPLING_EXTENDED_SPENDING_KEY,
        _ => {
            return json_err(
                "unsupported_network",
                "network must be 'main', 'test', or 'regtest'",
            )
        }
    };

    let sk = match derive_sapling_spending_key_str(&seed_bytes, &net, account_id, hrp) {
        Ok(s) => s,
        Err(e) => return json_err("derivation_error", &e),
    };

    json_success(json!({ "sapling_spending_key": sk }))
}

fn derive_sapling_spending_key_str(
    seed: &[u8],
    net: &Network,
    account: AccountId,
    hrp: &str,
) -> Result<String, String> {
    let usk = match net {
        Network::MainNetwork => UnifiedSpendingKey::from_seed(&MainNetwork, seed, account),
        Network::TestNetwork => UnifiedSpendingKey::from_seed(&TestNetwork, seed, account),
    }
    .map_err(|e| format!("key derivation error: {:?}", e))?;
    Ok(encode_extended_spending_key(hrp, usk.sapling()))
}

#[no_mangle]
pub extern "C" fn zcash_ffi_seed_to_transparent_xpub(
    seed_ptr: *const c_char,
    network_ptr: *const c_char,
    account_index: u32,
) -> *mut c_char {
    let seed_hex = match c_str_to_str(seed_ptr) {
        Ok(s) => s,
        Err(FfiStringError::Null) => return json_err("null_pointer", "null seed pointer"),
        Err(FfiStringError::MalformedUtf8) => {
            return json_err("malformed_utf8", "seed is not valid UTF-8")
        }
    };
    let seed_bytes = match hex::decode(seed_hex) {
        Ok(b) => b,
        Err(_) => return json_err("invalid_hex", "seed is not valid hex"),
    };
    if seed_bytes.len() < 32 {
        return json_err("invalid_seed", "seed must be at least 32 bytes");
    }
    let network_label = match c_str_to_str(network_ptr) {
        Ok(s) => s,
        Err(FfiStringError::Null) => return json_err("null_pointer", "null network pointer"),
        Err(FfiStringError::MalformedUtf8) => {
            return json_err("malformed_utf8", "network is not valid UTF-8")
        }
    };
    let net = match parse_network_label(network_label) {
        Some(n) => n,
        None => {
            return json_err(
                "unsupported_network",
                "network must be 'main', 'test', or 'regtest'",
            )
        }
    };
    let account_id = match AccountId::try_from(account_index) {
        Ok(id) => id,
        Err(_) => return json_err("invalid_account", "account_index out of range"),
    };

    let xpub_str = match derive_transparent_xpub(&seed_bytes, &net, account_id, account_index) {
        Ok(s) => s,
        Err(e) => return json_err("derivation_error", &e),
    };

    json_success(json!({ "xpub": xpub_str }))
}

fn derive_transparent_xpub(
    seed: &[u8],
    net: &Network,
    account: AccountId,
    account_index: u32,
) -> Result<String, String> {
    let account_priv_key = match net {
        Network::MainNetwork => AccountPrivKey::from_seed(&MainNetwork, seed, account),
        Network::TestNetwork => AccountPrivKey::from_seed(&TestNetwork, seed, account),
    }
    .map_err(|e| format!("transparent key derivation error: {:?}", e))?;

    let account_pub_key = account_priv_key.to_account_pubkey();
    encode_transparent_xpub(&account_pub_key, net, account_index)
}

fn encode_transparent_xpub(
    account_pub_key: &zcash_transparent::keys::AccountPubKey,
    net: &Network,
    account_index: u32,
) -> Result<String, String> {
    let serialized = account_pub_key.serialize();
    let chain_code = &serialized[..32];
    let pubkey = &serialized[32..];

    // BIP 32 version bytes
    let version: [u8; 4] = match net {
        Network::MainNetwork => [0x04, 0x88, 0xB2, 0x1E],
        Network::TestNetwork => [0x04, 0x35, 0x87, 0xCF],
    };
    let child_number = 0x8000_0000u32 | account_index;

    let mut xpub_bytes: Vec<u8> = Vec::with_capacity(78);
    xpub_bytes.extend_from_slice(&version);
    xpub_bytes.push(3);
    xpub_bytes.extend_from_slice(&[0u8; 4]);
    xpub_bytes.extend_from_slice(&child_number.to_be_bytes());
    xpub_bytes.extend_from_slice(chain_code);
    xpub_bytes.extend_from_slice(pubkey);

    Ok(bs58::encode(xpub_bytes).with_check().into_string())
}

/// Uses the first valid diversifier at or after `diversifier_index`.
#[no_mangle]
pub extern "C" fn zcash_ffi_ufvk_to_address(
    ufvk_ptr: *const c_char,
    network_ptr: *const c_char,
    diversifier_index: u32,
) -> *mut c_char {
    let ufvk_str = match c_str_to_str(ufvk_ptr) {
        Ok(s) => s,
        Err(FfiStringError::Null) => return json_err("null_pointer", "null ufvk pointer"),
        Err(FfiStringError::MalformedUtf8) => {
            return json_err("malformed_utf8", "ufvk is not valid UTF-8")
        }
    };
    let network_label = match c_str_to_str(network_ptr) {
        Ok(s) => s,
        Err(FfiStringError::Null) => return json_err("null_pointer", "null network pointer"),
        Err(FfiStringError::MalformedUtf8) => {
            return json_err("malformed_utf8", "network is not valid UTF-8")
        }
    };
    let network_type = match parse_network_type_label(network_label) {
        Some(n) => n,
        None => {
            return json_err(
                "unsupported_network",
                "network must be 'main', 'test', or 'regtest'",
            )
        }
    };
    let net = match parse_network_label(network_label) {
        Some(n) => n,
        None => {
            return json_err(
                "unsupported_network",
                "network must be 'main', 'test', or 'regtest'",
            )
        }
    };

    let result = match derive_ua_json(ufvk_str, &net, network_type, diversifier_index) {
        Ok(s) => s,
        Err(e) => {
            let category = if e.starts_with("invalid ufvk") {
                "invalid_ufvk"
            } else {
                "derivation_error"
            };
            return json_err(category, &e);
        }
    };
    json_success(result)
}

fn derive_ua_json(
    ufvk_str: &str,
    net: &Network,
    network_type: NetworkType,
    diversifier_index: u32,
) -> Result<Value, String> {
    let ufvk = match net {
        Network::MainNetwork => UnifiedFullViewingKey::decode(&MainNetwork, ufvk_str),
        Network::TestNetwork => UnifiedFullViewingKey::decode(&TestNetwork, ufvk_str),
    }
    .map_err(|e| format!("invalid ufvk: {}", e))?;

    let j = DiversifierIndex::from(diversifier_index);
    let requested_index = u64::from(diversifier_index);
    let (ua, found_index) = ufvk
        .find_address(
            j,
            UnifiedAddressRequest::unsafe_custom(
                ReceiverRequirement::Allow,
                ReceiverRequirement::Require,
                ReceiverRequirement::Allow,
            ),
        )
        .map_err(|e| format!("address generation error: {:?}", e))?;
    let next_valid_index = u64::try_from(found_index)
        .map_err(|_| "valid diversifier index exceeds supported range".to_string())?;

    let ua_str = ua.to_zcash_address(network_type).to_string();

    let sapling_str = ua
        .sapling()
        .map(|pa| ZcashAddress::from_sapling(network_type, pa.to_bytes()).to_string());

    let transparent_str = ua.transparent().map(|ta| match ta {
        TransparentAddress::PublicKeyHash(data) => {
            ZcashAddress::from_transparent_p2pkh(network_type, *data).to_string()
        }
        TransparentAddress::ScriptHash(data) => {
            ZcashAddress::from_transparent_p2sh(network_type, *data).to_string()
        }
    });

    let orchard_str = ua.orchard().and_then(|oa| {
        let orchard_ua = UnifiedAddress::from_receivers(Some(*oa), None, None)?;
        Some(orchard_ua.to_zcash_address(network_type).to_string())
    });

    let receiver_total = usize::from(orchard_str.is_some())
        + usize::from(sapling_str.is_some())
        + usize::from(transparent_str.is_some());

    Ok(json!({
        "ua": ua_str.clone(),
        "sapling": sapling_str.clone(),
        "orchard": orchard_str.clone(),
        "transparent": transparent_str.clone(),
        "address_encoding": network_type_label(network_type),
        "requested_index": requested_index,
        "next_valid_index": next_valid_index,
        "skipped_count": next_valid_index.saturating_sub(requested_index),
        "receiver_presence": {
            "orchard": orchard_str.is_some(),
            "sapling": sapling_str.is_some(),
            "transparent": transparent_str.is_some(),
            "transparent_kind": if transparent_str.is_some() { Some("p2pkh") } else { None },
            "total": receiver_total,
        },
        "addresses": {
            "ua": ua_str,
            "sapling": sapling_str,
            "orchard": orchard_str,
            "transparent": transparent_str,
        },
    }))
}

#[no_mangle]
pub extern "C" fn zcash_ffi_transparent_address(
    xpub_ptr: *const c_char,
    network_ptr: *const c_char,
    child_index: u32,
) -> *mut c_char {
    let xpub_str = match c_str_to_str(xpub_ptr) {
        Ok(s) => s,
        Err(FfiStringError::Null) => return json_err("null_pointer", "null xpub pointer"),
        Err(FfiStringError::MalformedUtf8) => {
            return json_err("malformed_utf8", "xpub is not valid UTF-8")
        }
    };
    let network_label = match c_str_to_str(network_ptr) {
        Ok(s) => s,
        Err(FfiStringError::Null) => return json_err("null_pointer", "null network pointer"),
        Err(FfiStringError::MalformedUtf8) => {
            return json_err("malformed_utf8", "network is not valid UTF-8")
        }
    };
    let net = match parse_network_label(network_label) {
        Some(n) => n,
        None => {
            return json_err(
                "unsupported_network",
                "network must be 'main', 'test', or 'regtest'",
            )
        }
    };
    let child_idx = match NonHardenedChildIndex::from_index(child_index) {
        Some(i) => i,
        None => return json_err("invalid_child_index", "child_index must be < 2^31"),
    };

    let result = match derive_transparent_addr(xpub_str, &net, child_idx) {
        Ok(s) => s,
        Err(e) => return json_err("invalid_xpub", &e),
    };
    json_success(json!({ "address": result }))
}

fn derive_transparent_addr(
    xpub_str: &str,
    net: &Network,
    child_idx: NonHardenedChildIndex,
) -> Result<String, String> {
    let decoded = bs58::decode(xpub_str)
        .with_check(None)
        .into_vec()
        .map_err(|e| format!("invalid xpub encoding: {}", e))?;
    if decoded.len() != 78 {
        return Err(format!("xpub wrong length: {} bytes", decoded.len()));
    }
    // After the version: depth(1) fingerprint(4) child_number(4) chain_code(32)
    // pubkey(33).
    let payload = &decoded[4..];
    let mut key_data = [0u8; 65];
    key_data[..32].copy_from_slice(&payload[9..41]);
    key_data[32..].copy_from_slice(&payload[41..74]);

    let account_pub_key = zcash_transparent::keys::AccountPubKey::deserialize(&key_data)
        .map_err(|e| format!("invalid xpub key data: {:?}", e))?;
    let external_ivk = account_pub_key
        .derive_external_ivk()
        .map_err(|e| format!("external ivk derivation error: {:?}", e))?;
    let addr = external_ivk
        .derive_address(child_idx)
        .map_err(|e| format!("address derivation error: {:?}", e))?;

    let addr_str = match net {
        Network::MainNetwork => Address::Transparent(addr).encode(&MainNetwork),
        Network::TestNetwork => Address::Transparent(addr).encode(&TestNetwork),
    };

    Ok(addr_str)
}

#[no_mangle]
pub extern "C" fn zcash_ffi_decode_transaction(
    tx_hex_ptr: *const c_char,
    network_ptr: *const c_char,
) -> *mut c_char {
    let tx_hex = match c_str_to_str(tx_hex_ptr) {
        Ok(s) => s,
        Err(FfiStringError::Null) => return json_err("null_pointer", "null transaction pointer"),
        Err(FfiStringError::MalformedUtf8) => {
            return json_err("malformed_utf8", "transaction is not valid UTF-8")
        }
    };
    let network_label = match c_str_to_str(network_ptr) {
        Ok(s) => s,
        Err(FfiStringError::Null) => return json_err("null_pointer", "null network pointer"),
        Err(FfiStringError::MalformedUtf8) => {
            return json_err("malformed_utf8", "network is not valid UTF-8")
        }
    };
    let network = match parse_network_type_label(network_label) {
        Some(n) => n,
        None => {
            return json_err(
                "unsupported_network",
                "network must be 'main', 'test', or 'regtest'",
            )
        }
    };

    let bytes = match hex::decode(tx_hex.trim()) {
        Ok(b) => b,
        Err(_) => return json_err("invalid_hex", "transaction is not valid hex"),
    };
    if bytes.is_empty() {
        return json_err("invalid_transaction", "transaction is empty");
    }

    match decode_transaction_json(&bytes, network) {
        Ok(value) => json_success(value),
        Err(()) => json_err("invalid_transaction", "could not decode transaction"),
    }
}

/// `txid` is in display order; `auth_digest` is in internal order, null before v5.
#[no_mangle]
pub extern "C" fn zcash_ffi_transaction_txid(tx_hex_ptr: *const c_char) -> *mut c_char {
    let tx_hex = match c_str_to_str(tx_hex_ptr) {
        Ok(s) => s,
        Err(FfiStringError::Null) => return json_err("null_pointer", "null transaction pointer"),
        Err(FfiStringError::MalformedUtf8) => {
            return json_err("malformed_utf8", "transaction is not valid UTF-8")
        }
    };

    let bytes = match hex::decode(tx_hex.trim()) {
        Ok(b) => b,
        Err(_) => return json_err("invalid_hex", "transaction is not valid hex"),
    };
    if bytes.is_empty() {
        return json_err("invalid_transaction", "transaction is empty");
    }

    match read_full_transaction(&bytes) {
        Ok(tx) => {
            let auth_digest = match tx.version() {
                TxVersion::V5 => Value::from(hex::encode(tx.auth_commitment().as_bytes())),
                _ => Value::Null,
            };
            json_success(json!({
                "txid": tx.txid().to_string(),
                "auth_digest": auth_digest,
            }))
        }
        Err(()) => json_err("invalid_transaction", "could not decode transaction"),
    }
}

fn read_full_transaction(bytes: &[u8]) -> Result<Transaction, ()> {
    let mut cursor = std::io::Cursor::new(bytes);
    let tx = Transaction::read(&mut cursor, BranchId::Nu5).map_err(|_| ())?;
    if cursor.position() as usize != bytes.len() {
        return Err(());
    }
    Ok(tx)
}

fn decode_transaction_json(bytes: &[u8], network: NetworkType) -> Result<Value, ()> {
    let tx = read_full_transaction(bytes)?;

    let transparent = match tx.transparent_bundle() {
        Some(b) => json!({
            "present": true,
            "vin": b.vin.len(),
            "vout": b.vout.len(),
        }),
        None => json!({ "present": false, "vin": 0, "vout": 0 }),
    };
    let sapling = match tx.sapling_bundle() {
        Some(b) => json!({
            "present": true,
            "spends": b.shielded_spends().len(),
            "outputs": b.shielded_outputs().len(),
        }),
        None => json!({ "present": false, "spends": 0, "outputs": 0 }),
    };
    let orchard = match tx.orchard_bundle() {
        Some(b) => json!({
            "present": true,
            "actions": b.actions().len(),
        }),
        None => json!({ "present": false, "actions": 0 }),
    };
    let ironwood = match tx.ironwood_bundle() {
        Some(b) => json!({
            "present": true,
            "actions": b.actions().len(),
        }),
        None => json!({ "present": false, "actions": 0 }),
    };
    let sprout = match tx.sprout_bundle() {
        Some(b) => json!({
            "present": true,
            "joinsplits": b.joinsplits.len(),
        }),
        None => json!({ "present": false, "joinsplits": 0 }),
    };

    // Only v5 and v6 (ZIP 229) serialize the branch id; earlier versions report null.
    let (branch_label, branch_hex) = match tx.version() {
        TxVersion::V5 | TxVersion::V6 => {
            let branch = tx.consensus_branch_id();
            (
                Value::from(branch_id_label(branch)),
                Value::from(format!("{:08x}", u32::from(branch))),
            )
        }
        _ => (Value::Null, Value::Null),
    };

    Ok(json!({
        "network": network_type_label(network),
        "txid": tx.txid().to_string(),
        "version": tx_version_label(tx.version()),
        "header": tx.version().header(),
        "version_group_id": tx.version().version_group_id(),
        "consensus_branch_id": branch_label,
        "consensus_branch_id_hex": branch_hex,
        "lock_time": tx.lock_time(),
        "expiry_height": u32::from(tx.expiry_height()),
        "transparent": transparent,
        "sapling": sapling,
        "orchard": orchard,
        "ironwood": ironwood,
        "sprout": sprout,
    }))
}

fn tx_version_label(version: TxVersion) -> &'static str {
    match version {
        TxVersion::Sprout(_) => "sprout",
        TxVersion::V3 => "v3",
        TxVersion::V4 => "v4",
        TxVersion::V5 => "v5",
        TxVersion::V6 => "v6",
    }
}

fn branch_id_label(branch: BranchId) -> &'static str {
    match branch {
        BranchId::Sprout => "sprout",
        BranchId::Overwinter => "overwinter",
        BranchId::Sapling => "sapling",
        BranchId::Blossom => "blossom",
        BranchId::Heartwood => "heartwood",
        BranchId::Canopy => "canopy",
        BranchId::Nu5 => "nu5",
        BranchId::Nu6 => "nu6",
        BranchId::Nu6_1 => "nu6.1",
        BranchId::Nu6_2 => "nu6.2",
        BranchId::Nu6_3 => "nu6.3",
    }
}

#[cfg(test)]
mod tests;
