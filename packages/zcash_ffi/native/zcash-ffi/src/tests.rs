use super::*;
use std::ffi::CString;

// Project test seed: the 64 bytes 0x00..0x3f; arbitrary.
const TEST_SEED_HEX: &str = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f\
         202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f";

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

fn account_ufvk(network: &CString) -> String {
    let seed = cptr(TEST_SEED_HEX);
    let ufvk_ptr = zcash_ffi_seed_to_account_ufvk(seed.as_ptr(), network.as_ptr(), 0);
    let ufvk_json = result_str(ufvk_ptr);
    serde_json::from_str::<serde_json::Value>(&ufvk_json).unwrap()["ufvk"]
        .as_str()
        .expect("ufvk field missing")
        .to_owned()
}

fn account_metadata_value(seed_hex: &str, network: &CString, account_index: u32) -> Value {
    let seed = cptr(seed_hex);
    result_value(zcash_ffi_seed_to_account_metadata(
        seed.as_ptr(),
        network.as_ptr(),
        account_index,
    ))
}

fn viewing_keys_value(seed_hex: &str, network: &CString, account_index: u32) -> Value {
    let seed = cptr(seed_hex);
    result_value(zcash_ffi_seed_to_viewing_keys(
        seed.as_ptr(),
        network.as_ptr(),
        account_index,
    ))
}

fn ufvk_to_address_value(ufvk: &str, network: &CString, diversifier_index: u32) -> Value {
    let ufvk_c = cptr(ufvk);
    let addr_ptr = zcash_ffi_ufvk_to_address(ufvk_c.as_ptr(), network.as_ptr(), diversifier_index);
    let addr_json = result_str(addr_ptr);
    serde_json::from_str(&addr_json).unwrap()
}

fn decode_address_value(addr: &str, network: &CString) -> Value {
    let addr_c = cptr(addr);
    result_value(zcash_ffi_decode_address(addr_c.as_ptr(), network.as_ptr()))
}

fn unified_address_receivers_value(addr: &str, network: &CString) -> Value {
    let addr_c = cptr(addr);
    result_value(zcash_ffi_unified_address_receivers(
        addr_c.as_ptr(),
        network.as_ptr(),
    ))
}

fn transparent_address_classification_value(addr: &str, network: &CString) -> Value {
    let addr_c = cptr(addr);
    result_value(zcash_ffi_classify_transparent_address(
        addr_c.as_ptr(),
        network.as_ptr(),
    ))
}

