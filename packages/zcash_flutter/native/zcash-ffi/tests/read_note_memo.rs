use std::ffi::{CStr, CString};
use std::os::raw::c_char;

use serde_json::Value;

// A v6 transaction from this crate's Ironwood builder, paying MEMO and VALUE_ZATOSHIS
// to the TEST_SEED_HEX account.
const TX_HEX: &str = include_str!("fixtures/ironwood_memo_tx.hex");

const MEMO: &[u8] = b"a note for you";
const VALUE_ZATOSHIS: u64 = 58000;

const TEST_SEED_HEX: &str = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f\
202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f";

fn cptr(value: &str) -> CString {
    CString::new(value).expect("no interior nulls")
}

fn result_value(ptr: *mut c_char) -> Value {
    let raw = unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .expect("valid UTF-8")
        .to_owned();
    unsafe { zcash_ffi::zcash_ffi_free_string(ptr) };
    serde_json::from_str(&raw).expect("valid JSON")
}

fn regtest_ufvk() -> String {
    let seed = cptr(TEST_SEED_HEX);
    let network = cptr("regtest");
    let v = result_value(zcash_ffi::zcash_ffi_seed_to_account_ufvk(
        seed.as_ptr(),
        network.as_ptr(),
        0,
    ));
    v["ufvk"].as_str().expect("ufvk field").to_owned()
}

fn read(pool: &str, index: usize, ufvk: &str) -> Value {
    let request = format!(
        r#"{{"memo_read_version":1,"network":"regtest","transaction":"{tx}",
             "pool":"{pool}","output_index":{index},"ufvk":"{ufvk}"}}"#,
        tx = TX_HEX.trim(),
    );
    let c = cptr(&request);
    result_value(zcash_ffi::zcash_ffi_read_note_memo(c.as_ptr()))
}

#[test]
fn the_default_build_reads_an_ironwood_memo() {
    let ufvk = regtest_ufvk();
    let mine: Vec<Value> = (0..6)
        .map(|index| read("ironwood", index, &ufvk))
        .inspect(|v| assert_eq!(v["status"], "ok", "{v}"))
        .filter(|v| v["outcome"] == "decrypted")
        .collect();

    assert_eq!(
        mine.len(),
        1,
        "one action of this transaction is addressed to this account and the \
         padding is not: {mine:?}"
    );
    assert_eq!(mine[0]["memo"], hex::encode(MEMO));
    assert_eq!(mine[0]["is_empty_memo"], false);
    assert_eq!(mine[0]["value_zatoshis"], VALUE_ZATOSHIS);
    assert_eq!(mine[0]["pool"], "ironwood");
    assert!(
        !mine[0].to_string().contains(&ufvk),
        "the answer names the output that was asked about, never the key"
    );
}

#[test]
fn an_ironwood_action_read_as_orchard_finds_nothing() {
    let ufvk = regtest_ufvk();
    for index in 0..6 {
        let v = read("orchard", index, &ufvk);
        assert_eq!(v["status"], "ok", "{v}");
        assert_eq!(v["outcome"], "not_for_this_key");
    }
}

#[test]
fn another_wallets_key_reads_nothing_and_learns_nothing() {
    let seed = cptr(&"7f".repeat(64));
    let network = cptr("regtest");
    let other = result_value(zcash_ffi::zcash_ffi_seed_to_account_ufvk(
        seed.as_ptr(),
        network.as_ptr(),
        0,
    ))["ufvk"]
        .as_str()
        .expect("ufvk field")
        .to_owned();

    for index in 0..6 {
        let v = read("ironwood", index, &other);
        assert_eq!(v["status"], "ok", "{v}");
        assert_eq!(v["outcome"], "not_for_this_key");
        assert!(v["memo"].is_null());
        assert!(v.get("value_zatoshis").is_none());
    }
}
