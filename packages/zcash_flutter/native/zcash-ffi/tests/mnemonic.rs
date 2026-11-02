use std::ffi::{CStr, CString};

use serde_json::Value;
use zcash_ffi::{
    zcash_ffi_free_string, zcash_ffi_mnemonic_from_entropy, zcash_ffi_mnemonic_to_seed,
};

fn take(ptr: *mut std::os::raw::c_char) -> Value {
    let out = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap().to_owned();
    unsafe { zcash_ffi_free_string(ptr) };
    serde_json::from_str(&out).unwrap()
}

fn from_entropy(entropy: &str) -> Value {
    let entropy = CString::new(entropy).unwrap();
    take(zcash_ffi_mnemonic_from_entropy(entropy.as_ptr()))
}

fn to_seed(phrase: &str, passphrase: &str) -> Value {
    let phrase = CString::new(phrase).unwrap();
    let passphrase = CString::new(passphrase).unwrap();
    take(zcash_ffi_mnemonic_to_seed(
        phrase.as_ptr(),
        passphrase.as_ptr(),
    ))
}

fn vectors() -> Vec<Value> {
    // Trezor's python-mnemonic vectors (MIT), from the bip0039 0.13.4 crate.
    serde_json::from_str(include_str!("fixtures/bip39_english_vectors.json")).unwrap()
}

#[test]
fn every_vector_makes_its_phrase_from_its_entropy() {
    let vectors = vectors();
    assert_eq!(vectors.len(), 24);
    for v in vectors {
        let out = from_entropy(v["entropy"].as_str().unwrap());
        assert_eq!(out["status"], "ok", "{out}");
        assert_eq!(out["phrase"], v["mnemonic"]);
    }
}

#[test]
fn every_vector_derives_its_seed_under_its_passphrase() {
    for v in vectors() {
        let out = to_seed(
            v["mnemonic"].as_str().unwrap(),
            v["passphrase"].as_str().unwrap(),
        );
        assert_eq!(out["status"], "ok", "{out}");
        assert_eq!(out["seed"], v["seed"]);
    }
}

#[test]
fn the_passphrase_changes_the_seed() {
    let phrase = vectors()[0]["mnemonic"].as_str().unwrap().to_owned();
    assert_ne!(
        to_seed(&phrase, "")["seed"],
        to_seed(&phrase, "TREZOR")["seed"]
    );
}

#[test]
fn entropy_of_the_wrong_length_is_refused() {
    let out = from_entropy(&"00".repeat(15));
    assert_eq!(out["category"], "invalid_entropy");
}

#[test]
fn a_bad_phrase_is_refused_by_category_without_echoing_it() {
    let good = "legal winner thank year wave sausage worth useful legal winner thank yellow";

    let short = to_seed("legal winner thank", "");
    assert_eq!(short["category"], "invalid_mnemonic_word_count");

    let typo = good.replace("sausage", "sausagf");
    let out = to_seed(&typo, "");
    assert_eq!(out["category"], "invalid_mnemonic_word");
    assert!(!out.to_string().contains("sausag"), "{out}");

    let swapped = good.replace("thank year", "year thank");
    let out = to_seed(&swapped, "");
    assert_eq!(out["category"], "invalid_mnemonic_checksum");
    assert!(!out.to_string().contains("winner"), "{out}");
}