fn transparent_script_classification_value(script_hex: &str) -> Value {
    let script_c = cptr(script_hex);
    result_value(zcash_ffi_classify_transparent_script(script_c.as_ptr()))
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
fn seed_to_ufvk_success_uses_versioned_result_envelope() {
    let seed = cptr(TEST_SEED_HEX);
    let net = cptr("test");
    let v = result_value(zcash_ffi_seed_to_account_ufvk(
        seed.as_ptr(),
        net.as_ptr(),
        0,
    ));

    assert_eq!(v[FFI_RESULT_VERSION_KEY], FFI_RESULT_VERSION);
    assert_eq!(v[FFI_RESULT_STATUS_KEY], FFI_RESULT_OK_STATUS);
    assert!(v["ufvk"].as_str().unwrap().starts_with("uviewtest"));
    assert!(v.get("error").is_none(), "success must not include error");
}

#[test]
fn seed_to_ufvk_rejects_null_pointer_with_categorized_error() {
    let net = cptr("test");
    let v = result_value(zcash_ffi_seed_to_account_ufvk(
        std::ptr::null(),
        net.as_ptr(),
        0,
    ));

    assert_eq!(v[FFI_RESULT_VERSION_KEY], FFI_RESULT_VERSION);
    assert_eq!(v[FFI_RESULT_STATUS_KEY], FFI_RESULT_ERROR_STATUS);
    assert_eq!(v["category"], "null_pointer");
    assert_eq!(v["error"], "null seed pointer");
}

#[test]
fn seed_to_ufvk_rejects_malformed_utf8_without_echoing_bytes() {
    let malformed_seed = c"\xff";
    let net = cptr("test");
    let v = result_value(zcash_ffi_seed_to_account_ufvk(
        malformed_seed.as_ptr(),
        net.as_ptr(),
        0,
    ));

    assert_eq!(v[FFI_RESULT_STATUS_KEY], FFI_RESULT_ERROR_STATUS);
    assert_eq!(v["category"], "malformed_utf8");
    assert_eq!(v["error"], "seed is not valid UTF-8");
    assert!(!v.to_string().contains("\\xff"));
}

#[test]
fn seed_to_ufvk_rejects_unsupported_network_with_category() {
    let seed = cptr(TEST_SEED_HEX);
    let net = cptr("devnet");
    let v = result_value(zcash_ffi_seed_to_account_ufvk(
        seed.as_ptr(),
        net.as_ptr(),
        0,
    ));

    assert_eq!(v[FFI_RESULT_STATUS_KEY], FFI_RESULT_ERROR_STATUS);
    assert_eq!(v["category"], "unsupported_network");
    assert_eq!(v["error"], "network must be 'main', 'test', or 'regtest'");
    assert!(!v.to_string().contains(TEST_SEED_HEX));

    let regtest = cptr("regtest");
    let ok = result_value(zcash_ffi_seed_to_account_ufvk(
        seed.as_ptr(),
        regtest.as_ptr(),
        0,
    ));
    assert_eq!(ok[FFI_RESULT_STATUS_KEY], FFI_RESULT_OK_STATUS);
}

#[test]
fn transparent_addr_classification() {
    let addr = cptr("t1c8oqrzA1kYPdgVhfDNUZn3buAbk6rXxiX");
    assert!(zcash_ffi_is_transparent_address(addr.as_ptr()));
    assert!(!zcash_ffi_is_shielded_address(addr.as_ptr()));
    assert_eq!(zcash_ffi_address_type(addr.as_ptr()), ADDR_TYPE_TRANSPARENT);
}

#[test]
fn sapling_addr_classification() {
    let addr =
        cptr("zs1zt3mq96vp65l8ch54r78nc50ml68qsyg3pkteq8pn8sfgzakhgw4vqn6px5w08hrf2uzuam5kmj");
    assert!(!zcash_ffi_is_transparent_address(addr.as_ptr()));
    assert!(zcash_ffi_is_shielded_address(addr.as_ptr()));
    assert_eq!(zcash_ffi_address_type(addr.as_ptr()), ADDR_TYPE_SAPLING);
}

#[test]
fn decode_address_reports_structured_mainnet_transparent_metadata() {
    let main = cptr("main");
    let v = decode_address_value("t1c8oqrzA1kYPdgVhfDNUZn3buAbk6rXxiX", &main);

    assert_eq!(v[FFI_RESULT_STATUS_KEY], FFI_RESULT_OK_STATUS);
    assert_eq!(v["network"], "mainnet");
    assert_eq!(v["receiver_type"], "p2pkh");
    assert_eq!(v["pool"], "transparent");
    assert_eq!(v["receivers"]["transparent"], true);
    assert_eq!(v["receivers"]["transparent_kind"], "p2pkh");
    assert_eq!(v["receivers"]["sapling"], false);
    assert_eq!(v["receivers"]["total"], 1);
}

#[test]
fn decode_address_reports_structured_sapling_and_unified_metadata() {
    let main = cptr("main");
    let sapling = "zs1zt3mq96vp65l8ch54r78nc50ml68qsyg3pkteq8pn8sfgzakhgw4vqn6px5w08hrf2uzuam5kmj";
    let sapling_v = decode_address_value(sapling, &main);
    assert_eq!(sapling_v["network"], "mainnet");
    assert_eq!(sapling_v["receiver_type"], "sapling");
    assert_eq!(sapling_v["pool"], "sapling");
    assert_eq!(sapling_v["receivers"]["sapling"], true);
    assert_eq!(sapling_v["receivers"]["total"], 1);

    let ufvk_str = account_ufvk(&main);
    let ua_value = ufvk_to_address_value(&ufvk_str, &main, 0);
    let ua = ua_value["ua"].as_str().unwrap();
    let ua_v = decode_address_value(ua, &main);
    assert_eq!(ua_v["network"], "mainnet");
    assert_eq!(ua_v["receiver_type"], "unified");
    assert_eq!(ua_v["pool"], "mixed");
    assert_eq!(ua_v["receivers"]["orchard"], true);
    assert_eq!(ua_v["receivers"]["sapling"], true);
    assert_eq!(ua_v["receivers"]["transparent"], true);
    assert_eq!(ua_v["receivers"]["total"], 3);
}

#[test]
fn decode_address_allows_regtest_compatible_transparent_encoding() {
    let seed = cptr(TEST_SEED_HEX);
    let test = cptr("test");
    let regtest = cptr("regtest");
    let xpub_value = result_value(zcash_ffi_seed_to_transparent_xpub(
        seed.as_ptr(),
        test.as_ptr(),
        0,
    ));
    let xpub = cptr(xpub_value["xpub"].as_str().unwrap());
    let addr_value = result_value(zcash_ffi_transparent_address(
        xpub.as_ptr(),
        test.as_ptr(),
        0,
    ));
    let addr = addr_value["address"].as_str().unwrap();
    assert!(addr.starts_with("tm"));

    let decoded = decode_address_value(addr, &regtest);
    assert_eq!(decoded[FFI_RESULT_STATUS_KEY], FFI_RESULT_OK_STATUS);
    assert_eq!(decoded["network"], "regtest");
    assert_eq!(decoded["receiver_type"], "p2pkh");
    assert_eq!(decoded["pool"], "transparent");
}

#[test]
fn decode_address_rejects_wrong_network_and_malformed_without_echo() {
    let test = cptr("test");
    let mainnet_addr = "t1c8oqrzA1kYPdgVhfDNUZn3buAbk6rXxiX";
    let wrong_network = result_str(zcash_ffi_decode_address(
        cptr(mainnet_addr).as_ptr(),
        test.as_ptr(),
    ));
    let wrong_network_value: Value = serde_json::from_str(&wrong_network).unwrap();
    assert_eq!(
        wrong_network_value[FFI_RESULT_STATUS_KEY],
        FFI_RESULT_ERROR_STATUS
    );
    assert_eq!(wrong_network_value["category"], "wrong_network");
    assert!(!wrong_network.contains(mainnet_addr));

    let malformed = "not-a-zcash-address-with-user-input";
    let malformed_json = result_str(zcash_ffi_decode_address(
        cptr(malformed).as_ptr(),
        test.as_ptr(),
    ));
    let malformed_value: Value = serde_json::from_str(&malformed_json).unwrap();
    assert_eq!(
        malformed_value[FFI_RESULT_STATUS_KEY],
        FFI_RESULT_ERROR_STATUS
    );
    assert_eq!(malformed_value["category"], "invalid_address");
    assert!(!malformed_json.contains(malformed));

    let unsupported_network = result_value(zcash_ffi_decode_address(
        cptr(mainnet_addr).as_ptr(),
        cptr("devnet").as_ptr(),
    ));
    assert_eq!(unsupported_network["category"], "unsupported_network");
}

#[test]
fn transparent_classification_reports_p2pkh_and_p2sh_addresses() {
    let main = cptr("main");
    let p2pkh =
        transparent_address_classification_value("t1c8oqrzA1kYPdgVhfDNUZn3buAbk6rXxiX", &main);
    assert_eq!(p2pkh[FFI_RESULT_STATUS_KEY], FFI_RESULT_OK_STATUS);
    assert_eq!(p2pkh["network"], "mainnet");
    assert_eq!(p2pkh["input_type"], "address");
    assert_eq!(p2pkh["kind"], "p2pkh");
    assert_eq!(p2pkh["pool"], "transparent");
    assert_eq!(p2pkh["standard"], true);
    assert_eq!(p2pkh["transparent"], true);
    assert_eq!(p2pkh["script_size"], 25);

    let p2sh_addr = TransparentAddress::ScriptHash([7; 20])
        .to_zcash_address(NetworkType::Main)
        .encode();
    let p2sh = transparent_address_classification_value(&p2sh_addr, &main);
    assert_eq!(p2sh[FFI_RESULT_STATUS_KEY], FFI_RESULT_OK_STATUS);
    assert_eq!(p2sh["network"], "mainnet");
    assert_eq!(p2sh["kind"], "p2sh");
    assert_eq!(p2sh["script_size"], 23);
    assert!(!p2sh.to_string().contains(&p2sh_addr));
}

#[test]
fn transparent_classification_reports_standard_and_nonstandard_scripts() {
    let p2pkh_script = hex::encode(
        TransparentAddress::PublicKeyHash([4; 20])
            .script()
            .to_bytes(),
    );
    let p2pkh = transparent_script_classification_value(&p2pkh_script);
    assert_eq!(p2pkh[FFI_RESULT_STATUS_KEY], FFI_RESULT_OK_STATUS);
    assert_eq!(p2pkh.get("network"), None);
    assert_eq!(p2pkh["input_type"], "script");
    assert_eq!(p2pkh["kind"], "p2pkh");
    assert_eq!(p2pkh["pool"], "transparent");
    assert_eq!(p2pkh["standard"], true);
    assert_eq!(p2pkh["script_size"], 25);
    assert!(!p2pkh.to_string().contains(&p2pkh_script));

    let p2sh_script = hex::encode(TransparentAddress::ScriptHash([7; 20]).script().to_bytes());
    let p2sh = transparent_script_classification_value(&p2sh_script);
    assert_eq!(p2sh["kind"], "p2sh");
    assert_eq!(p2sh["script_size"], 23);

    let non_standard = transparent_script_classification_value("6a");
    assert_eq!(non_standard[FFI_RESULT_STATUS_KEY], FFI_RESULT_OK_STATUS);
    assert_eq!(non_standard["kind"], "non_standard");
    assert_eq!(non_standard["pool"], "unknown");
    assert_eq!(non_standard["standard"], false);
    assert_eq!(non_standard["transparent"], false);
    assert_eq!(non_standard["script_size"], 1);
}

#[test]
fn transparent_classification_rejects_bad_inputs_without_echo() {
    let test = cptr("test");
    let mainnet_addr = "t1c8oqrzA1kYPdgVhfDNUZn3buAbk6rXxiX";
    let wrong_network = result_str(zcash_ffi_classify_transparent_address(
        cptr(mainnet_addr).as_ptr(),
        test.as_ptr(),
    ));
    let wrong_network_value: Value = serde_json::from_str(&wrong_network).unwrap();
    assert_eq!(wrong_network_value["category"], "wrong_network");
    assert!(!wrong_network.contains(mainnet_addr));

    let malformed_addr = "not-a-transparent-address-with-user-input";
    let malformed_addr_json = result_str(zcash_ffi_classify_transparent_address(
        cptr(malformed_addr).as_ptr(),
        test.as_ptr(),
    ));
    let malformed_addr_value: Value = serde_json::from_str(&malformed_addr_json).unwrap();
    assert_eq!(malformed_addr_value["category"], "invalid_address");
    assert!(!malformed_addr_json.contains(malformed_addr));

    let malformed_script = "not-hex-user-input";
    let malformed_script_json = result_str(zcash_ffi_classify_transparent_script(
        cptr(malformed_script).as_ptr(),
    ));
    let malformed_script_value: Value = serde_json::from_str(&malformed_script_json).unwrap();
    assert_eq!(malformed_script_value["category"], "invalid_hex");
    assert!(!malformed_script_json.contains(malformed_script));

    let invalid_script = "14";
    let invalid_script_json = result_str(zcash_ffi_classify_transparent_script(
        cptr(invalid_script).as_ptr(),
    ));
    let invalid_script_value: Value = serde_json::from_str(&invalid_script_json).unwrap();
    assert_eq!(invalid_script_value["category"], "invalid_script");
    assert!(!invalid_script_json.contains(invalid_script));
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

#[test]
fn unified_address_receivers_reports_kinds_and_counts() {
    let main = cptr("main");
    let ufvk_str = account_ufvk(&main);
    let ua_value = ufvk_to_address_value(&ufvk_str, &main, 0);
    let ua = ua_value["ua"].as_str().unwrap();

    let inventory = unified_address_receivers_value(ua, &main);

    assert_eq!(inventory[FFI_RESULT_STATUS_KEY], FFI_RESULT_OK_STATUS);
    assert_eq!(inventory["network"], "mainnet");
    assert_eq!(inventory["address_type"], "unified");
    assert_eq!(inventory["receiver_count"], 3);
    assert_eq!(inventory["counts"]["orchard"], 1);
    assert_eq!(inventory["counts"]["sapling"], 1);
    assert_eq!(inventory["counts"]["transparent"], 1);
    assert_eq!(inventory["counts"]["p2pkh"], 1);
    assert_eq!(inventory["counts"]["p2sh"], 0);
    assert_eq!(inventory["counts"]["unknown"], 0);
    assert_eq!(inventory["counts"]["total"], 3);

    let receivers = inventory["receivers"].as_array().unwrap();
    assert_eq!(receivers.len(), 3);
    for (index, receiver) in receivers.iter().enumerate() {
        assert_eq!(receiver["index"], index);
    }
    let kinds = receivers
        .iter()
        .map(|receiver| receiver["kind"].as_str().unwrap())
        .collect::<Vec<_>>();
    assert!(kinds.contains(&"orchard"));
    assert!(kinds.contains(&"sapling"));
    assert!(kinds.contains(&"p2pkh"));
    assert!(!inventory.to_string().contains(ua));
    assert!(!inventory.to_string().contains(&ufvk_str));
    assert!(!inventory.to_string().contains(TEST_SEED_HEX));
}

#[test]
fn unified_address_receivers_rejects_non_ua_and_bad_inputs_without_echo() {
    let main = cptr("main");
    let test = cptr("test");
    let sapling = "zs1zt3mq96vp65l8ch54r78nc50ml68qsyg3pkteq8pn8sfgzakhgw4vqn6px5w08hrf2uzuam5kmj";
    let non_ua_json = result_str(zcash_ffi_unified_address_receivers(
        cptr(sapling).as_ptr(),
        main.as_ptr(),
    ));
    let non_ua: Value = serde_json::from_str(&non_ua_json).unwrap();
    assert_eq!(non_ua[FFI_RESULT_STATUS_KEY], FFI_RESULT_ERROR_STATUS);
    assert_eq!(non_ua["category"], "not_unified_address");
    assert!(!non_ua_json.contains(sapling));

    let ufvk_str = account_ufvk(&main);
    let ua_value = ufvk_to_address_value(&ufvk_str, &main, 0);
    let ua = ua_value["ua"].as_str().unwrap();
    let wrong_network_json = result_str(zcash_ffi_unified_address_receivers(
        cptr(ua).as_ptr(),
        test.as_ptr(),
    ));
    let wrong_network: Value = serde_json::from_str(&wrong_network_json).unwrap();
    assert_eq!(wrong_network["category"], "wrong_network");
    assert!(!wrong_network_json.contains(ua));
    assert!(!wrong_network_json.contains(&ufvk_str));

    let malformed = "not-a-unified-address-with-user-input";
    let malformed_json = result_str(zcash_ffi_unified_address_receivers(
        cptr(malformed).as_ptr(),
        main.as_ptr(),
    ));
    let malformed_value: Value = serde_json::from_str(&malformed_json).unwrap();
    assert_eq!(malformed_value["category"], "invalid_address");
    assert!(!malformed_json.contains(malformed));

    let bad_network = result_value(zcash_ffi_unified_address_receivers(
        cptr(ua).as_ptr(),
        cptr("devnet").as_ptr(),
    ));
    assert_eq!(bad_network["category"], "unsupported_network");
}

#[test]
fn seed_to_account_metadata_reports_read_only_keys_and_receivers() {
    let main = cptr("main");
    let v = account_metadata_value(TEST_SEED_HEX, &main, 0);

    assert_eq!(v[FFI_RESULT_VERSION_KEY], FFI_RESULT_VERSION);
    assert_eq!(v[FFI_RESULT_STATUS_KEY], FFI_RESULT_OK_STATUS);
    assert_eq!(v["network"], "mainnet");
    assert_eq!(v["account_index"], 0);
    assert!(v["ufvk"].as_str().unwrap().starts_with("uview"));
    assert!(v["transparent_account_xpub"]
        .as_str()
        .unwrap()
        .starts_with("xpub"));
    assert_eq!(v["receivers"]["orchard"], true);
    assert_eq!(v["receivers"]["sapling"], true);
    assert_eq!(v["receivers"]["transparent"], true);
    assert_eq!(v["receivers"]["p2pkh"], true);
    assert_eq!(v["receivers"]["p2sh"], false);
    assert_eq!(v["receivers"]["unknown"], 0);
    assert_eq!(v["receivers"]["total"], 3);

    let receiver_kinds = v["receiver_kinds"]
        .as_array()
        .unwrap()
        .iter()
        .map(|receiver| receiver["kind"].as_str().unwrap())
        .collect::<Vec<_>>();
    assert!(receiver_kinds.contains(&"orchard"));
    assert!(receiver_kinds.contains(&"sapling"));
    assert!(receiver_kinds.contains(&"p2pkh"));
    assert!(!v.to_string().contains(TEST_SEED_HEX));
    assert!(!v.to_string().contains("secret-extended-key"));
}

#[test]
fn seed_to_account_metadata_respects_network_and_account_index() {
    let regtest = cptr("regtest");
    let account0 = account_metadata_value(TEST_SEED_HEX, &regtest, 0);
    let account1 = account_metadata_value(TEST_SEED_HEX, &regtest, 1);

    assert_eq!(account0["network"], "regtest");
    assert_eq!(account0["account_index"], 0);
    assert_eq!(account1["account_index"], 1);
    assert!(account0["ufvk"].as_str().unwrap().starts_with("uviewtest"));
    assert!(account0["transparent_account_xpub"]
        .as_str()
        .unwrap()
        .starts_with("tpub"));
    assert_ne!(account0["ufvk"], account1["ufvk"]);
    assert_ne!(
        account0["transparent_account_xpub"],
        account1["transparent_account_xpub"]
    );
}

#[test]
fn seed_to_account_metadata_rejects_bad_inputs_without_secret_echo() {
    let test = cptr("test");
    let short_seed = "000102";
    let short_json = result_str(zcash_ffi_seed_to_account_metadata(
        cptr(short_seed).as_ptr(),
        test.as_ptr(),
        0,
    ));
    let short_value: Value = serde_json::from_str(&short_json).unwrap();
    assert_eq!(short_value[FFI_RESULT_STATUS_KEY], FFI_RESULT_ERROR_STATUS);
    assert_eq!(short_value["category"], "invalid_seed");
    assert!(!short_json.contains(short_seed));

    let bad_network = "devnet-with-user-input";
    let network_json = result_str(zcash_ffi_seed_to_account_metadata(
        cptr(TEST_SEED_HEX).as_ptr(),
        cptr(bad_network).as_ptr(),
        0,
    ));
    let network_value: Value = serde_json::from_str(&network_json).unwrap();
    assert_eq!(network_value["category"], "unsupported_network");
    assert!(!network_json.contains(TEST_SEED_HEX));
    assert!(!network_json.contains(bad_network));

    let account_json = result_str(zcash_ffi_seed_to_account_metadata(
        cptr(TEST_SEED_HEX).as_ptr(),
        test.as_ptr(),
        1 << 31,
    ));
    let account_value: Value = serde_json::from_str(&account_json).unwrap();
    assert_eq!(account_value["category"], "invalid_account");
    assert!(!account_json.contains(TEST_SEED_HEX));
}

#[test]
fn seed_to_viewing_keys_reports_transparent_and_sapling_metadata() {
    let main = cptr("main");
    let v = viewing_keys_value(TEST_SEED_HEX, &main, 0);

    assert_eq!(v[FFI_RESULT_VERSION_KEY], FFI_RESULT_VERSION);
    assert_eq!(v[FFI_RESULT_STATUS_KEY], FFI_RESULT_OK_STATUS);
    assert_eq!(v["network"], "mainnet");
    assert_eq!(v["account_index"], 0);

    assert_eq!(v["transparent"]["available"], true);
    let external_ivk = v["transparent"]["external_ivk"].as_str().unwrap();
    let internal_ivk = v["transparent"]["internal_ivk"].as_str().unwrap();
    assert_eq!(external_ivk.len(), 130);
    assert_eq!(internal_ivk.len(), 130);
    assert_ne!(external_ivk, internal_ivk);
    assert!(v["transparent"]["default_external_address"]
        .as_str()
        .unwrap()
        .starts_with("t1"));
    assert_eq!(v["transparent"]["default_external_index"], 0);

    assert_eq!(v["sapling"]["available"], true);
    assert!(v["sapling"]["default_address"]
        .as_str()
        .unwrap()
        .starts_with("zs1"));
    assert!(v["sapling"]["default_diversifier_index"].is_number());

    assert_eq!(v["orchard"]["available"], true);

    assert!(!v.to_string().contains(TEST_SEED_HEX));
    assert!(!v.to_string().contains("secret-extended-key"));
}

#[test]
fn seed_to_viewing_keys_respects_network_and_account_index() {
    let test = cptr("test");
    let account0 = viewing_keys_value(TEST_SEED_HEX, &test, 0);
    let account1 = viewing_keys_value(TEST_SEED_HEX, &test, 1);

    assert_eq!(account0["network"], "testnet");
    assert!(account0["transparent"]["default_external_address"]
        .as_str()
        .unwrap()
        .starts_with("tm"));
    assert!(account0["sapling"]["default_address"]
        .as_str()
        .unwrap()
        .starts_with("ztestsapling"));
    assert_ne!(
        account0["transparent"]["external_ivk"],
        account1["transparent"]["external_ivk"]
    );
    assert_ne!(
        account0["sapling"]["default_address"],
        account1["sapling"]["default_address"]
    );

    let regtest = cptr("regtest");
    let regtest_keys = viewing_keys_value(TEST_SEED_HEX, &regtest, 0);
    assert_eq!(regtest_keys["network"], "regtest");
    assert!(regtest_keys["sapling"]["default_address"]
        .as_str()
        .unwrap()
        .starts_with("zregtestsapling"));
}

#[test]
fn seed_to_viewing_keys_rejects_bad_inputs_without_secret_echo() {
    let test = cptr("test");
    let short_seed = "000102";
    let short_json = result_str(zcash_ffi_seed_to_viewing_keys(
        cptr(short_seed).as_ptr(),
        test.as_ptr(),
        0,
    ));
    let short_value: Value = serde_json::from_str(&short_json).unwrap();
    assert_eq!(short_value[FFI_RESULT_STATUS_KEY], FFI_RESULT_ERROR_STATUS);
    assert_eq!(short_value["category"], "invalid_seed");
    assert!(!short_json.contains(short_seed));

    let bad_network = "devnet-with-user-input";
    let network_json = result_str(zcash_ffi_seed_to_viewing_keys(
        cptr(TEST_SEED_HEX).as_ptr(),
        cptr(bad_network).as_ptr(),
        0,
    ));
    let network_value: Value = serde_json::from_str(&network_json).unwrap();
    assert_eq!(network_value["category"], "unsupported_network");
    assert!(!network_json.contains(TEST_SEED_HEX));
    assert!(!network_json.contains(bad_network));

    let account_json = result_str(zcash_ffi_seed_to_viewing_keys(
        cptr(TEST_SEED_HEX).as_ptr(),
        test.as_ptr(),
        1 << 31,
    ));
    let account_value: Value = serde_json::from_str(&account_json).unwrap();
    assert_eq!(account_value["category"], "invalid_account");
    assert!(!account_json.contains(TEST_SEED_HEX));
}

fn validate_key_value(key: &str, network: &CString, key_type: &str) -> Value {
    let key_c = cptr(key);
    let key_type_c = cptr(key_type);
    result_value(zcash_ffi_validate_key(
        key_c.as_ptr(),
        network.as_ptr(),
        key_type_c.as_ptr(),
    ))
}

fn sapling_spending_key(network: &CString) -> String {
    let seed = cptr(TEST_SEED_HEX);
    let ptr = zcash_ffi_seed_to_sapling_spending_key(seed.as_ptr(), network.as_ptr(), 0);
    result_value(ptr)["sapling_spending_key"]
        .as_str()
        .expect("sapling_spending_key field missing")
        .to_owned()
}

fn transparent_xpub(network: &CString) -> String {
    let seed = cptr(TEST_SEED_HEX);
    let ptr = zcash_ffi_seed_to_transparent_xpub(seed.as_ptr(), network.as_ptr(), 0);
    result_value(ptr)["xpub"]
        .as_str()
        .expect("xpub field missing")
        .to_owned()
}

#[allow(deprecated)]
fn sapling_extfvk(hrp: &str) -> String {
    use zcash_keys::encoding::encode_extended_full_viewing_key;
    let seed = hex::decode(TEST_SEED_HEX).unwrap();
    let usk = UnifiedSpendingKey::from_seed(&MainNetwork, &seed, AccountId::ZERO).unwrap();
    let extfvk = usk.sapling().to_extended_full_viewing_key();
    encode_extended_full_viewing_key(hrp, &extfvk)
}

#[test]
fn validate_key_accepts_valid_keys_for_each_type() {
    let main = cptr("main");
    let test = cptr("test");

    let ufvk = account_ufvk(&main);
    let ufvk_v = validate_key_value(&ufvk, &main, "ufvk");
    assert_eq!(ufvk_v[FFI_RESULT_STATUS_KEY], FFI_RESULT_OK_STATUS);
    assert_eq!(ufvk_v["key_type"], "ufvk");
    assert_eq!(ufvk_v["network"], "mainnet");
    assert_eq!(ufvk_v["valid"], true);
    assert_eq!(ufvk_v["components"]["sapling"], true);
    assert_eq!(ufvk_v["components"]["orchard"], true);
    assert_eq!(ufvk_v["components"]["transparent"], true);

    let extsk = sapling_spending_key(&main);
    let extsk_v = validate_key_value(&extsk, &main, "sapling_extended_spending_key");
    assert_eq!(extsk_v["key_type"], "sapling_extended_spending_key");
    assert_eq!(extsk_v["valid"], true);
    assert!(!extsk_v.to_string().contains(&extsk));

    let extfvk = sapling_extfvk(constants::mainnet::HRP_SAPLING_EXTENDED_FULL_VIEWING_KEY);
    let extfvk_v = validate_key_value(&extfvk, &main, "sapling_extended_full_viewing_key");
    assert_eq!(extfvk_v["key_type"], "sapling_extended_full_viewing_key");
    assert_eq!(extfvk_v["valid"], true);

    let xpub = transparent_xpub(&main);
    let xpub_v = validate_key_value(&xpub, &main, "transparent_xpub");
    assert_eq!(xpub_v["key_type"], "transparent_xpub");
    assert_eq!(xpub_v["valid"], true);

    let test_ufvk = account_ufvk(&test);
    assert_eq!(validate_key_value(&test_ufvk, &test, "ufvk")["valid"], true);
}

#[test]
fn validate_key_flags_wrong_network_without_echo() {
    let main = cptr("main");
    let test = cptr("test");

    let main_ufvk = account_ufvk(&main);
    let wrong = validate_key_value(&main_ufvk, &test, "ufvk");
    assert_eq!(wrong["valid"], false);
    assert_eq!(wrong["reason"], "wrong_network");
    assert!(!wrong.to_string().contains(&main_ufvk));

    let main_extsk = sapling_spending_key(&main);
    let wrong_extsk = validate_key_value(&main_extsk, &test, "sapling_extended_spending_key");
    assert_eq!(wrong_extsk["valid"], false);
    assert_eq!(wrong_extsk["reason"], "wrong_network");
    assert!(!wrong_extsk.to_string().contains(&main_extsk));

    let main_xpub = transparent_xpub(&main);
    let wrong_xpub = validate_key_value(&main_xpub, &test, "transparent_xpub");
    assert_eq!(wrong_xpub["valid"], false);
    assert_eq!(wrong_xpub["reason"], "wrong_network");
    assert!(!wrong_xpub.to_string().contains(&main_xpub));
}

#[test]
fn validate_key_rejects_malformed_and_bad_arguments() {
    let main = cptr("main");
    let garbage = "uview-not-a-real-key-with-user-input";

    let invalid = validate_key_value(garbage, &main, "ufvk");
    assert_eq!(invalid[FFI_RESULT_STATUS_KEY], FFI_RESULT_OK_STATUS);
    assert_eq!(invalid["valid"], false);
    assert_eq!(invalid["reason"], "invalid");
    assert!(!invalid.to_string().contains(garbage));

    let bad_xpub = validate_key_value("not-base58-xpub", &main, "transparent_xpub");
    assert_eq!(bad_xpub["valid"], false);
    assert_eq!(bad_xpub["reason"], "invalid");

    let bad_type_json = result_str(zcash_ffi_validate_key(
        cptr("whatever").as_ptr(),
        main.as_ptr(),
        cptr("bogus_key_type").as_ptr(),
    ));
    let bad_type: Value = serde_json::from_str(&bad_type_json).unwrap();
    assert_eq!(bad_type[FFI_RESULT_STATUS_KEY], FFI_RESULT_ERROR_STATUS);
    assert_eq!(bad_type["category"], "unsupported_key_type");

    let bad_network_json = result_str(zcash_ffi_validate_key(
        cptr("whatever").as_ptr(),
        cptr("devnet-user-input").as_ptr(),
        cptr("ufvk").as_ptr(),
    ));
    let bad_network: Value = serde_json::from_str(&bad_network_json).unwrap();
    assert_eq!(bad_network["category"], "unsupported_network");
    assert!(!bad_network_json.contains("devnet-user-input"));
}

#[test]
fn seed_to_ufvk_mainnet() {
    let seed = cptr(TEST_SEED_HEX);
    let net = cptr("main");
    let ptr = zcash_ffi_seed_to_account_ufvk(seed.as_ptr(), net.as_ptr(), 0);
    let json = result_str(ptr);
    assert!(json.contains("\"ufvk\""), "expected ufvk, got: {json}");
    assert!(
        json.contains("uview"),
        "mainnet ufvk should start with uview: {json}"
    );
}

#[test]
fn seed_to_ufvk_testnet() {
    let seed = cptr(TEST_SEED_HEX);
    let net = cptr("test");
    let ptr = zcash_ffi_seed_to_account_ufvk(seed.as_ptr(), net.as_ptr(), 0);
    let json = result_str(ptr);
    assert!(json.contains("\"ufvk\""), "expected ufvk, got: {json}");
    assert!(
        json.contains("uviewtest"),
        "testnet ufvk should contain uviewtest: {json}"
    );
}

#[test]
fn seed_to_sapling_spending_key_regtest() {
    let seed = cptr(TEST_SEED_HEX);
    let net = cptr("regtest");
    let ptr = zcash_ffi_seed_to_sapling_spending_key(seed.as_ptr(), net.as_ptr(), 0);
    let json = result_str(ptr);
    let v: serde_json::Value = serde_json::from_str(&json).unwrap();
    assert!(v.get("error").is_none(), "unexpected error: {json}");
    let sk = v["sapling_spending_key"]
        .as_str()
        .expect("sapling_spending_key missing");
    assert!(
        sk.starts_with("secret-extended-key-regtest"),
        "regtest uses zcashd import key encoding: {sk}"
    );
    assert!(!json.contains(TEST_SEED_HEX));
}

#[test]
fn seed_to_sapling_spending_key_rejects_invalid_inputs() {
    let bad_seed = cptr("000102");
    let test = cptr("test");
    let short_seed_json = result_str(zcash_ffi_seed_to_sapling_spending_key(
        bad_seed.as_ptr(),
        test.as_ptr(),
        0,
    ));
    assert!(short_seed_json.contains("seed must be at least 32 bytes"));
    assert!(!short_seed_json.contains("000102"));

    let seed = cptr(TEST_SEED_HEX);
    let bad_network = cptr("devnet");
    let network_json = result_str(zcash_ffi_seed_to_sapling_spending_key(
        seed.as_ptr(),
        bad_network.as_ptr(),
        0,
    ));
    assert!(network_json.contains("network must be 'main', 'test', or 'regtest'"));
    assert!(!network_json.contains(TEST_SEED_HEX));

    let account_json = result_str(zcash_ffi_seed_to_sapling_spending_key(
        seed.as_ptr(),
        test.as_ptr(),
        1 << 31,
    ));
    assert!(account_json.contains("account_index out of range"));
}

#[test]
fn seed_to_xpub_mainnet() {
    let seed = cptr(TEST_SEED_HEX);
    let net = cptr("main");
    let ptr = zcash_ffi_seed_to_transparent_xpub(seed.as_ptr(), net.as_ptr(), 0);
    let json = result_str(ptr);
    assert!(json.contains("\"xpub\""), "expected xpub, got: {json}");
    assert!(
        json.contains("\"xpub"),
        "mainnet xpub should start with xpub: {json}"
    );
}

#[test]
fn ufvk_to_address_exposes_stable_full_mainnet_receiver_set() {
    let net = cptr("main");
    let ufvk_str = account_ufvk(&net);

    let first = ufvk_to_address_value(&ufvk_str, &net, 0);
    let second = ufvk_to_address_value(&ufvk_str, &net, 0);
    assert_eq!(first, second, "same UFVK/diversifier must be stable");
    assert!(first.get("error").is_none(), "unexpected error: {first}");

    let ua = first["ua"].as_str().expect("ua field missing");
    assert!(
        ua.starts_with('u') && !ua.starts_with("utest"),
        "mainnet UA should use the main unified prefix: {ua}"
    );
    assert_eq!(first["requested_index"], 0);
    assert_eq!(first["next_valid_index"], 0);
    assert_eq!(first["skipped_count"], 0);
    assert_eq!(first["addresses"]["ua"], first["ua"]);
    assert_eq!(first["receiver_presence"]["orchard"], true);
    assert_eq!(first["receiver_presence"]["sapling"], true);
    assert_eq!(first["receiver_presence"]["transparent"], true);
    assert_eq!(first["receiver_presence"]["transparent_kind"], "p2pkh");
    assert_eq!(first["receiver_presence"]["total"], 3);
    let sapling = first["sapling"].as_str().expect("sapling field missing");
    assert!(
        sapling.starts_with("zs"),
        "mainnet Sapling receiver should start with zs: {sapling}"
    );
    let orchard = first["orchard"].as_str().expect("orchard field missing");
    assert!(
        orchard.starts_with('u') && !orchard.starts_with("utest"),
        "Orchard receiver is exposed as a mainnet UA receiver component: {orchard}"
    );
    assert_ne!(
        orchard, ua,
        "Orchard component should be a receiver-specific UA, not the full UA"
    );
    let transparent = first["transparent"]
        .as_str()
        .expect("transparent field missing");
    assert!(
        transparent.starts_with("t1"),
        "mainnet transparent receiver should be p2pkh/t1 encoded: {transparent}"
    );
}

#[test]
fn ufvk_to_address_reports_requested_and_next_valid_index() {
    let net = cptr("main");
    let ufvk_str = account_ufvk(&net);

    let result = ufvk_to_address_value(&ufvk_str, &net, 1);

    assert_eq!(result[FFI_RESULT_STATUS_KEY], FFI_RESULT_OK_STATUS);
    assert_eq!(result["requested_index"], 1);
    assert!(result["next_valid_index"].as_u64().unwrap() >= 1);
    assert_eq!(
        result["skipped_count"].as_u64().unwrap(),
        result["next_valid_index"].as_u64().unwrap() - 1
    );
    assert_eq!(result["addresses"]["ua"], result["ua"]);
    assert_eq!(result["addresses"]["sapling"], result["sapling"]);
    assert_eq!(result["addresses"]["orchard"], result["orchard"]);
    assert_eq!(result["addresses"]["transparent"], result["transparent"]);
    assert!(!result.to_string().contains(&ufvk_str));
    assert!(!result.to_string().contains(TEST_SEED_HEX));
}

#[test]
fn regtest_ufvk_to_address_encodes_every_receiver_for_regtest() {
    let net = cptr("regtest");
    let ufvk_str = account_ufvk(&net);

    let val = ufvk_to_address_value(&ufvk_str, &net, 0);
    assert!(val.get("error").is_none(), "unexpected error: {val}");
    assert_eq!(val["address_encoding"], "regtest");
    let ua = val["ua"].as_str().expect("ua field missing");
    assert!(
        ua.starts_with("uregtest"),
        "regtest UA must use the regtest HRP: {ua}"
    );
    let sapling = val["sapling"].as_str().expect("sapling field missing");
    assert!(
        sapling.starts_with("zregtestsapling"),
        "regtest Sapling receiver should use zcashd regtest HRP: {sapling}"
    );
    let orchard = val["orchard"].as_str().expect("orchard field missing");
    assert!(
        orchard.starts_with("uregtest"),
        "regtest Orchard receiver must use the regtest UA HRP: {orchard}"
    );
    let transparent = val["transparent"]
        .as_str()
        .expect("transparent field missing");
    assert!(
        transparent.starts_with("tm"),
        "regtest transparent receiver shares testnet's p2pkh prefix: {transparent}"
    );

    let test_net = cptr("test");
    let test_val = ufvk_to_address_value(&account_ufvk(&test_net), &test_net, 0);
    assert_eq!(test_val["address_encoding"], "testnet");
    let test_ua = test_val["ua"].as_str().expect("ua field missing");
    assert!(test_ua.starts_with("utest"), "{test_ua}");
    assert_ne!(ua, test_ua);
}

#[test]
fn ufvk_to_address_rejects_malformed_inputs_without_secret_echo() {
    let main = cptr("main");
    let malformed_ufvk = "not-a-valid-ufvk-with-wallet-input";
    let malformed = cptr(malformed_ufvk);
    let malformed_json = result_str(zcash_ffi_ufvk_to_address(
        malformed.as_ptr(),
        main.as_ptr(),
        0,
    ));
    let malformed_value: Value = serde_json::from_str(&malformed_json).unwrap();
    assert!(
        malformed_value["error"].as_str().is_some(),
        "malformed UFVK should return a JSON error: {malformed_json}"
    );
    assert!(!malformed_json.contains(malformed_ufvk));

    let ufvk_str = account_ufvk(&main);
    let ufvk_c = cptr(&ufvk_str);
    let bad_network = cptr("devnet");
    let bad_network_json = result_str(zcash_ffi_ufvk_to_address(
        ufvk_c.as_ptr(),
        bad_network.as_ptr(),
        0,
    ));
    assert!(bad_network_json.contains("network must be 'main', 'test', or 'regtest'"));
    assert!(!bad_network_json.contains(&ufvk_str));
    assert!(!bad_network_json.contains(TEST_SEED_HEX));

    let null_ufvk_json = result_str(zcash_ffi_ufvk_to_address(
        std::ptr::null(),
        main.as_ptr(),
        0,
    ));
    assert!(null_ufvk_json.contains("null ufvk pointer"));
    assert!(!null_ufvk_json.contains(TEST_SEED_HEX));

    let null_network_json = result_str(zcash_ffi_ufvk_to_address(
        ufvk_c.as_ptr(),
        std::ptr::null(),
        0,
    ));
    let null_network_value: Value = serde_json::from_str(&null_network_json).unwrap();
    assert_eq!(null_network_value["status"], "error");
    assert_eq!(null_network_value["category"], "null_pointer");
    assert_eq!(null_network_value["error"], "null network pointer");
    assert!(!null_network_json.contains(&ufvk_str));
}

#[test]
fn equihash_solver_round_trip() {
    let mut header = [0u8; 108];
    for (i, b) in header.iter_mut().enumerate() {
        *b = i as u8;
    }
    let ptr = unsafe { zcash_ffi_solve_equihash(header.as_ptr(), header.len()) };
    let json = result_str(ptr);
    let v: serde_json::Value = serde_json::from_str(&json).unwrap();
    assert!(v.get("error").is_none(), "unexpected error: {json}");

    let nonce_hex = v["nonce"].as_str().expect("nonce missing");
    let sol_hex = v["solution"].as_str().expect("solution missing");
    let nonce = hex::decode(nonce_hex).unwrap();
    let solution = hex::decode(sol_hex).unwrap();
    assert_eq!(nonce.len(), 32);
    assert_eq!(solution.len(), 1344);

    equihash::is_valid_solution(200, 9, &header, &nonce, &solution)
        .expect("returned solution should validate");
}

#[test]
fn transparent_address_from_xpub() {
    let seed = cptr(TEST_SEED_HEX);
    let net = cptr("main");

    let xpub_ptr = zcash_ffi_seed_to_transparent_xpub(seed.as_ptr(), net.as_ptr(), 0);
    let xpub_json = result_str(xpub_ptr);
    let xpub_str: String = serde_json::from_str::<serde_json::Value>(&xpub_json).unwrap()["xpub"]
        .as_str()
        .unwrap()
        .to_owned();

    let xpub_c = cptr(&xpub_str);
    let addr_ptr = zcash_ffi_transparent_address(xpub_c.as_ptr(), net.as_ptr(), 0);
    let addr_json = result_str(addr_ptr);
    let val: serde_json::Value = serde_json::from_str(&addr_json).unwrap();
    assert!(val.get("error").is_none(), "unexpected error: {addr_json}");
    let addr = val["address"].as_str().expect("address field missing");
    assert!(
        addr.starts_with('t'),
        "mainnet transparent address should start with 't': {addr}"
    );
}

fn build_v5_tx_hex(vin: usize, vout: usize) -> (String, String) {
    use zcash_primitives::transaction::{Authorized as TxAuthorized, TransactionData};
    use zcash_protocol::consensus::BlockHeight;
    use zcash_protocol::value::Zatoshis;
    use zcash_transparent::address::Script;
    use zcash_transparent::bundle::{
        Authorized as TransparentAuthorized, Bundle as TransparentBundle, OutPoint, TxIn, TxOut,
    };

    let transparent = if vin == 0 && vout == 0 {
        None
    } else {
        let vins: Vec<TxIn<TransparentAuthorized>> = (0..vin)
            .map(|i| {
                TxIn::<TransparentAuthorized>::from_parts(
                    OutPoint::new([i as u8; 32], i as u32),
                    Script::default(),
                    0xffff_ffff,
                )
            })
            .collect();
        let vouts: Vec<TxOut> = (0..vout)
            .map(|_| TxOut::new(Zatoshis::const_from_u64(1000), Script::default()))
            .collect();
        Some(TransparentBundle {
            vin: vins,
            vout: vouts,
            authorization: TransparentAuthorized,
        })
    };
    let data = TransactionData::<TxAuthorized>::from_parts(
        TxVersion::V5,
        BranchId::Nu5,
        0,
        BlockHeight::from_u32(0),
        transparent,
        None,
        None,
        None,
    );
    let tx = data.freeze().expect("freeze v5 tx");
    let mut bytes = Vec::new();
    tx.write(&mut bytes).expect("write v5 tx");
    (hex::encode(&bytes), tx.txid().to_string())
}

fn build_v4_empty_tx_hex() -> (String, String) {
    use zcash_primitives::transaction::{Authorized as TxAuthorized, TransactionData};
    use zcash_protocol::consensus::BlockHeight;

    let data = TransactionData::<TxAuthorized>::from_parts(
        TxVersion::V4,
        BranchId::Sapling,
        0,
        BlockHeight::from_u32(0),
        None,
        None,
        None,
        None,
    );
    let tx = data.freeze().expect("freeze v4 tx");
    let mut bytes = Vec::new();
    tx.write(&mut bytes).expect("write v4 tx");
    (hex::encode(&bytes), tx.txid().to_string())
}

#[test]
fn decode_transaction_v5_empty() {
    let (tx_hex, txid) = build_v5_tx_hex(0, 0);
    let hex_c = cptr(&tx_hex);
    let net = cptr("main");
    let v = result_value(zcash_ffi_decode_transaction(hex_c.as_ptr(), net.as_ptr()));
    assert_eq!(v["status"], "ok", "unexpected: {v}");
    assert_eq!(v["network"], "mainnet");
    assert_eq!(v["version"], "v5");
    assert_eq!(v["txid"], txid);
    assert_eq!(v["consensus_branch_id"], "nu5");
    // NU5 consensus branch ID (ZIP 252).
    assert_eq!(v["consensus_branch_id_hex"], "c2d6d0b4");
    assert_eq!(v["transparent"]["present"], false);
    assert_eq!(v["sapling"]["present"], false);
    assert_eq!(v["orchard"]["present"], false);
    assert_eq!(v["sprout"]["present"], false);
}

#[test]
fn decode_transaction_v5_transparent_counts() {
    let (tx_hex, txid) = build_v5_tx_hex(1, 2);
    let hex_c = cptr(&tx_hex);
    let net = cptr("test");
    let v = result_value(zcash_ffi_decode_transaction(hex_c.as_ptr(), net.as_ptr()));
    assert_eq!(v["status"], "ok", "unexpected: {v}");
    assert_eq!(v["network"], "testnet");
    assert_eq!(v["version"], "v5");
    assert_eq!(v["txid"], txid);
    assert_eq!(v["transparent"]["present"], true);
    assert_eq!(v["transparent"]["vin"], 1);
    assert_eq!(v["transparent"]["vout"], 2);
}

#[test]
fn decode_transaction_v4_has_null_branch() {
    let (tx_hex, txid) = build_v4_empty_tx_hex();
    let hex_c = cptr(&tx_hex);
    let net = cptr("main");
    let v = result_value(zcash_ffi_decode_transaction(hex_c.as_ptr(), net.as_ptr()));
    assert_eq!(v["status"], "ok", "unexpected: {v}");
    assert_eq!(v["version"], "v4");
    assert_eq!(v["txid"], txid);
    assert!(v["consensus_branch_id"].is_null());
    assert!(v["consensus_branch_id_hex"].is_null());
}

#[test]
fn decode_transaction_rejects_malformed_hex() {
    let bad = cptr("not hex zz");
    let net = cptr("main");
    let v = result_value(zcash_ffi_decode_transaction(bad.as_ptr(), net.as_ptr()));
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "invalid_hex");
    let serialized = v.to_string();
    assert!(
        !serialized.contains("not hex"),
        "raw input must not be echoed: {serialized}"
    );
}

#[test]
fn decode_transaction_rejects_garbage_bytes() {
    let bad = cptr("deadbeef");
    let net = cptr("main");
    let v = result_value(zcash_ffi_decode_transaction(bad.as_ptr(), net.as_ptr()));
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "invalid_transaction");
    assert!(
        !v.to_string().contains("deadbeef"),
        "raw input must not be echoed"
    );
}

