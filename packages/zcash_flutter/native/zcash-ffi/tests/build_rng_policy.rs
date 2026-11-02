#![cfg(all(
    any(feature = "ironwood-tx-build", feature = "orchard-tx-build"),
    not(feature = "deterministic-build-rng")
))]

use std::ffi::{CStr, CString};

use serde_json::Value;

// A caller `rng_seed` is refused (`rng_seed_not_permitted`) unless the crate is built
// with `deterministic-build-rng`.

fn call(
    f: extern "C" fn(*const std::os::raw::c_char) -> *mut std::os::raw::c_char,
    request: &str,
) -> Value {
    let request = CString::new(request).unwrap();
    let ptr = f(request.as_ptr());
    let out = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap().to_owned();
    unsafe { zcash_ffi::zcash_ffi_free_string(ptr) };
    serde_json::from_str(&out).unwrap()
}

#[test]
#[cfg(feature = "ironwood-tx-build")]
fn ironwood_build_refuses_a_seed_without_the_test_feature() {
    let request = format!(
        r#"{{"ironwood_build_version":1,"network":"regtest","target_height":10,
             "ironwood_tree":"","rng_seed":"{seed}",
             "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,
                         "secret_key":"{sk}"}}],
             "ironwood_output":{{"address":"uregtest1"}}}}"#,
        seed = "0a".repeat(32),
        txid = "22".repeat(32),
        sk = "11".repeat(32),
    );
    let v = call(zcash_ffi::zcash_ffi_build_ironwood_transaction, &request);
    assert_eq!(v["status"], "error", "{v}");
    assert_eq!(v["category"], "rng_seed_not_permitted", "{v}");
}

#[test]
#[cfg(feature = "orchard-tx-build")]
fn orchard_build_refuses_a_seed_without_the_test_feature() {
    let request = format!(
        r#"{{"orchard_build_version":1,"network":"regtest","target_height":10,
             "orchard_tree":"","rng_seed":"{seed}",
             "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,
                         "secret_key":"{sk}"}}],
             "orchard_output":{{"address":"uregtest1"}}}}"#,
        seed = "0a".repeat(32),
        txid = "22".repeat(32),
        sk = "11".repeat(32),
    );
    let v = call(zcash_ffi::zcash_ffi_build_orchard_transaction, &request);
    assert_eq!(v["status"], "error", "{v}");
    assert_eq!(v["category"], "rng_seed_not_permitted", "{v}");
}
