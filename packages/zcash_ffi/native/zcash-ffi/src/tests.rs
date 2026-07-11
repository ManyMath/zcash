use super::*;
use std::ffi::CString;

fn cptr(s: &str) -> CString {
    CString::new(s).unwrap()
}

fn result_str(ptr: *mut c_char) -> String {
    unsafe {
        let s = std::ffi::CStr::from_ptr(ptr).to_str().unwrap().to_owned();
        zcash_ffi_free_string(ptr);
        s
    }
}

fn result_value(ptr: *mut c_char) -> Value {
    serde_json::from_str(&result_str(ptr)).unwrap()
}

fn network_constants_value(network: &CString) -> Value {
    result_value(zcash_ffi_network_constants(network.as_ptr()))
}

#[test]
fn version_is_semver() {
    let ptr = zcash_ffi_version();
    let v = result_str(ptr);
    assert!(v.contains('.'), "version should be semver: {v}");
}

#[test]
fn free_string_accepts_null_pointer() {
    unsafe {
        zcash_ffi_free_string(std::ptr::null_mut());
    }
}

#[test]
fn network_constants_report_mainnet_static_vectors() {
    let main = cptr("main");
    let constants = network_constants_value(&main);

    assert_eq!(constants[FFI_RESULT_STATUS_KEY], FFI_RESULT_OK_STATUS);
    assert_eq!(constants["network"], "mainnet");
    assert_eq!(constants["network_kind"], "mainnet");
    assert_eq!(constants["coin_type"], 133);
    assert_eq!(constants["zatoshis_per_zec"], 100_000_000u64);
    assert_eq!(constants["max_money_zatoshis"], 2_100_000_000_000_000u64);
    assert_eq!(constants["coinbase_maturity_blocks"], 100);
    assert_eq!(
        constants["address_prefixes"]["sapling_payment_address_hrp"],
        "zs"
    );
    assert_eq!(constants["address_prefixes"]["unified_address_hrp"], "u");
    assert_eq!(
        constants["address_prefixes"]["transparent_pubkey_address_b58_prefix"],
        json!([0x1c, 0xb8])
    );

    let activations = constants["activation_heights"].as_array().unwrap();
    let sapling = activations
        .iter()
        .find(|activation| activation["name"] == "Sapling")
        .expect("Sapling activation missing");
    assert_eq!(sapling["activation_height"], 419_200);
    assert_eq!(sapling["branch_id"], "76b809bb");
    let nu6_1 = activations
        .iter()
        .find(|activation| activation["name"] == "Nu6.1")
        .expect("Nu6.1 activation missing");
    assert_eq!(nu6_1["activation_height"], 3_146_400);
    assert_eq!(nu6_1["branch_id"], "4dec4df0");
}

#[test]
fn network_constants_report_testnet_and_regtest_boundaries() {
    let test = cptr("test");
    let test_constants = network_constants_value(&test);
    assert_eq!(test_constants["network"], "testnet");
    assert_eq!(test_constants["coin_type"], 1);
    assert_eq!(
        test_constants["address_prefixes"]["sapling_payment_address_hrp"],
        "ztestsapling"
    );
    let test_activations = test_constants["activation_heights"].as_array().unwrap();
    let sapling = test_activations
        .iter()
        .find(|activation| activation["name"] == "Sapling")
        .expect("testnet Sapling activation missing");
    assert_eq!(sapling["activation_height"], 280_000);

    let regtest = cptr("regtest");
    let regtest_constants = network_constants_value(&regtest);
    assert_eq!(regtest_constants["network"], "regtest");
    assert_eq!(regtest_constants["coin_type"], 1);
    assert_eq!(
        regtest_constants["address_prefixes"]["sapling_payment_address_hrp"],
        "zregtestsapling"
    );
    assert_eq!(
        regtest_constants["address_prefixes"]["unified_address_hrp"],
        "uregtest"
    );
    assert_eq!(
        regtest_constants["activation_heights"]
            .as_array()
            .unwrap()
            .len(),
        0,
        "regtest activation heights are local-network configuration"
    );
}

#[test]
fn network_constants_rejects_invalid_network_without_echo() {
    let bad_network = "devnet-with-user-input";
    let bad_json = result_str(zcash_ffi_network_constants(cptr(bad_network).as_ptr()));
    let bad: Value = serde_json::from_str(&bad_json).unwrap();
    assert_eq!(bad[FFI_RESULT_STATUS_KEY], FFI_RESULT_ERROR_STATUS);
    assert_eq!(bad["category"], "unsupported_network");
    assert!(!bad_json.contains(bad_network));

    let null_value = result_value(zcash_ffi_network_constants(std::ptr::null()));
    assert_eq!(null_value["category"], "null_pointer");
}