#[test]
fn decode_transaction_rejects_trailing_bytes() {
    let (tx_hex, _) = build_v5_tx_hex(0, 0);
    let with_trailing = format!("{tx_hex}00");
    let hex_c = cptr(&with_trailing);
    let net = cptr("main");
    let v = result_value(zcash_ffi_decode_transaction(hex_c.as_ptr(), net.as_ptr()));
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "invalid_transaction");
}

#[test]
fn decode_transaction_rejects_unsupported_network() {
    let (tx_hex, _) = build_v5_tx_hex(0, 0);
    let hex_c = cptr(&tx_hex);
    let net = cptr("bogus");
    let v = result_value(zcash_ffi_decode_transaction(hex_c.as_ptr(), net.as_ptr()));
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "unsupported_network");
}

#[test]
fn decode_transaction_rejects_null_pointer() {
    let net = cptr("main");
    let v = result_value(zcash_ffi_decode_transaction(std::ptr::null(), net.as_ptr()));
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "null_pointer");
}

#[test]
fn transaction_txid_matches_decode_for_v5() {
    let (tx_hex, txid) = build_v5_tx_hex(1, 2);
    let hex_c = cptr(&tx_hex);
    let v = result_value(zcash_ffi_transaction_txid(hex_c.as_ptr()));
    assert_eq!(v["status"], "ok", "unexpected: {v}");
    assert_eq!(v["txid"], txid);
    let auth = v["auth_digest"].as_str().expect("auth_digest for v5");
    assert_eq!(auth.len(), 64, "auth_digest must be 32 bytes hex");
    assert!(hex::decode(auth).is_ok());
}

#[test]
fn transaction_txid_reports_null_auth_digest_for_v4() {
    let (tx_hex, txid) = build_v4_empty_tx_hex();
    let hex_c = cptr(&tx_hex);
    let v = result_value(zcash_ffi_transaction_txid(hex_c.as_ptr()));
    assert_eq!(v["status"], "ok", "unexpected: {v}");
    assert_eq!(v["txid"], txid);
    assert!(v["auth_digest"].is_null());
}

#[test]
fn transaction_txid_rejects_malformed_hex() {
    let bad = cptr("not hex zz");
    let v = result_value(zcash_ffi_transaction_txid(bad.as_ptr()));
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "invalid_hex");
    assert!(!v.to_string().contains("not hex"));
}

#[test]
fn transaction_txid_rejects_garbage_bytes() {
    let bad = cptr("deadbeef");
    let v = result_value(zcash_ffi_transaction_txid(bad.as_ptr()));
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "invalid_transaction");
    assert!(!v.to_string().contains("deadbeef"));
}

#[test]
fn transaction_txid_rejects_null_pointer() {
    let v = result_value(zcash_ffi_transaction_txid(std::ptr::null()));
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "null_pointer");
}
