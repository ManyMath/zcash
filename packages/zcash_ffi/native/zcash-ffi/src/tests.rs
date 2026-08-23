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

fn scan_with_payload(network: &CString, payload: &str) -> Value {
    let ufvk = account_ufvk(network);
    let ufvk_c = cptr(&ufvk);
    let payload_c = cptr(payload);
    result_value(zcash_ffi_scan_compact_blocks(
        ufvk_c.as_ptr(),
        network.as_ptr(),
        payload_c.as_ptr(),
    ))
}

#[test]
fn scan_accepts_versioned_envelope_and_legacy_input() {
    let test = cptr("test");

    let legacy = scan_with_payload(&test, r#"{"blocks":[]}"#);
    assert_eq!(legacy[FFI_RESULT_STATUS_KEY], FFI_RESULT_OK_STATUS);
    assert_eq!(legacy["scanned_blocks"], 0);

    let versioned = scan_with_payload(
        &test,
        r#"{"scan_input_version":1,"network":"test","range":{"start":0,"end":100},"blocks":[]}"#,
    );
    assert_eq!(versioned[FFI_RESULT_STATUS_KEY], FFI_RESULT_OK_STATUS);
    assert_eq!(versioned["scanned_blocks"], 0);

    let regtest_label = scan_with_payload(
        &test,
        r#"{"scan_input_version":1,"network":"regtest","blocks":[]}"#,
    );
    assert_eq!(regtest_label[FFI_RESULT_STATUS_KEY], FFI_RESULT_OK_STATUS);
}

#[test]
fn scan_rejects_invalid_versioned_envelopes() {
    let test = cptr("test");

    let bad_version = scan_with_payload(&test, r#"{"scan_input_version":2,"blocks":[]}"#);
    assert_eq!(bad_version[FFI_RESULT_STATUS_KEY], FFI_RESULT_ERROR_STATUS);
    assert_eq!(bad_version["category"], "unsupported_scan_input_version");

    let network_mismatch = scan_with_payload(
        &test,
        r#"{"scan_input_version":1,"network":"main","blocks":[]}"#,
    );
    assert_eq!(network_mismatch["category"], "network_mismatch");

    let bad_range = scan_with_payload(
        &test,
        r#"{"scan_input_version":1,"range":{"start":10,"end":5},"blocks":[]}"#,
    );
    assert_eq!(bad_range["category"], "invalid_range");

    let out_of_range = scan_with_payload(
        &test,
        r#"{"scan_input_version":1,"range":{"start":0,"end":10},"blocks":[{"height":99,"data":"AA=="}]}"#,
    );
    assert_eq!(out_of_range["category"], "height_out_of_range");
    assert_eq!(out_of_range["block_index"], 0);
    assert_eq!(out_of_range["height"], 99);
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
#[cfg(feature = "orchard-tx-build")]
fn regtest_ufvk_to_address_agrees_with_the_orchard_builder_fixture() {
    let net = cptr("regtest");
    let val = ufvk_to_address_value(&account_ufvk(&net), &net, 0);
    assert_eq!(
        val["ua"].as_str().expect("ua field missing"),
        orchard_build::test_regtest_unified_address(&hex::decode(TEST_SEED_HEX).unwrap())
    );
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

// The keys, txids, seeds, rseeds and anchors below are arbitrary.
const BUILD_TEST_SECRET_KEY: &str =
    "1111111111111111111111111111111111111111111111111111111111111111";

fn build_transparent_value(request: &str) -> Value {
    let req = cptr(request);
    result_value(zcash_ffi_build_transparent_transaction(req.as_ptr()))
}

#[test]
#[cfg(not(feature = "transparent-tx-build"))]
fn build_transparent_transaction_disabled_in_default_build() {
    let request = format!(
        r#"{{"transparent_build_version":1,"network":"regtest","target_height":10,
                 "fee_zatoshis":10000,
                 "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}],
                 "outputs":[{{"address":"tmEgiuT","value_zatoshis":90000}}]}}"#,
        txid = "22".repeat(32),
        sk = BUILD_TEST_SECRET_KEY,
    );
    let v = build_transparent_value(&request);
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "experimental_feature_disabled");
    assert!(
        !v.to_string().contains(BUILD_TEST_SECRET_KEY),
        "disabled build must not echo the supplied secret key"
    );
}

#[test]
#[cfg(not(feature = "transparent-tx-build"))]
fn build_transparent_transaction_disabled_rejects_null_pointer() {
    let v = result_value(zcash_ffi_build_transparent_transaction(std::ptr::null()));
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "null_pointer");
}

#[cfg(feature = "transparent-tx-build")]
fn regtest_transparent_address() -> String {
    use secp256k1::{PublicKey, Secp256k1, SecretKey};
    let sk = SecretKey::from_slice(&[0x11u8; 32]).unwrap();
    let secp = Secp256k1::new();
    let pk = PublicKey::from_secret_key(&secp, &sk);
    let addr = TransparentAddress::from_pubkey(&pk);
    Address::Transparent(addr).encode(&transparent_build::regtest_params())
}

#[test]
#[cfg(feature = "transparent-tx-build")]
fn build_transparent_transaction_builds_signed_regtest_vector() {
    let to = regtest_transparent_address();
    let request = format!(
        r#"{{"transparent_build_version":1,"network":"regtest","target_height":10,
                 "fee_zatoshis":10000,
                 "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}],
                 "outputs":[{{"address":"{to}","value_zatoshis":90000}}]}}"#,
        txid = "22".repeat(32),
        sk = BUILD_TEST_SECRET_KEY,
        to = to,
    );
    let v = build_transparent_value(&request);
    assert_eq!(v["status"], "ok", "build should succeed: {v}");
    assert_eq!(v["network"], "regtest");
    assert_eq!(v["version"], "v5");
    assert_eq!(v["fee_zatoshis"], 10000);
    assert_eq!(v["total_input_zatoshis"], 100000);
    assert_eq!(v["total_output_zatoshis"], 90000);
    assert_eq!(v["transparent"]["vin"], 1);
    assert_eq!(v["transparent"]["vout"], 1);

    let tx_hex = v["transaction"].as_str().expect("transaction hex");
    let net = cptr("regtest");
    let decoded = result_value(zcash_ffi_decode_transaction(
        cptr(tx_hex).as_ptr(),
        net.as_ptr(),
    ));
    assert_eq!(decoded["status"], "ok");
    assert_eq!(decoded["version"], "v5");
    assert_eq!(decoded["txid"], v["txid"]);
    assert_eq!(decoded["transparent"]["vin"], 1);
    assert_eq!(decoded["transparent"]["vout"], 1);
    assert_eq!(decoded["sapling"]["present"], false);
    assert_eq!(decoded["orchard"]["present"], false);

    assert!(
        !v.to_string().contains(BUILD_TEST_SECRET_KEY),
        "build output must not echo the signing key"
    );
}

/// ZIP 229 keeps `nConsensusBranchId` in v6's common fields.
#[test]
#[cfg(feature = "transparent-tx-build")]
fn decode_reads_v6_transaction_despite_fixed_branch_id_in_reader() {
    let params = transparent_build::regtest_nu63_params();
    let to = Address::Transparent(TransparentAddress::from_pubkey(&{
        use secp256k1::{PublicKey, Secp256k1, SecretKey};
        let sk = SecretKey::from_slice(&[0x11u8; 32]).unwrap();
        PublicKey::from_secret_key(&Secp256k1::new(), &sk)
    }))
    .encode(&params);

    let inputs = vec![json!({
        "txid": "22".repeat(32),
        "vout": 0,
        "value_zatoshis": 100000u64,
        "secret_key": BUILD_TEST_SECRET_KEY,
    })];
    let outputs = vec![json!({ "address": to, "value_zatoshis": 90000u64 })];

    let built = transparent_build::build_generic(
        params,
        NetworkType::Regtest,
        10,
        10000,
        &inputs,
        &outputs,
    )
    .expect("v6 transparent build should succeed");

    assert_eq!(built["version"], "v6", "expected a v6 build: {built}");

    let tx_hex = built["transaction"].as_str().expect("transaction hex");
    let net = cptr("regtest");
    let decoded = result_value(zcash_ffi_decode_transaction(
        cptr(tx_hex).as_ptr(),
        net.as_ptr(),
    ));

    assert_eq!(decoded["status"], "ok", "v6 decode must succeed: {decoded}");
    assert_eq!(decoded["version"], "v6");
    assert_eq!(decoded["txid"], built["txid"]);
    assert_eq!(decoded["consensus_branch_id"], "nu6.3");
    assert_eq!(decoded["consensus_branch_id_hex"], "37a5165b");
    assert_eq!(decoded["transparent"]["vin"], 1);
    assert_eq!(decoded["transparent"]["vout"], 1);
}

#[test]
#[cfg(feature = "transparent-tx-build")]
fn build_transparent_transaction_is_deterministic() {
    let to = regtest_transparent_address();
    let request = format!(
        r#"{{"transparent_build_version":1,"network":"regtest","target_height":10,
                 "fee_zatoshis":10000,
                 "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}],
                 "outputs":[{{"address":"{to}","value_zatoshis":90000}}]}}"#,
        txid = "22".repeat(32),
        sk = BUILD_TEST_SECRET_KEY,
        to = to,
    );
    let first = build_transparent_value(&request);
    let second = build_transparent_value(&request);
    assert_eq!(first["status"], "ok");
    assert_eq!(
        first["transaction"], second["transaction"],
        "identical requests must yield identical signed transactions"
    );
}

#[test]
#[cfg(feature = "transparent-tx-build")]
fn build_transparent_transaction_rejects_shielded_output_without_echo() {
    let sapling = "zs1zt3mq96vp65l8ch54r78nc50ml68qsyg3pkteq8pn8sfgzakhgw4vqn6px5w08hrf2uzuam5kmj";
    let request = format!(
        r#"{{"transparent_build_version":1,"network":"main","target_height":2500000,
                 "fee_zatoshis":10000,
                 "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}],
                 "outputs":[{{"address":"{to}","value_zatoshis":90000}}]}}"#,
        txid = "22".repeat(32),
        sk = BUILD_TEST_SECRET_KEY,
        to = sapling,
    );
    let v = build_transparent_value(&request);
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "unsupported_shielded_output");
    assert!(
        !v.to_string().contains(BUILD_TEST_SECRET_KEY),
        "shielded rejection must not echo the signing key"
    );
}

#[test]
#[cfg(feature = "transparent-tx-build")]
fn build_transparent_transaction_rejects_unbalanced_inputs() {
    let to = regtest_transparent_address();
    let request = format!(
        r#"{{"transparent_build_version":1,"network":"regtest","target_height":10,
                 "fee_zatoshis":10000,
                 "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}],
                 "outputs":[{{"address":"{to}","value_zatoshis":95000}}]}}"#,
        txid = "22".repeat(32),
        sk = BUILD_TEST_SECRET_KEY,
        to = to,
    );
    let v = build_transparent_value(&request);
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "insufficient_funds");
}

#[test]
#[cfg(feature = "transparent-tx-build")]
fn build_transparent_transaction_rejects_malformed_secret_key_without_echo() {
    let to = regtest_transparent_address();
    let bad_key = "00".repeat(32);
    let request = format!(
        r#"{{"transparent_build_version":1,"network":"regtest","target_height":10,
                 "fee_zatoshis":10000,
                 "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}],
                 "outputs":[{{"address":"{to}","value_zatoshis":90000}}]}}"#,
        txid = "22".repeat(32),
        sk = bad_key,
        to = to,
    );
    let v = build_transparent_value(&request);
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "invalid_secret_key");
    assert!(!v.to_string().contains(&bad_key));
}

#[test]
#[cfg(feature = "transparent-tx-build")]
fn build_transparent_transaction_rejects_unsupported_version_and_bad_json() {
    let v = build_transparent_value(r#"{"transparent_build_version":2}"#);
    assert_eq!(v["category"], "unsupported_transparent_build_version");

    let v = build_transparent_value("not json");
    assert_eq!(v["category"], "invalid_json");

    let v = build_transparent_value(r#"{"network":"regtest"}"#);
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "invalid_request");
}

fn build_orchard_value(request: &str) -> Value {
    let req = cptr(request);
    result_value(zcash_ffi_build_orchard_transaction(req.as_ptr()))
}

#[test]
#[cfg(not(feature = "orchard-tx-build"))]
fn build_orchard_transaction_disabled_in_default_build() {
    let request = format!(
        r#"{{"orchard_build_version":1,"network":"regtest","target_height":10,
                 "orchard_tree":"",
                 "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}],
                 "orchard_output":{{"address":"uregtest1"}}}}"#,
        txid = "22".repeat(32),
        sk = BUILD_TEST_SECRET_KEY,
    );
    let v = build_orchard_value(&request);
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "experimental_feature_disabled");
    assert!(
        !v.to_string().contains(BUILD_TEST_SECRET_KEY),
        "disabled build must not echo the supplied secret key"
    );
}

#[test]
#[cfg(not(feature = "orchard-tx-build"))]
fn build_orchard_transaction_disabled_rejects_null_pointer() {
    let v = result_value(zcash_ffi_build_orchard_transaction(std::ptr::null()));
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "null_pointer");
}

#[cfg(feature = "orchard-tx-build")]
fn orchard_regtest_unified_address() -> String {
    orchard_build::test_regtest_unified_address(&hex::decode(TEST_SEED_HEX).unwrap())
}

#[test]
#[cfg(feature = "orchard-tx-build")]
fn build_orchard_transaction_shields_transparent_input_into_orchard() {
    let to = orchard_regtest_unified_address();
    let (tree_hex, root_hex) = orchard_build::test_tree_fixture(3);
    let request = format!(
        r#"{{"orchard_build_version":1,"network":"regtest","target_height":10,
                 "orchard_tree":"{tree}",
                 "rng_seed":"{seed}",
                 "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}],
                 "orchard_output":{{"address":"{to}"}}}}"#,
        tree = tree_hex,
        seed = "07".repeat(32),
        txid = "22".repeat(32),
        sk = BUILD_TEST_SECRET_KEY,
        to = to,
    );
    let v = build_orchard_value(&request);
    assert_eq!(v["status"], "ok", "build should succeed: {v}");
    assert_eq!(v["network"], "regtest");
    assert_eq!(v["version"], "v5");
    assert_eq!(v["proof_validity"], "real");
    assert_eq!(v["fee_rule"], "zip317");
    assert_eq!(v["rng"], "deterministic");

    assert_eq!(v["orchard_anchor"], root_hex);
    assert_eq!(v["orchard_anchor_source"], "tree");
    assert_eq!(v["orchard_anchor_tree_size"], 3);

    // ZIP 317: 1 transparent input + 2 Orchard actions = 3 logical actions at 5000 zatoshis.
    assert_eq!(v["fee_zatoshis"], 15000);
    assert_eq!(v["total_input_zatoshis"], 100000);
    assert_eq!(v["non_orchard_output_zatoshis"], 0);
    assert_eq!(v["orchard_output_zatoshis"], 85000);
    assert_eq!(v["transparent"]["vin"], 1);
    assert_eq!(v["transparent"]["vout"], 0);
    assert_eq!(v["orchard"]["actions"], 2);

    let tx_hex = v["transaction"].as_str().expect("transaction hex");
    let net = cptr("regtest");
    let decoded = result_value(zcash_ffi_decode_transaction(
        cptr(tx_hex).as_ptr(),
        net.as_ptr(),
    ));
    assert_eq!(decoded["status"], "ok", "v5 decode must succeed: {decoded}");
    assert_eq!(decoded["version"], "v5");
    assert_eq!(decoded["txid"], v["txid"]);
    assert_eq!(
        decoded["consensus_branch_id"], "nu6.2",
        "the setup transaction must be signed under the pre-activation branch"
    );
    assert_eq!(decoded["orchard"]["present"], true);
    assert_eq!(decoded["orchard"]["actions"], 2);
    assert_eq!(decoded["ironwood"]["present"], false);
    assert_eq!(decoded["sapling"]["present"], false);
    assert_eq!(decoded["transparent"]["vin"], 1);

    assert!(
        !v.to_string().contains(BUILD_TEST_SECRET_KEY),
        "build output must not echo the signing key"
    );
}

#[test]
#[cfg(feature = "orchard-tx-build")]
fn build_orchard_transaction_requires_a_supplied_anchor() {
    let to = orchard_regtest_unified_address();
    let (tree_hex, _) = orchard_build::test_tree_fixture(2);
    let request_with = |anchor_fields: &str| {
        format!(
            r#"{{"orchard_build_version":1,"network":"regtest","target_height":10,
                     {anchor}
                     "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}],
                     "orchard_output":{{"address":"{to}"}}}}"#,
            anchor = anchor_fields,
            txid = "22".repeat(32),
            sk = BUILD_TEST_SECRET_KEY,
            to = to,
        )
    };

    let v = build_orchard_value(&request_with(""));
    assert_eq!(v["category"], "missing_orchard_anchor", "{v}");

    let v = build_orchard_value(&request_with(&format!(
        r#""orchard_tree":"{tree_hex}","orchard_anchor":"{anchor}","#,
        anchor = "11".repeat(32),
    )));
    assert_eq!(v["category"], "conflicting_orchard_anchor", "{v}");

    let v = build_orchard_value(&request_with(r#""orchard_tree":"not hex","#));
    assert_eq!(v["category"], "invalid_orchard_tree", "{v}");

    let v = build_orchard_value(&request_with(r#""orchard_tree":"abcdef","#));
    assert_eq!(v["category"], "invalid_orchard_tree", "{v}");

    let v = build_orchard_value(&request_with(&format!(
        r#""orchard_anchor":"{anchor}","#,
        anchor = "ff".repeat(32),
    )));
    assert_eq!(v["category"], "invalid_orchard_anchor", "{v}");

    let v = build_orchard_value(&request_with(r#""orchard_anchor":"0011","#));
    assert_eq!(v["category"], "invalid_orchard_anchor", "{v}");
}

#[test]
#[cfg(feature = "orchard-tx-build")]
fn build_orchard_transaction_accepts_a_declared_empty_tree() {
    let to = orchard_regtest_unified_address();
    let request = format!(
        r#"{{"orchard_build_version":1,"network":"regtest","target_height":10,
                 "orchard_tree":"","rng_seed":"{seed}",
                 "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}],
                 "orchard_output":{{"address":"{to}"}}}}"#,
        seed = "08".repeat(32),
        txid = "22".repeat(32),
        sk = BUILD_TEST_SECRET_KEY,
        to = to,
    );
    let v = build_orchard_value(&request);
    assert_eq!(v["status"], "ok", "{v}");
    assert_eq!(v["orchard_anchor_source"], "tree");
    assert_eq!(v["orchard_anchor_tree_size"], 0);
    assert_eq!(v["orchard"]["actions"], 2);
}

#[test]
#[cfg(feature = "orchard-tx-build")]
fn build_orchard_transaction_refuses_heights_outside_the_pre_activation_window() {
    let request_at = |network: &str, height: u64| {
        format!(
            r#"{{"orchard_build_version":1,"network":"{network}","target_height":{height},
                     "orchard_tree":"",
                     "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}],
                     "orchard_output":{{"address":"{to}"}}}}"#,
            network = network,
            height = height,
            txid = "22".repeat(32),
            sk = BUILD_TEST_SECRET_KEY,
            to = "u1placeholder",
        )
    };

    // Mainnet NU6.2 (3,364,600) and NU6.3 (3,428,143) heights from zcash_protocol.
    let v = build_orchard_value(&request_at("main", 3_428_143));
    assert_eq!(v["category"], "orchard_pool_closed", "{v}");
    let v = build_orchard_value(&request_at("main", 4_000_000));
    assert_eq!(v["category"], "orchard_pool_closed", "{v}");

    let v = build_orchard_value(&request_at("main", 3_364_599));
    assert_eq!(v["category"], "orchard_circuit_pre_nu6_2", "{v}");
    let v = build_orchard_value(&request_at("main", 1_000_000));
    assert_eq!(v["category"], "orchard_circuit_pre_nu6_2", "{v}");

    let v = build_orchard_value(&request_at("main", 3_400_000));
    assert_eq!(
        v["category"], "invalid_output_address",
        "a height inside the window must get past the height checks: {v}"
    );
}

#[test]
#[cfg(feature = "orchard-tx-build")]
fn build_orchard_transaction_pays_transparent_change_with_a_fixed_fee() {
    let to = orchard_regtest_unified_address();
    let change = orchard_build::test_regtest_transparent_address();
    let (tree_hex, _) = orchard_build::test_tree_fixture(1);
    let request = format!(
        r#"{{"orchard_build_version":1,"network":"regtest","target_height":10,
                 "orchard_tree":"{tree}","fee_zatoshis":12000,"rng_seed":"{seed}",
                 "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}],
                 "outputs":[{{"address":"{change}","value_zatoshis":30000}}],
                 "orchard_output":{{"address":"{to}","value_zatoshis":58000}}}}"#,
        tree = tree_hex,
        seed = "09".repeat(32),
        txid = "22".repeat(32),
        sk = BUILD_TEST_SECRET_KEY,
        change = change,
        to = to,
    );
    let v = build_orchard_value(&request);
    assert_eq!(v["status"], "ok", "{v}");
    assert_eq!(v["fee_rule"], "fixed");
    assert_eq!(v["fee_zatoshis"], 12000);
    assert_eq!(v["transparent"]["vout"], 1);
    assert_eq!(v["non_orchard_output_zatoshis"], 30000);
    assert_eq!(v["orchard_output_zatoshis"], 58000);
    assert_eq!(v["orchard"]["actions"], 2);
}

#[test]
#[cfg(feature = "orchard-tx-build")]
fn build_orchard_transaction_rejects_recipients_that_cannot_receive_orchard() {
    let transparent = orchard_build::test_regtest_transparent_address();
    let request_to = |address: &str| {
        format!(
            r#"{{"orchard_build_version":1,"network":"regtest","target_height":10,
                     "orchard_tree":"",
                     "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}],
                     "orchard_output":{{"address":"{to}"}}}}"#,
            txid = "22".repeat(32),
            sk = BUILD_TEST_SECRET_KEY,
            to = address,
        )
    };

    let v = build_orchard_value(&request_to(&transparent));
    assert_eq!(v["category"], "unsupported_orchard_recipient", "{v}");

    let v = build_orchard_value(&request_to("not an address"));
    assert_eq!(v["category"], "invalid_output_address", "{v}");

    let to = orchard_regtest_unified_address();
    let request = format!(
        r#"{{"orchard_build_version":1,"network":"regtest","target_height":10,
                 "orchard_tree":"",
                 "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}],
                 "outputs":[{{"address":"{to}","value_zatoshis":1000}}],
                 "orchard_output":{{"address":"{to}"}}}}"#,
        txid = "22".repeat(32),
        sk = BUILD_TEST_SECRET_KEY,
        to = to,
    );
    let v = build_orchard_value(&request);
    assert_eq!(v["category"], "unsupported_shielded_output", "{v}");
}

#[test]
#[cfg(feature = "orchard-tx-build")]
fn build_orchard_transaction_rejects_malformed_requests_without_echo() {
    let to = orchard_regtest_unified_address();
    let cases: &[(&str, &str)] = &[
        (
            r#"{"orchard_build_version":2,"network":"regtest","target_height":10}"#,
            "unsupported_orchard_build_version",
        ),
        (
            r#"{"orchard_build_version":1,"network":"simnet","target_height":10}"#,
            "unsupported_network",
        ),
        (
            r#"{"orchard_build_version":1,"network":"regtest","target_height":0}"#,
            "invalid_height",
        ),
        ("[]", "invalid_request"),
    ];
    for (request, category) in cases {
        let v = build_orchard_value(request);
        assert_eq!(v["category"], *category, "request {request} -> {v}");
    }

    let request = format!(
        r#"{{"orchard_build_version":1,"network":"regtest","target_height":10,
                 "orchard_tree":"",
                 "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}],
                 "orchard_output":{{"address":"{to}"}}}}"#,
        txid = "22".repeat(32),
        sk = "00".repeat(32),
        to = to,
    );
    let v = build_orchard_value(&request);
    assert_eq!(v["category"], "invalid_secret_key", "{v}");
    assert!(!v.to_string().contains(&"00".repeat(32)));

    let v = result_value(zcash_ffi_build_orchard_transaction(cptr("{").as_ptr()));
    assert_eq!(v["category"], "invalid_json", "{v}");
}

#[test]
#[cfg(feature = "orchard-tx-build")]
fn build_orchard_transaction_is_deterministic_only_with_a_supplied_seed() {
    let to = orchard_regtest_unified_address();
    let request = |seed_field: &str| {
        format!(
            r#"{{"orchard_build_version":1,"network":"regtest","target_height":10,
                     "orchard_tree":"",{seed}
                     "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}],
                     "orchard_output":{{"address":"{to}"}}}}"#,
            seed = seed_field,
            txid = "22".repeat(32),
            sk = BUILD_TEST_SECRET_KEY,
            to = to,
        )
    };
    let seeded = format!(r#""rng_seed":"{}","#, "0a".repeat(32));

    let first = build_orchard_value(&request(&seeded));
    let second = build_orchard_value(&request(&seeded));
    assert_eq!(first["status"], "ok", "{first}");
    assert_eq!(first["transaction"], second["transaction"]);
    assert_eq!(first["rng"], "deterministic");

    let os_first = build_orchard_value(&request(""));
    let os_second = build_orchard_value(&request(""));
    assert_eq!(os_first["status"], "ok", "{os_first}");
    assert_eq!(os_first["rng"], "os");
    assert_ne!(
        os_first["transaction"], os_second["transaction"],
        "the OS RNG must not produce identical transactions"
    );
}

#[test]
#[cfg(feature = "orchard-tx-build")]
fn the_build_test_key_owns_the_live_proof_miner_address() {
    // The Dart live harness mines to this address.
    assert_eq!(
        orchard_build::test_regtest_transparent_address(),
        "tmYjAZFpvdDXTaJrq2WikAntitBNJJo9VSo"
    );
}

/// The Dart live harness uses this UA.
#[test]
#[cfg(feature = "orchard-tx-build")]
fn the_test_seed_owns_the_live_proof_unified_address() {
    assert_eq!(
            orchard_build::test_regtest_unified_address(
                &hex::decode(TEST_SEED_HEX).unwrap()
            ),
            "uregtest1t5ljufrslrjkts4ku72pj7cer8qtck0yzv58jna7pg7ygjm2taexqnvcl8eg28ac6verjfdnsx3p028x2pykav0q2vvp0hu3nk3z72vh2adxjgvp34y47zc2efx98pqvqsp9k30j7cq9vwx09g9ukzfqxzzcm6sm5qt7l0md4t66uj4fxntqk7mlgy4az57rkk6xwu0ag53g5j2h9rz"
        );
}

#[test]
#[cfg(feature = "orchard-tx-build")]
fn build_orchard_transaction_honours_a_staged_regtest_activation_height() {
    let to = orchard_regtest_unified_address();
    let request_at = |height: u64, activation: &str| {
        format!(
            r#"{{"orchard_build_version":1,"network":"regtest","target_height":{height},
                     "orchard_tree":"","rng_seed":"{seed}",{activation}
                     "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}],
                     "orchard_output":{{"address":"{to}"}}}}"#,
            height = height,
            activation = activation,
            seed = "0b".repeat(32),
            txid = "22".repeat(32),
            sk = BUILD_TEST_SECRET_KEY,
            to = to,
        )
    };

    let v = build_orchard_value(&request_at(50, r#""regtest_nu63_activation_height":100,"#));
    assert_eq!(v["status"], "ok", "{v}");
    assert_eq!(v["consensus_branch_id"], "nu6.2");
    assert_eq!(v["version"], "v5");

    let v = build_orchard_value(&request_at(100, r#""regtest_nu63_activation_height":100,"#));
    assert_eq!(v["category"], "orchard_pool_closed", "{v}");
    let v = build_orchard_value(&request_at(101, r#""regtest_nu63_activation_height":100,"#));
    assert_eq!(v["category"], "orchard_pool_closed", "{v}");

    let v = build_orchard_value(&request_at(101, ""));
    assert_eq!(v["status"], "ok", "{v}");
    assert_eq!(v["consensus_branch_id"], "nu6.2");

    let main = format!(
        r#"{{"orchard_build_version":1,"network":"main","target_height":3400000,
                 "orchard_tree":"","regtest_nu63_activation_height":100,
                 "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}],
                 "orchard_output":{{"address":"u1x"}}}}"#,
        txid = "22".repeat(32),
        sk = BUILD_TEST_SECRET_KEY,
    );
    let v = build_orchard_value(&main);
    assert_eq!(v["category"], "unsupported_activation_override", "{v}");
}

fn build_ironwood_value(request: &str) -> Value {
    let req = cptr(request);
    result_value(zcash_ffi_build_ironwood_transaction(req.as_ptr()))
}

#[test]
#[cfg(not(feature = "ironwood-tx-build"))]
fn build_ironwood_transaction_disabled_in_default_build() {
    let request = format!(
        r#"{{"ironwood_build_version":1,"network":"regtest","target_height":10,
                 "ironwood_tree":"",
                 "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}],
                 "ironwood_output":{{"address":"uregtest1"}}}}"#,
        txid = "22".repeat(32),
        sk = BUILD_TEST_SECRET_KEY,
    );
    let v = build_ironwood_value(&request);
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "experimental_feature_disabled");
    assert!(
        !v.to_string().contains(BUILD_TEST_SECRET_KEY),
        "disabled build must not echo the supplied secret key"
    );
}

#[test]
#[cfg(not(feature = "ironwood-tx-build"))]
fn build_ironwood_transaction_disabled_rejects_null_pointer() {
    let v = result_value(zcash_ffi_build_ironwood_transaction(std::ptr::null()));
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "null_pointer");
}

#[cfg(feature = "ironwood-tx-build")]
fn regtest_unified_address() -> String {
    ironwood_build::test_regtest_unified_address(&hex::decode(TEST_SEED_HEX).unwrap())
}

#[test]
#[cfg(feature = "ironwood-tx-build")]
fn build_ironwood_transaction_shields_transparent_input_into_ironwood() {
    let to = regtest_unified_address();
    let (tree_hex, root_hex) = ironwood_build::test_tree_fixture(3);
    let request = format!(
        r#"{{"ironwood_build_version":1,"network":"regtest","target_height":10,
                 "ironwood_tree":"{tree}",
                 "rng_seed":"{seed}",
                 "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}],
                 "ironwood_output":{{"address":"{to}"}}}}"#,
        tree = tree_hex,
        seed = "05".repeat(32),
        txid = "22".repeat(32),
        sk = BUILD_TEST_SECRET_KEY,
        to = to,
    );
    let v = build_ironwood_value(&request);
    assert_eq!(v["status"], "ok", "build should succeed: {v}");
    assert_eq!(v["network"], "regtest");
    assert_eq!(v["version"], "v6");
    assert_eq!(v["proof_validity"], "real");
    assert_eq!(v["fee_rule"], "zip317");
    assert_eq!(v["rng"], "deterministic");

    assert_eq!(v["ironwood_anchor"], root_hex);
    assert_eq!(v["ironwood_anchor_source"], "tree");
    assert_eq!(v["ironwood_anchor_tree_size"], 3);

    // ZIP 317 Revision 1: 1 transparent input + 2 Ironwood actions = 3 logical actions at 5000.
    assert_eq!(v["fee_zatoshis"], 15000);
    assert_eq!(v["total_input_zatoshis"], 100000);
    assert_eq!(v["non_ironwood_output_zatoshis"], 0);
    assert_eq!(v["ironwood_output_zatoshis"], 85000);
    assert_eq!(v["transparent"]["vin"], 1);
    assert_eq!(v["transparent"]["vout"], 0);
    assert_eq!(v["ironwood"]["actions"], 2);

    let tx_hex = v["transaction"].as_str().expect("transaction hex");
    let net = cptr("regtest");
    let decoded = result_value(zcash_ffi_decode_transaction(
        cptr(tx_hex).as_ptr(),
        net.as_ptr(),
    ));
    assert_eq!(decoded["status"], "ok", "v6 decode must succeed: {decoded}");
    assert_eq!(decoded["version"], "v6");
    assert_eq!(decoded["txid"], v["txid"]);
    assert_eq!(decoded["consensus_branch_id"], "nu6.3");
    assert_eq!(decoded["ironwood"]["present"], true);
    assert_eq!(decoded["ironwood"]["actions"], 2);
    assert_eq!(decoded["orchard"]["present"], false);
    assert_eq!(decoded["sapling"]["present"], false);
    assert_eq!(decoded["transparent"]["vin"], 1);

    assert!(
        !v.to_string().contains(BUILD_TEST_SECRET_KEY),
        "build output must not echo the signing key"
    );
}

#[test]
#[cfg(feature = "ironwood-tx-build")]
fn ironwood_fee_quote_equals_the_fee_the_build_charges() {
    let to = regtest_unified_address();
    let (tree_hex, _) = ironwood_build::test_tree_fixture(3);

    let shapes: [(&str, &str); 3] = [
        (
            "one transparent input",
            &format!(
                r#""inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}]"#,
                txid = "22".repeat(32),
                sk = BUILD_TEST_SECRET_KEY,
            ),
        ),
        (
            "two transparent inputs",
            &format!(
                r#""inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}},
                                 {{"txid":"{txid2}","vout":1,"value_zatoshis":70000,"secret_key":"{sk}"}}]"#,
                txid = "22".repeat(32),
                txid2 = "33".repeat(32),
                sk = BUILD_TEST_SECRET_KEY,
            ),
        ),
        (
            "two inputs and a transparent output",
            &format!(
                r#""inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}},
                                 {{"txid":"{txid2}","vout":1,"value_zatoshis":70000,"secret_key":"{sk}"}}],
                       "outputs":[{{"address":"{change}","value_zatoshis":10000}}]"#,
                txid = "22".repeat(32),
                txid2 = "33".repeat(32),
                sk = BUILD_TEST_SECRET_KEY,
                change = ironwood_build::test_regtest_transparent_address(),
            ),
        ),
    ];

    let mut fees = Vec::new();
    for (label, shape) in shapes {
        let request = |quote: bool| {
            format!(
                r#"{{"ironwood_build_version":1,"network":"regtest","target_height":10,
                         "ironwood_tree":"{tree}","rng_seed":"{seed}",{quote}
                         {shape},
                         "ironwood_output":{{"address":"{to}"}}}}"#,
                tree = tree_hex,
                seed = "05".repeat(32),
                quote = if quote { r#""quote_only":true,"# } else { "" },
                shape = shape,
                to = to,
            )
        };

        let quoted = build_ironwood_value(&request(true));
        assert_eq!(quoted["status"], "ok", "{label} quote failed: {quoted}");
        let built = build_ironwood_value(&request(false));
        assert_eq!(built["status"], "ok", "{label} build failed: {built}");

        assert_eq!(
            quoted["fee_zatoshis"], built["fee_zatoshis"],
            "{label}: the quote must be the fee the build charges"
        );
        assert_eq!(quoted["fee_rule"], built["fee_rule"]);
        assert_eq!(quoted["consensus_branch_id"], built["consensus_branch_id"]);
        assert_eq!(
            quoted["max_ironwood_output_zatoshis"], built["ironwood_output_zatoshis"],
            "{label}: the quoted maximum is what the build actually paid"
        );
        fees.push(quoted["fee_zatoshis"].as_u64().expect("fee"));

        assert_eq!(quoted["quote_only"], true);
        assert!(quoted.get("transaction").is_none(), "{label}: {quoted}");
        assert!(quoted.get("txid").is_none(), "{label}: {quoted}");
        assert!(
            !quoted.to_string().contains(BUILD_TEST_SECRET_KEY),
            "{label}: a quote must not echo the signing key"
        );
    }

    assert!(
        fees.iter().collect::<std::collections::HashSet<_>>().len() > 1,
        "expected the shapes to differ in fee, got {fees:?}"
    );
}

#[test]
#[cfg(feature = "ironwood-tx-build")]
fn ironwood_fee_quote_reports_a_shortfall_rather_than_refusing() {
    let to = regtest_unified_address();
    let (tree_hex, _) = ironwood_build::test_tree_fixture(3);
    let request = |quote: bool| {
        format!(
            r#"{{"ironwood_build_version":1,"network":"regtest","target_height":10,
                     "ironwood_tree":"{tree}","rng_seed":"{seed}",{quote}
                     "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":1000,"secret_key":"{sk}"}}],
                     "ironwood_output":{{"address":"{to}"}}}}"#,
            tree = tree_hex,
            seed = "05".repeat(32),
            quote = if quote { r#""quote_only":true,"# } else { "" },
            txid = "22".repeat(32),
            sk = BUILD_TEST_SECRET_KEY,
            to = to,
        )
    };

    let quoted = build_ironwood_value(&request(true));
    assert_eq!(quoted["status"], "ok", "a shortfall is not a failed quote");
    assert_eq!(quoted["fee_zatoshis"], 15000);
    assert_eq!(quoted["total_input_zatoshis"], 1000);
    assert!(
        quoted["max_ironwood_output_zatoshis"].is_null(),
        "1000 zatoshis cannot cover a 15000 fee: {quoted}"
    );

    let built = build_ironwood_value(&request(false));
    assert_eq!(built["status"], "error");
    assert_eq!(built["category"], "insufficient_funds");
}

#[test]
#[cfg(feature = "ironwood-tx-build")]
fn build_ironwood_transaction_requires_a_supplied_anchor() {
    let to = regtest_unified_address();
    let (tree_hex, _) = ironwood_build::test_tree_fixture(2);
    let request_with = |anchor_fields: &str| {
        format!(
            r#"{{"ironwood_build_version":1,"network":"regtest","target_height":10,
                     {anchor}
                     "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}],
                     "ironwood_output":{{"address":"{to}"}}}}"#,
            anchor = anchor_fields,
            txid = "22".repeat(32),
            sk = BUILD_TEST_SECRET_KEY,
            to = to,
        )
    };

    let v = build_ironwood_value(&request_with(""));
    assert_eq!(v["category"], "missing_ironwood_anchor", "{v}");

    let v = build_ironwood_value(&request_with(&format!(
        r#""ironwood_tree":"{tree_hex}","ironwood_anchor":"{anchor}","#,
        anchor = "11".repeat(32),
    )));
    assert_eq!(v["category"], "conflicting_ironwood_anchor", "{v}");

    let v = build_ironwood_value(&request_with(r#""ironwood_tree":"not hex","#));
    assert_eq!(v["category"], "invalid_ironwood_tree", "{v}");

    let v = build_ironwood_value(&request_with(r#""ironwood_tree":"abcdef","#));
    assert_eq!(v["category"], "invalid_ironwood_tree", "{v}");

    let v = build_ironwood_value(&request_with(&format!(
        r#""ironwood_anchor":"{anchor}","#,
        anchor = "ff".repeat(32),
    )));
    assert_eq!(v["category"], "invalid_ironwood_anchor", "{v}");

    let v = build_ironwood_value(&request_with(r#""ironwood_anchor":"0011","#));
    assert_eq!(v["category"], "invalid_ironwood_anchor", "{v}");
}

#[test]
#[cfg(feature = "ironwood-tx-build")]
fn build_ironwood_transaction_accepts_a_declared_empty_tree() {
    let to = regtest_unified_address();
    let request = format!(
        r#"{{"ironwood_build_version":1,"network":"regtest","target_height":10,
                 "ironwood_tree":"","rng_seed":"{seed}",
                 "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}],
                 "ironwood_output":{{"address":"{to}"}}}}"#,
        seed = "06".repeat(32),
        txid = "22".repeat(32),
        sk = BUILD_TEST_SECRET_KEY,
        to = to,
    );
    let v = build_ironwood_value(&request);
    assert_eq!(v["status"], "ok", "{v}");
    assert_eq!(v["ironwood_anchor_source"], "tree");
    assert_eq!(v["ironwood_anchor_tree_size"], 0);
    assert_eq!(v["ironwood"]["actions"], 2);
}

fn read_memo_value(request: &str) -> Value {
    let c = cptr(request);
    result_value(zcash_ffi_read_note_memo(c.as_ptr()))
}

#[test]
fn read_note_memo_refuses_an_unknown_envelope_version() {
    let ufvk = account_ufvk(&cptr("regtest"));
    let (tx_hex, _) = build_v5_tx_hex(1, 1);
    let v = read_memo_value(&format!(
        r#"{{"memo_read_version":999,"network":"regtest","transaction":"{tx_hex}",
                 "pool":"sapling","output_index":0,"ufvk":"{ufvk}"}}"#
    ));
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "unsupported_memo_read_version");
}

#[test]
fn read_note_memo_refuses_an_unknown_pool_without_echoing_it() {
    let ufvk = account_ufvk(&cptr("regtest"));
    let (tx_hex, _) = build_v5_tx_hex(1, 1);
    let v = read_memo_value(&format!(
        r#"{{"memo_read_version":1,"network":"regtest","transaction":"{tx_hex}",
                 "pool":"sprout","output_index":0,"ufvk":"{ufvk}"}}"#
    ));
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "invalid_pool");
    assert!(
        !v.to_string().contains("sprout"),
        "a failure path reports what was expected, not what it was handed"
    );
}

#[test]
fn read_note_memo_refuses_a_malformed_transaction() {
    let ufvk = account_ufvk(&cptr("regtest"));
    let v = read_memo_value(&format!(
        r#"{{"memo_read_version":1,"network":"regtest","transaction":"zz",
                 "pool":"sapling","output_index":0,"ufvk":"{ufvk}"}}"#
    ));
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "invalid_transaction");
}

#[test]
fn read_note_memo_never_echoes_the_viewing_key() {
    let ufvk = account_ufvk(&cptr("regtest"));
    let (tx_hex, _) = build_v5_tx_hex(1, 1);
    let refused = read_memo_value(&format!(
        r#"{{"memo_read_version":1,"network":"regtest","transaction":"nothex",
                 "pool":"sapling","output_index":0,"ufvk":"{ufvk}"}}"#
    ));
    assert!(!refused.to_string().contains(&ufvk));

    let ok = read_memo_value(&format!(
        r#"{{"memo_read_version":1,"network":"regtest","transaction":"{tx_hex}",
                 "pool":"sapling","output_index":0,"ufvk":"{ufvk}"}}"#
    ));
    assert!(!ok.to_string().contains(&ufvk));
}

#[test]
fn read_note_memo_reports_not_for_this_key_rather_than_an_error() {
    let ufvk = account_ufvk(&cptr("regtest"));
    let (tx_hex, _) = build_v5_tx_hex(1, 1);
    for pool in ["sapling", "orchard", "ironwood"] {
        let v = read_memo_value(&format!(
            r#"{{"memo_read_version":1,"network":"regtest","transaction":"{tx_hex}",
                     "pool":"{pool}","output_index":0,"ufvk":"{ufvk}"}}"#
        ));
        assert_eq!(v["status"], "ok", "{v}");
        assert_eq!(v["outcome"], "not_for_this_key");
        assert_eq!(v["pool"], pool);
        assert!(v["memo"].is_null());
        assert!(
            v.get("value_zatoshis").is_none(),
            "a note that was not decrypted has no value to report"
        );
    }
}

#[test]
fn read_note_memo_refuses_an_invalid_ufvk() {
    let (tx_hex, _) = build_v5_tx_hex(1, 1);
    let v = read_memo_value(&format!(
        r#"{{"memo_read_version":1,"network":"regtest","transaction":"{tx_hex}",
                 "pool":"sapling","output_index":0,"ufvk":"uview1notakey"}}"#
    ));
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "invalid_ufvk");
}

#[cfg(feature = "ironwood-tx-build")]
fn ironwood_tx_with_memo(memo_field: &str) -> String {
    let to = regtest_unified_address();
    let change = ironwood_build::test_regtest_transparent_address();
    let (tree_hex, _) = ironwood_build::test_tree_fixture(1);
    let request = format!(
        r#"{{"ironwood_build_version":1,"network":"regtest","target_height":10,
                 "ironwood_tree":"{tree}","fee_zatoshis":12000,
                 "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}],
                 "outputs":[{{"address":"{change}","value_zatoshis":30000}}],
                 "ironwood_output":{{"address":"{to}","value_zatoshis":58000{memo}}}}}"#,
        tree = tree_hex,
        txid = "22".repeat(32),
        sk = BUILD_TEST_SECRET_KEY,
        change = change,
        to = to,
        memo = memo_field,
    );
    let v = build_ironwood_value(&request);
    assert_eq!(v["status"], "ok", "{v}");
    v["transaction"]
        .as_str()
        .expect("transaction hex")
        .to_owned()
}

#[cfg(any(
    feature = "ironwood-tx-build",
    feature = "orchard-tx-build",
    feature = "sapling-spend-build"
))]
fn decrypted_memos(pool: &str, tx_hex: &str, ufvk: &str, upto: usize, extra: &str) -> Vec<Value> {
    (0..upto)
        .map(|index| {
            read_memo_value(&format!(
                r#"{{"memo_read_version":1,"network":"regtest","transaction":"{tx_hex}",
                         "pool":"{pool}","output_index":{index},"ufvk":"{ufvk}"{extra}}}"#
            ))
        })
        .inspect(|v| assert_eq!(v["status"], "ok", "{v}"))
        .filter(|v| v["outcome"] == "decrypted")
        .collect()
}

#[cfg(feature = "ironwood-tx-build")]
fn ironwood_memos(tx_hex: &str, ufvk: &str) -> Vec<Value> {
    decrypted_memos("ironwood", tx_hex, ufvk, 6, "")
}

#[test]
#[cfg(feature = "ironwood-tx-build")]
fn a_memo_this_repo_wrote_is_a_memo_this_repo_can_read() {
    let memo = b"a note for you";
    let tx_hex = ironwood_tx_with_memo(&format!(r#","memo":"{}""#, hex::encode(memo)));
    let ufvk = account_ufvk(&cptr("regtest"));

    let mine = ironwood_memos(&tx_hex, &ufvk);
    assert_eq!(
        mine.len(),
        1,
        "one action of this transaction is addressed to this account, and \
             the padding is not: {mine:?}"
    );
    assert_eq!(mine[0]["memo"], hex::encode(memo));
    assert_eq!(mine[0]["is_empty_memo"], false);
    assert_eq!(mine[0]["value_zatoshis"], 58000);
    assert_eq!(mine[0]["pool"], "ironwood");
    assert!(
        !mine[0].to_string().contains(&ufvk),
        "the answer names the output that was asked about, never the key"
    );
}

#[test]
#[cfg(feature = "ironwood-tx-build")]
fn the_empty_memo_reads_as_no_memo() {
    let tx_hex = ironwood_tx_with_memo("");
    let ufvk = account_ufvk(&cptr("regtest"));

    let mine = ironwood_memos(&tx_hex, &ufvk);
    assert_eq!(mine.len(), 1);
    assert_eq!(mine[0]["is_empty_memo"], true);
    assert!(mine[0]["memo"].is_null());
    assert_eq!(mine[0]["value_zatoshis"], 58000);
}

#[test]
#[cfg(feature = "orchard-tx-build")]
fn an_orchard_memo_this_repo_wrote_is_read_back() {
    let memo = b"an orchard note";
    let to = orchard_regtest_unified_address();
    let change = orchard_build::test_regtest_transparent_address();
    let (tree_hex, _) = orchard_build::test_tree_fixture(1);
    let request = format!(
        r#"{{"orchard_build_version":1,"network":"regtest","target_height":10,
                 "orchard_tree":"{tree}","fee_zatoshis":12000,"rng_seed":"{seed}",
                 "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}],
                 "outputs":[{{"address":"{change}","value_zatoshis":30000}}],
                 "orchard_output":{{"address":"{to}","value_zatoshis":58000,"memo":"{memo}"}}}}"#,
        tree = tree_hex,
        seed = "09".repeat(32),
        txid = "22".repeat(32),
        sk = BUILD_TEST_SECRET_KEY,
        change = change,
        to = to,
        memo = hex::encode(memo),
    );
    let v = build_orchard_value(&request);
    assert_eq!(v["status"], "ok", "{v}");
    let tx_hex = v["transaction"].as_str().expect("transaction hex");

    let ufvk = account_ufvk(&cptr("regtest"));
    let mine = decrypted_memos("orchard", tx_hex, &ufvk, 6, "");
    assert_eq!(
        mine.len(),
        1,
        "one action is addressed to this account and the padding is not: \
             {mine:?}"
    );
    assert_eq!(mine[0]["memo"], hex::encode(memo));
    assert_eq!(mine[0]["is_empty_memo"], false);
    assert_eq!(mine[0]["value_zatoshis"], 58000);
    assert_eq!(mine[0]["pool"], "orchard");
    assert!(!mine[0].to_string().contains(&ufvk));

    assert!(decrypted_memos("ironwood", tx_hex, &ufvk, 6, "").is_empty());
}

#[test]
#[cfg(feature = "sapling-spend-build")]
fn a_sapling_memo_this_repo_wrote_is_read_back() {
    let memo = b"a sapling note";
    let to = regtest_sapling_address();
    let request = format!(
        r#"{{"sapling_build_version":1,"network":"regtest","target_height":140,
                 "regtest_nu63_activation_height":130,
                 "fee_zatoshis":15000,"seed":"{seed}","account":0,
                 "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,
                   "secret_key":"{sk}"}}],
                 "outputs":[{{"address":"{to}","value_zatoshis":85000,"memo":"{memo}"}}]}}"#,
        seed = TEST_SEED_HEX,
        txid = "33".repeat(32),
        sk = BUILD_TEST_SECRET_KEY,
        to = to,
        memo = hex::encode(memo),
    );
    let v = build_sapling_value(&request);
    assert_eq!(v["status"], "ok", "{v}");
    let tx_hex = v["transaction"].as_str().expect("transaction hex");

    let ufvk = account_ufvk(&cptr("regtest"));
    let extra = r#","mined_height":140,"regtest_nu63_activation_height":130"#;
    let mine = decrypted_memos("sapling", tx_hex, &ufvk, 4, extra);
    assert_eq!(
        mine.len(),
        1,
        "one output is this account's; the bundle's padding output is a \
             dummy addressed to nobody: {mine:?}"
    );
    assert_eq!(mine[0]["memo"], hex::encode(memo));
    assert_eq!(mine[0]["is_empty_memo"], false);
    assert_eq!(mine[0]["value_zatoshis"], 85000);
    assert_eq!(mine[0]["pool"], "sapling");
    assert!(!mine[0].to_string().contains(&ufvk));
    assert!(!mine[0].to_string().contains(TEST_SEED_HEX));

    assert!(decrypted_memos("orchard", tx_hex, &ufvk, 4, extra).is_empty());
}

#[test]
#[cfg(feature = "ironwood-tx-build")]
fn the_same_note_read_under_the_wrong_pool_is_not_found() {
    let tx_hex = ironwood_tx_with_memo(&format!(r#","memo":"{}""#, hex::encode(b"hello")));
    let ufvk = account_ufvk(&cptr("regtest"));

    for index in 0..6 {
        let v = read_memo_value(&format!(
            r#"{{"memo_read_version":1,"network":"regtest","transaction":"{tx_hex}",
                     "pool":"orchard","output_index":{index},"ufvk":"{ufvk}"}}"#
        ));
        assert_eq!(v["status"], "ok", "{v}");
        assert_eq!(v["outcome"], "not_for_this_key");
    }
}

#[test]
#[cfg(feature = "ironwood-tx-build")]
fn build_ironwood_transaction_pays_transparent_change_with_a_fixed_fee() {
    let to = regtest_unified_address();
    let change = ironwood_build::test_regtest_transparent_address();
    let (tree_hex, _) = ironwood_build::test_tree_fixture(1);
    let request = format!(
        r#"{{"ironwood_build_version":1,"network":"regtest","target_height":10,
                 "ironwood_tree":"{tree}","fee_zatoshis":12000,
                 "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}],
                 "outputs":[{{"address":"{change}","value_zatoshis":30000}}],
                 "ironwood_output":{{"address":"{to}","value_zatoshis":58000,"memo":"{memo}"}}}}"#,
        tree = tree_hex,
        txid = "22".repeat(32),
        sk = BUILD_TEST_SECRET_KEY,
        change = change,
        to = to,
        memo = hex::encode(b"ironwood"),
    );
    let v = build_ironwood_value(&request);
    assert_eq!(v["status"], "ok", "{v}");
    assert_eq!(v["fee_rule"], "fixed");
    assert_eq!(v["fee_zatoshis"], 12000);
    assert_eq!(v["rng"], "os");
    assert_eq!(v["transparent"]["vout"], 1);
    assert_eq!(v["non_ironwood_output_zatoshis"], 30000);
    assert_eq!(v["ironwood_output_zatoshis"], 58000);

    let tx_hex = v["transaction"].as_str().expect("transaction hex");
    let net = cptr("regtest");
    let decoded = result_value(zcash_ffi_decode_transaction(
        cptr(tx_hex).as_ptr(),
        net.as_ptr(),
    ));
    assert_eq!(decoded["version"], "v6");
    assert_eq!(decoded["transparent"]["vout"], 1);
    assert_eq!(decoded["ironwood"]["present"], true);
}

#[test]
#[cfg(feature = "ironwood-tx-build")]
fn build_ironwood_transaction_is_deterministic_with_a_supplied_seed() {
    let to = regtest_unified_address();
    let (tree_hex, _) = ironwood_build::test_tree_fixture(2);
    let request = format!(
        r#"{{"ironwood_build_version":1,"network":"regtest","target_height":10,
                 "ironwood_tree":"{tree}","rng_seed":"{seed}",
                 "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}],
                 "ironwood_output":{{"address":"{to}"}}}}"#,
        tree = tree_hex,
        seed = "07".repeat(32),
        txid = "22".repeat(32),
        sk = BUILD_TEST_SECRET_KEY,
        to = to,
    );
    let first = build_ironwood_value(&request);
    let second = build_ironwood_value(&request);
    assert_eq!(first["status"], "ok", "{first}");
    assert_eq!(first["transaction"], second["transaction"]);
    assert_eq!(first["txid"], second["txid"]);
}

#[test]
#[cfg(feature = "ironwood-tx-build")]
fn build_ironwood_transaction_rejects_a_pre_activation_target_height() {
    let request = format!(
        r#"{{"ironwood_build_version":1,"network":"main","target_height":3428142,
                 "ironwood_tree":"",
                 "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}],
                 "ironwood_output":{{"address":"u1whatever"}}}}"#,
        txid = "22".repeat(32),
        sk = BUILD_TEST_SECRET_KEY,
    );
    let v = build_ironwood_value(&request);
    assert_eq!(v["category"], "ironwood_not_active", "{v}");

    let v = build_ironwood_value(&request.replace("3428142", "3428143"));
    assert_eq!(v["category"], "invalid_output_address", "{v}");
}

#[test]
#[cfg(feature = "ironwood-tx-build")]
fn build_ironwood_transaction_honours_a_staged_regtest_activation_height() {
    let to = regtest_unified_address();
    let request_at = |height: u64, activation: &str| {
        format!(
            r#"{{"ironwood_build_version":1,"network":"regtest","target_height":{height},
                     "ironwood_tree":"","rng_seed":"{seed}",{activation}
                     "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}],
                     "ironwood_output":{{"address":"{to}"}}}}"#,
            height = height,
            activation = activation,
            seed = "0c".repeat(32),
            txid = "22".repeat(32),
            sk = BUILD_TEST_SECRET_KEY,
            to = to,
        )
    };

    let v = build_ironwood_value(&request_at(99, r#""regtest_nu63_activation_height":100,"#));
    assert_eq!(v["category"], "ironwood_not_active", "{v}");

    let v = build_ironwood_value(&request_at(100, r#""regtest_nu63_activation_height":100,"#));
    assert_eq!(v["status"], "ok", "{v}");
    assert_eq!(v["version"], "v6");
    assert_eq!(v["consensus_branch_id"], "nu6.3");

    let v = build_ironwood_value(&request_at(99, ""));
    assert_eq!(v["status"], "ok", "{v}");
    assert_eq!(v["consensus_branch_id"], "nu6.3");

    let main = format!(
        r#"{{"ironwood_build_version":1,"network":"main","target_height":3428143,
                 "ironwood_tree":"","regtest_nu63_activation_height":100,
                 "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}],
                 "ironwood_output":{{"address":"u1x"}}}}"#,
        txid = "22".repeat(32),
        sk = BUILD_TEST_SECRET_KEY,
    );
    let v = build_ironwood_value(&main);
    assert_eq!(v["category"], "unsupported_activation_override", "{v}");
}

#[test]
#[cfg(feature = "ironwood-tx-build")]
fn build_ironwood_transaction_rejects_recipients_that_cannot_receive_ironwood() {
    let (tree_hex, _) = ironwood_build::test_tree_fixture(1);
    let transparent = ironwood_build::test_regtest_transparent_address();
    let request_paying = |to: &str| {
        format!(
            r#"{{"ironwood_build_version":1,"network":"regtest","target_height":10,
                     "ironwood_tree":"{tree}",
                     "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}],
                     "ironwood_output":{{"address":"{to}"}}}}"#,
            tree = tree_hex,
            txid = "22".repeat(32),
            sk = BUILD_TEST_SECRET_KEY,
            to = to,
        )
    };

    let v = build_ironwood_value(&request_paying(&transparent));
    assert_eq!(v["category"], "unsupported_ironwood_recipient", "{v}");

    let v = build_ironwood_value(&request_paying("not an address"));
    assert_eq!(v["category"], "invalid_output_address", "{v}");

    let to = regtest_unified_address();
    let request = format!(
        r#"{{"ironwood_build_version":1,"network":"regtest","target_height":10,
                 "ironwood_tree":"{tree}","fee_zatoshis":10000,
                 "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}],
                 "outputs":[{{"address":"{to}","value_zatoshis":30000}}],
                 "ironwood_output":{{"address":"{to}","value_zatoshis":60000}}}}"#,
        tree = tree_hex,
        txid = "22".repeat(32),
        sk = BUILD_TEST_SECRET_KEY,
        to = to,
    );
    let v = build_ironwood_value(&request);
    assert_eq!(v["category"], "unsupported_shielded_output", "{v}");
}

#[test]
#[cfg(feature = "ironwood-tx-build")]
fn build_ironwood_transaction_rejects_malformed_requests_without_echo() {
    let to = regtest_unified_address();
    let (tree_hex, _) = ironwood_build::test_tree_fixture(1);

    let v = build_ironwood_value(r#"{"ironwood_build_version":2}"#);
    assert_eq!(v["category"], "unsupported_ironwood_build_version");

    let v = build_ironwood_value("not json");
    assert_eq!(v["category"], "invalid_json");

    let v = build_ironwood_value(r#"{"network":"regtest"}"#);
    assert_eq!(v["category"], "invalid_request");

    let bad_key = "00".repeat(32);
    let request = format!(
        r#"{{"ironwood_build_version":1,"network":"regtest","target_height":10,
                 "ironwood_tree":"{tree}",
                 "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}],
                 "ironwood_output":{{"address":"{to}"}}}}"#,
        tree = tree_hex,
        txid = "22".repeat(32),
        sk = bad_key,
        to = to,
    );
    let v = build_ironwood_value(&request);
    assert_eq!(v["category"], "invalid_secret_key", "{v}");
    assert!(!v.to_string().contains(&bad_key));

    let request = format!(
        r#"{{"ironwood_build_version":1,"network":"regtest","target_height":10,
                 "ironwood_tree":"{tree}","fee_zatoshis":200000,
                 "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}],
                 "ironwood_output":{{"address":"{to}"}}}}"#,
        tree = tree_hex,
        txid = "22".repeat(32),
        sk = BUILD_TEST_SECRET_KEY,
        to = to,
    );
    let v = build_ironwood_value(&request);
    assert_eq!(v["category"], "insufficient_funds", "{v}");
    assert!(!v.to_string().contains(BUILD_TEST_SECRET_KEY));
}

#[cfg(feature = "ironwood-tx-build")]
fn sapling_spend_fragment(value: u64) -> String {
    let (recipient, rseed, witness, anchor) = ironwood_build::test_sapling_note_fixture(
        &hex::decode(TEST_SEED_HEX).unwrap(),
        value,
        [0x2au8; 32],
    );
    format!(
        r#""sapling_spends":[{{"value_zatoshis":{value},"recipient":"{recipient}",
                 "rseed":"{rseed}","witness":"{witness}","anchor":"{anchor}"}}],
               "seed":"{seed}","account":0"#,
        value = value,
        recipient = recipient,
        rseed = rseed,
        witness = witness,
        anchor = anchor,
        seed = TEST_SEED_HEX,
    )
}

/// Real Sapling proving needs the MPC parameters.
#[test]
#[cfg(feature = "ironwood-tx-build")]
fn build_ironwood_transaction_requires_sapling_params_to_spend_sapling() {
    let to = regtest_unified_address();
    let (tree_hex, _) = ironwood_build::test_tree_fixture(1);
    let request = format!(
        r#"{{"ironwood_build_version":1,"network":"regtest","target_height":10,
                 "ironwood_tree":"{tree}",{sapling},
                 "ironwood_output":{{"address":"{to}"}}}}"#,
        tree = tree_hex,
        sapling = sapling_spend_fragment(100000),
        to = to,
    );
    let v = build_ironwood_value(&request);
    assert_eq!(v["category"], "sapling_params_required", "{v}");
    assert!(
        !v.to_string().contains(TEST_SEED_HEX),
        "error must not echo the seed"
    );
}

#[test]
#[cfg(feature = "ironwood-tx-build")]
fn build_ironwood_transaction_validates_sapling_spend_components() {
    let to = regtest_unified_address();
    let (tree_hex, _) = ironwood_build::test_tree_fixture(1);
    let seed_bytes = hex::decode(TEST_SEED_HEX).unwrap();
    let (recipient, rseed, witness, anchor) =
        ironwood_build::test_sapling_note_fixture(&seed_bytes, 100000, [0x2au8; 32]);
    let params = "\"spend_params_path\":\"/nonexistent/spend\",\
                      \"output_params_path\":\"/nonexistent/output\"";
    let request_with = |spends: String| {
        format!(
            r#"{{"ironwood_build_version":1,"network":"regtest","target_height":10,
                     "ironwood_tree":"{tree}","seed":"{seed}","account":0,{params},
                     "sapling_spends":[{spends}],
                     "ironwood_output":{{"address":"{to}"}}}}"#,
            tree = tree_hex,
            seed = TEST_SEED_HEX,
            params = params,
            spends = spends,
            to = to,
        )
    };

    let v = build_ironwood_value(&request_with(format!(
        r#"{{"value_zatoshis":100000,"recipient":"{recipient}","rseed":"{rseed}",
                "witness":"{witness}","anchor":"{bad}"}}"#,
        recipient = recipient,
        rseed = rseed,
        witness = witness,
        bad = "11".repeat(32),
    )));
    assert_eq!(v["category"], "witness_anchor_mismatch", "{v}");

    let (recipient2, rseed2, witness2, anchor2) =
        ironwood_build::test_sapling_note_fixture(&seed_bytes, 50000, [0x3bu8; 32]);
    assert_ne!(
        anchor, anchor2,
        "distinct notes must yield distinct anchors"
    );
    let v = build_ironwood_value(&request_with(format!(
        r#"{{"value_zatoshis":100000,"recipient":"{r1}","rseed":"{s1}",
                "witness":"{w1}","anchor":"{a1}"}},
               {{"value_zatoshis":50000,"recipient":"{r2}","rseed":"{s2}",
                "witness":"{w2}","anchor":"{a2}"}}"#,
        r1 = recipient,
        s1 = rseed,
        w1 = witness,
        a1 = anchor,
        r2 = recipient2,
        s2 = rseed2,
        w2 = witness2,
        a2 = anchor2,
    )));
    assert_eq!(v["category"], "anchor_mismatch", "{v}");

    let other_seed = "ff".repeat(32);
    let (other_recipient, other_rseed, other_witness, other_anchor) =
        ironwood_build::test_sapling_note_fixture(
            &hex::decode(&other_seed).unwrap(),
            100000,
            [0x2au8; 32],
        );
    let v = build_ironwood_value(&request_with(format!(
        r#"{{"value_zatoshis":100000,"recipient":"{r}","rseed":"{s}",
                "witness":"{w}","anchor":"{a}"}}"#,
        r = other_recipient,
        s = other_rseed,
        w = other_witness,
        a = other_anchor,
    )));
    assert_eq!(v["category"], "note_not_spendable", "{v}");

    let v = build_ironwood_value(&request_with(format!(
        r#"{{"value_zatoshis":100000,"recipient":"{r}","rseed":"{s}",
                "witness":"{w}","anchor":"{a}"}}"#,
        r = recipient,
        s = rseed,
        w = witness,
        a = anchor,
    )));
    assert_eq!(v["category"], "params_not_found", "{v}");
    assert!(!v.to_string().contains(TEST_SEED_HEX));
}

#[test]
#[cfg(feature = "ironwood-tx-build")]
fn build_ironwood_transaction_rejects_sapling_change_without_a_sapling_spend() {
    let to = regtest_unified_address();
    let (tree_hex, _) = ironwood_build::test_tree_fixture(1);
    let (sapling_addr, _, _, _) = ironwood_build::test_sapling_note_fixture(
        &hex::decode(TEST_SEED_HEX).unwrap(),
        1,
        [0x2au8; 32],
    );
    let request = format!(
        r#"{{"ironwood_build_version":1,"network":"regtest","target_height":10,
                 "ironwood_tree":"{tree}","fee_zatoshis":10000,
                 "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}],
                 "outputs":[{{"address":"{sapling}","value_zatoshis":30000}}],
                 "ironwood_output":{{"address":"{to}","value_zatoshis":60000}}}}"#,
        tree = tree_hex,
        txid = "22".repeat(32),
        sk = BUILD_TEST_SECRET_KEY,
        sapling = sapling_addr,
        to = to,
    );
    let v = build_ironwood_value(&request);
    assert_eq!(v["category"], "sapling_output_without_spend", "{v}");
}

#[test]
#[cfg(feature = "ironwood-tx-build")]
fn build_ironwood_transaction_requires_at_least_one_input_source() {
    let to = regtest_unified_address();
    let (tree_hex, _) = ironwood_build::test_tree_fixture(1);
    let request = format!(
        r#"{{"ironwood_build_version":1,"network":"regtest","target_height":10,
                 "ironwood_tree":"{tree}",
                 "ironwood_output":{{"address":"{to}","value_zatoshis":1000}}}}"#,
        tree = tree_hex,
        to = to,
    );
    let v = build_ironwood_value(&request);
    assert_eq!(v["category"], "invalid_request", "{v}");
    assert!(v["error"].as_str().unwrap().contains("input source"), "{v}");
}

#[test]
#[cfg(feature = "ironwood-tx-build")]
fn build_ironwood_transaction_migrates_a_sapling_note_with_supplied_params() {
    let (spend_path, output_path) = match (
        std::env::var("ZCASH_SAPLING_SPEND_PARAMS"),
        std::env::var("ZCASH_SAPLING_OUTPUT_PARAMS"),
    ) {
        (Ok(s), Ok(o)) if !s.is_empty() && !o.is_empty() => (s, o),
        _ => {
            eprintln!(
                    "skipping Sapling -> Ironwood migration test: set                      ZCASH_SAPLING_SPEND_PARAMS and ZCASH_SAPLING_OUTPUT_PARAMS                      to the real Sapling parameter files to run it"
                );
            return;
        }
    };

    let to = regtest_unified_address();
    let (tree_hex, root_hex) = ironwood_build::test_tree_fixture(2);
    let request = format!(
        r#"{{"ironwood_build_version":1,"network":"regtest","target_height":10,
                 "ironwood_tree":"{tree}",{sapling},
                 "spend_params_path":{spend:?},"output_params_path":{output:?},
                 "ironwood_output":{{"address":"{to}"}}}}"#,
        tree = tree_hex,
        sapling = sapling_spend_fragment(100000),
        spend = spend_path,
        output = output_path,
        to = to,
    );
    let v = build_ironwood_value(&request);
    assert_eq!(v["status"], "ok", "migration build should succeed: {v}");
    assert_eq!(v["version"], "v6");
    assert_eq!(v["proof_validity"], "real");
    assert_eq!(v["ironwood_anchor"], root_hex);
    assert_eq!(v["sapling"]["spends"], 1);
    assert_eq!(v["ironwood"]["actions"], 2);
    assert_eq!(v["transparent"]["vin"], 0);
    assert_eq!(v["sapling_input_zatoshis"], 100000);
    assert_eq!(v["transparent_input_zatoshis"], 0);
    assert!(!v.to_string().contains(TEST_SEED_HEX));

    let tx_hex = v["transaction"].as_str().expect("transaction hex");
    let net = cptr("regtest");
    let decoded = result_value(zcash_ffi_decode_transaction(
        cptr(tx_hex).as_ptr(),
        net.as_ptr(),
    ));
    assert_eq!(decoded["status"], "ok", "{decoded}");
    assert_eq!(decoded["version"], "v6");
    assert_eq!(decoded["consensus_branch_id"], "nu6.3");
    assert_eq!(decoded["sapling"]["present"], true);
    assert_eq!(decoded["sapling"]["spends"], 1);
    assert_eq!(decoded["ironwood"]["present"], true);
    assert_eq!(decoded["orchard"]["present"], false);
}

#[cfg(feature = "ironwood-tx-build")]
fn orchard_spend_fragment(value: u64, nonce: u8) -> String {
    let (recipient, rseed, rho, witness, anchor) = ironwood_build::test_orchard_note_fixture(
        &hex::decode(TEST_SEED_HEX).unwrap(),
        value,
        nonce,
        false,
    );
    format!(
        r#""orchard_spends":[{{"value_zatoshis":{value},"recipient":"{recipient}",
                 "rseed":"{rseed}","rho":"{rho}","note_version":"v2",
                 "witness":"{witness}","anchor":"{anchor}"}}],
               "seed":"{seed}","account":0"#,
        value = value,
        recipient = recipient,
        rseed = rseed,
        rho = rho,
        witness = witness,
        anchor = anchor,
        seed = TEST_SEED_HEX,
    )
}

/// ZIP 318 expiry for the first 30-day window (34560 blocks). `EXPIRY_MODULUS` is
/// provisional, so the crate takes the expiry as input.
#[cfg(feature = "ironwood-tx-build")]
const TEST_CANONICAL_EXPIRY: u32 = 2 * 34560;

#[test]
#[cfg(feature = "ironwood-tx-build")]
fn build_ironwood_transaction_migrates_an_orchard_note_in_the_zip318_canonical_shape() {
    let to = regtest_unified_address();
    let (tree_hex, root_hex) = ironwood_build::test_tree_fixture(2);
    let request = format!(
        r#"{{"ironwood_build_version":1,"network":"regtest","target_height":10,
                 "ironwood_tree":"{tree}","expiry_height":{expiry},{orchard},
                 "ironwood_output":{{"address":"{to}"}}}}"#,
        tree = tree_hex,
        expiry = TEST_CANONICAL_EXPIRY,
        orchard = orchard_spend_fragment(1_000_000, 0x11),
        to = to,
    );
    let v = build_ironwood_value(&request);
    assert_eq!(v["status"], "ok", "canonical migration should build: {v}");
    assert_eq!(v["version"], "v6");
    assert_eq!(v["proof_validity"], "real");
    assert_eq!(v["zip318_canonical"], true);

    assert_eq!(v["orchard"]["spends"], 1);
    assert_eq!(v["orchard"]["actions"], 2);
    assert_eq!(v["orchard"]["change_outputs"], 0);
    assert_eq!(v["ironwood"]["actions"], 1);

    // ZIP 317 Revision 1: 2 Orchard + 1 Ironwood action = 3 logical actions at 5000 each.
    assert_eq!(v["fee_zatoshis"], 15000);
    assert_eq!(v["fee_rule"], "zip317");
    assert_eq!(v["orchard_input_zatoshis"], 1_000_000);
    assert_eq!(v["orchard_change_zatoshis"], 0);
    assert_eq!(v["transparent_input_zatoshis"], 0);
    assert_eq!(v["sapling_input_zatoshis"], 0);
    assert_eq!(v["non_ironwood_output_zatoshis"], 0);
    assert_eq!(v["ironwood_output_zatoshis"], 985_000);
    assert_eq!(v["ironwood_anchor"], root_hex);

    assert_eq!(v["expiry_height"], TEST_CANONICAL_EXPIRY);

    let tx_hex = v["transaction"].as_str().expect("transaction hex");
    let net = cptr("regtest");
    let decoded = result_value(zcash_ffi_decode_transaction(
        cptr(tx_hex).as_ptr(),
        net.as_ptr(),
    ));
    assert_eq!(decoded["status"], "ok", "{decoded}");
    assert_eq!(decoded["version"], "v6");
    assert_eq!(decoded["consensus_branch_id"], "nu6.3");
    assert_eq!(decoded["orchard"]["present"], true);
    assert_eq!(decoded["orchard"]["actions"], 2);
    assert_eq!(decoded["ironwood"]["present"], true);
    assert_eq!(decoded["ironwood"]["actions"], 1);
    assert_eq!(decoded["sapling"]["present"], false);
    assert_eq!(decoded["transparent"]["vin"], 0);
    assert_eq!(decoded["transparent"]["vout"], 0);

    assert!(
        !v.to_string().contains(TEST_SEED_HEX),
        "build output must not echo the seed"
    );
}

/// ZIP 318 pads the Orchard bundle to two actions so change is not observable.
#[test]
#[cfg(feature = "ironwood-tx-build")]
fn build_ironwood_transaction_keeps_orchard_change_indistinguishable_from_none() {
    let to = regtest_unified_address();
    let (tree_hex, _) = ironwood_build::test_tree_fixture(2);
    let request = format!(
        r#"{{"ironwood_build_version":1,"network":"regtest","target_height":10,
                 "ironwood_tree":"{tree}","expiry_height":{expiry},
                 "orchard_change_zatoshis":300000,{orchard},
                 "ironwood_output":{{"address":"{to}"}}}}"#,
        tree = tree_hex,
        expiry = TEST_CANONICAL_EXPIRY,
        orchard = orchard_spend_fragment(1_000_000, 0x22),
        to = to,
    );
    let v = build_ironwood_value(&request);
    assert_eq!(v["status"], "ok", "partial migration should build: {v}");
    assert_eq!(v["orchard"]["spends"], 1);
    assert_eq!(v["orchard"]["change_outputs"], 1);
    assert_eq!(v["orchard"]["actions"], 2);
    assert_eq!(v["ironwood"]["actions"], 1);
    assert_eq!(v["fee_zatoshis"], 15000);
    assert_eq!(v["orchard_change_zatoshis"], 300000);
    assert_eq!(v["non_ironwood_output_zatoshis"], 300000);
    assert_eq!(v["ironwood_output_zatoshis"], 685_000);

    let tx_hex = v["transaction"].as_str().expect("transaction hex");
    let net = cptr("regtest");
    let decoded = result_value(zcash_ffi_decode_transaction(
        cptr(tx_hex).as_ptr(),
        net.as_ptr(),
    ));
    assert_eq!(decoded["orchard"]["actions"], 2, "{decoded}");
    assert_eq!(decoded["ironwood"]["actions"], 1);

    let request = format!(
        r#"{{"ironwood_build_version":1,"network":"regtest","target_height":10,
                 "ironwood_tree":"{tree}","expiry_height":{expiry},
                 "orchard_change_zatoshis":2000000,{orchard},
                 "ironwood_output":{{"address":"{to}"}}}}"#,
        tree = tree_hex,
        expiry = TEST_CANONICAL_EXPIRY,
        orchard = orchard_spend_fragment(1_000_000, 0x22),
        to = to,
    );
    let v = build_ironwood_value(&request);
    assert_eq!(v["category"], "invalid_request", "{v}");
    assert!(v["error"].as_str().unwrap().contains("Orchard pool"), "{v}");
}

#[test]
#[cfg(feature = "ironwood-tx-build")]
fn build_ironwood_transaction_refuses_ironwood_change_without_a_spend() {
    let to = regtest_unified_address();
    let (tree_hex, _) = ironwood_build::test_tree_fixture(2);
    let request = format!(
        r#"{{"ironwood_build_version":1,"network":"regtest","target_height":10,
                 "ironwood_tree":"{tree}","ironwood_change_zatoshis":1000,
                 "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,
                   "secret_key":"{sk}"}}],
                 "ironwood_output":{{"address":"{to}"}}}}"#,
        tree = tree_hex,
        txid = "22".repeat(32),
        sk = BUILD_TEST_SECRET_KEY,
        to = to,
    );
    let v = build_ironwood_value(&request);
    assert_eq!(v["category"], "ironwood_change_without_spend", "{v}");
}

#[test]
#[cfg(feature = "ironwood-tx-build")]
fn build_ironwood_transaction_requires_a_seed_to_spend_ironwood() {
    let to = regtest_unified_address();
    let (tree_hex, _) = ironwood_build::test_tree_fixture(2);
    let request = format!(
        r#"{{"ironwood_build_version":1,"network":"regtest","target_height":10,
                 "ironwood_tree":"{tree}",
                 "ironwood_spends":[{{"value_zatoshis":100000,"recipient":"{to}",
                   "rseed":"{h}","rho":"{h}","note_version":"v3","witness":"{h}",
                   "anchor":"{h}"}}],
                 "ironwood_output":{{"address":"{to}"}}}}"#,
        tree = tree_hex,
        to = to,
        h = "11".repeat(32),
    );
    let v = build_ironwood_value(&request);
    assert_eq!(v["category"], "invalid_request", "{v}");
    assert!(
        v["error"]
            .as_str()
            .unwrap()
            .contains("Ironwood notes requires a seed"),
        "{v}"
    );
}

/// ZIP 318: each of these is consensus-valid but breaks the canonical migration shape.
#[test]
#[cfg(feature = "ironwood-tx-build")]
fn build_ironwood_transaction_refuses_non_canonical_orchard_migrations() {
    let to = regtest_unified_address();
    let (tree_hex, _) = ironwood_build::test_tree_fixture(2);
    let request_with = |extra: &str, expiry: &str| {
        format!(
            r#"{{"ironwood_build_version":1,"network":"regtest","target_height":10,
                     "ironwood_tree":"{tree}",{expiry}{extra}{orchard},
                     "ironwood_output":{{"address":"{to}"}}}}"#,
            tree = tree_hex,
            expiry = expiry,
            extra = extra,
            orchard = orchard_spend_fragment(1_000_000, 0x33),
            to = to,
        )
    };
    let expiry = format!(r#""expiry_height":{TEST_CANONICAL_EXPIRY},"#);

    let v = build_ironwood_value(&request_with(
        &format!(
            r#""inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,
                     "secret_key":"{sk}"}}],"#,
            txid = "22".repeat(32),
            sk = BUILD_TEST_SECRET_KEY,
        ),
        &expiry,
    ));
    assert_eq!(v["category"], "non_canonical_orchard_migration", "{v}");

    let v = build_ironwood_value(&request_with(
        &format!(
            r#""outputs":[{{"address":"{t}","value_zatoshis":1000}}],"#,
            t = ironwood_build::test_regtest_transparent_address(),
        ),
        &expiry,
    ));
    assert_eq!(v["category"], "non_canonical_orchard_migration", "{v}");

    let v = build_ironwood_value(&request_with(
        &format!("{},", sapling_spend_fragment(100000)),
        &expiry,
    ));
    assert_eq!(v["category"], "non_canonical_orchard_migration", "{v}");

    let v = build_ironwood_value(&request_with(
        &format!(
            r#""ironwood_spends":[{{"value_zatoshis":100000,"recipient":"{to}",
                     "rseed":"{h}","rho":"{h}","note_version":"v3","witness":"{h}",
                     "anchor":"{h}"}}],"#,
            to = to,
            h = "11".repeat(32),
        ),
        &expiry,
    ));
    assert_eq!(v["category"], "non_canonical_orchard_migration", "{v}");

    let (r2, s2, rho2, w2, a2) = ironwood_build::test_orchard_note_fixture(
        &hex::decode(TEST_SEED_HEX).unwrap(),
        500_000,
        0x44,
        false,
    );
    let two_spends = format!(
        r#"{{"ironwood_build_version":1,"network":"regtest","target_height":10,
                 "ironwood_tree":"{tree}","expiry_height":{expiry},"seed":"{seed}",
                 "account":0,"orchard_spends":[
                   {{"value_zatoshis":500000,"recipient":"{r2}","rseed":"{s2}",
                     "rho":"{rho2}","note_version":"v2","witness":"{w2}","anchor":"{a2}"}},
                   {{"value_zatoshis":500000,"recipient":"{r2}","rseed":"{s2}",
                     "rho":"{rho2}","note_version":"v2","witness":"{w2}","anchor":"{a2}"}}],
                 "ironwood_output":{{"address":"{to}"}}}}"#,
        tree = tree_hex,
        expiry = TEST_CANONICAL_EXPIRY,
        seed = TEST_SEED_HEX,
        r2 = r2,
        s2 = s2,
        rho2 = rho2,
        w2 = w2,
        a2 = a2,
        to = to,
    );
    let v = build_ironwood_value(&two_spends);
    assert_eq!(v["category"], "non_canonical_orchard_migration", "{v}");

    let v = build_ironwood_value(&request_with("", ""));
    assert_eq!(v["category"], "missing_canonical_expiry_height", "{v}");

    assert!(!v.to_string().contains(TEST_SEED_HEX));
}

#[test]
#[cfg(feature = "ironwood-tx-build")]
fn build_ironwood_transaction_validates_orchard_spend_components() {
    let to = regtest_unified_address();
    let (tree_hex, _) = ironwood_build::test_tree_fixture(2);
    let seed_bytes = hex::decode(TEST_SEED_HEX).unwrap();
    let (recipient, rseed, rho, witness, anchor) =
        ironwood_build::test_orchard_note_fixture(&seed_bytes, 1_000_000, 0x55, false);
    let request_with = |spends: String| {
        format!(
            r#"{{"ironwood_build_version":1,"network":"regtest","target_height":10,
                     "ironwood_tree":"{tree}","expiry_height":{expiry},
                     "seed":"{seed}","account":0,"orchard_spends":[{spends}],
                     "ironwood_output":{{"address":"{to}"}}}}"#,
            tree = tree_hex,
            expiry = TEST_CANONICAL_EXPIRY,
            seed = TEST_SEED_HEX,
            spends = spends,
            to = to,
        )
    };
    let entry = |value: u64, rseed: &str, rho: &str, version: &str, anchor: &str| {
        format!(
            r#"{{"value_zatoshis":{value},"recipient":"{recipient}","rseed":"{rseed}",
                    "rho":"{rho}","note_version":"{version}","witness":"{witness}",
                    "anchor":"{anchor}"}}"#,
            value = value,
            recipient = recipient,
            rseed = rseed,
            rho = rho,
            version = version,
            witness = witness,
            anchor = anchor,
        )
    };

    let v = build_ironwood_value(&request_with(entry(1_000_000, &rseed, &rho, "v2", &anchor)));
    assert_eq!(v["status"], "ok", "the control case must build: {v}");

    let v = build_ironwood_value(&request_with(entry(
        1_000_000,
        &rseed,
        &rho,
        "v2",
        &"11".repeat(32),
    )));
    assert_eq!(v["category"], "witness_anchor_mismatch", "{v}");

    let v = build_ironwood_value(&request_with(entry(1_000_000, &rseed, &rho, "v3", &anchor)));
    assert_eq!(v["category"], "unsupported_orchard_note_version", "{v}");

    let (_, other_rseed, other_rho, _, _) =
        ironwood_build::test_orchard_note_fixture(&seed_bytes, 1_000_000, 0x66, false);
    let v = build_ironwood_value(&request_with(entry(
        1_000_000,
        &other_rseed,
        &other_rho,
        "v2",
        &anchor,
    )));
    assert_eq!(v["category"], "witness_anchor_mismatch", "{v}");

    let v = build_ironwood_value(&request_with(entry(2_000_000, &rseed, &rho, "v2", &anchor)));
    assert_eq!(v["category"], "witness_anchor_mismatch", "{v}");

    let (other_recipient, other_rseed, other_rho, other_witness, other_anchor) =
        ironwood_build::test_orchard_note_fixture(
            &hex::decode("ff".repeat(32)).unwrap(),
            1_000_000,
            0x55,
            false,
        );
    let v = build_ironwood_value(&request_with(format!(
        r#"{{"value_zatoshis":1000000,"recipient":"{r}","rseed":"{s}","rho":"{rho}",
                "note_version":"v2","witness":"{w}","anchor":"{a}"}}"#,
        r = other_recipient,
        s = other_rseed,
        rho = other_rho,
        w = other_witness,
        a = other_anchor,
    )));
    assert_eq!(v["category"], "note_not_spendable", "{v}");

    assert!(!v.to_string().contains(TEST_SEED_HEX));
}

/// ZIP 326: upstream randomizes the same-address output only for an external-scope spend.
#[test]
#[cfg(feature = "ironwood-tx-build")]
fn build_ironwood_transaction_migrates_an_internal_scope_orchard_note() {
    let to = regtest_unified_address();
    let (tree_hex, _) = ironwood_build::test_tree_fixture(2);
    let (recipient, rseed, rho, witness, anchor) = ironwood_build::test_orchard_note_fixture(
        &hex::decode(TEST_SEED_HEX).unwrap(),
        1_000_000,
        0x77,
        true,
    );
    let request = format!(
        r#"{{"ironwood_build_version":1,"network":"regtest","target_height":10,
                 "ironwood_tree":"{tree}","expiry_height":{expiry},
                 "seed":"{seed}","account":0,
                 "orchard_spends":[{{"value_zatoshis":1000000,"recipient":"{recipient}",
                   "rseed":"{rseed}","rho":"{rho}","note_version":"v2",
                   "witness":"{witness}","anchor":"{anchor}"}}],
                 "ironwood_output":{{"address":"{to}"}}}}"#,
        tree = tree_hex,
        expiry = TEST_CANONICAL_EXPIRY,
        seed = TEST_SEED_HEX,
        recipient = recipient,
        rseed = rseed,
        rho = rho,
        witness = witness,
        anchor = anchor,
        to = to,
    );
    let v = build_ironwood_value(&request);
    assert_eq!(v["status"], "ok", "{v}");
    assert_eq!(v["orchard"]["actions"], 2);
    assert_eq!(v["ironwood"]["actions"], 1);
}

#[test]
#[cfg(feature = "ironwood-tx-build")]
fn build_ironwood_transaction_rejects_orchard_change_without_an_orchard_spend() {
    // ZIP 258: Orchard change without an Orchard spend is value entering the Orchard pool.
    let to = regtest_unified_address();
    let (tree_hex, _) = ironwood_build::test_tree_fixture(1);
    let request = format!(
        r#"{{"ironwood_build_version":1,"network":"regtest","target_height":10,
                 "ironwood_tree":"{tree}","orchard_change_zatoshis":10000,
                 "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}],
                 "ironwood_output":{{"address":"{to}"}}}}"#,
        tree = tree_hex,
        txid = "22".repeat(32),
        sk = BUILD_TEST_SECRET_KEY,
        to = to,
    );
    let v = build_ironwood_value(&request);
    assert_eq!(v["category"], "orchard_change_without_spend", "{v}");
}

#[test]
#[cfg(feature = "ironwood-tx-build")]
fn build_ironwood_transaction_leaves_the_non_migration_shape_padded() {
    let to = regtest_unified_address();
    let (tree_hex, _) = ironwood_build::test_tree_fixture(2);
    let request = format!(
        r#"{{"ironwood_build_version":1,"network":"regtest","target_height":10,
                 "ironwood_tree":"{tree}",
                 "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,"secret_key":"{sk}"}}],
                 "ironwood_output":{{"address":"{to}"}}}}"#,
        tree = tree_hex,
        txid = "22".repeat(32),
        sk = BUILD_TEST_SECRET_KEY,
        to = to,
    );
    let v = build_ironwood_value(&request);
    assert_eq!(v["status"], "ok", "{v}");
    assert_eq!(v["zip318_canonical"], false);
    assert_eq!(v["ironwood"]["actions"], 2);
    assert_eq!(v["orchard"]["spends"], 0);
    assert_eq!(v["orchard"]["actions"], 0);
}

fn build_sapling_value(request: &str) -> Value {
    let req = cptr(request);
    result_value(zcash_ffi_build_sapling_transaction(req.as_ptr()))
}

#[test]
#[cfg(not(feature = "sapling-spend-build"))]
fn build_sapling_transaction_disabled_in_default_build() {
    let request = format!(
        r#"{{"sapling_build_version":1,"network":"regtest","target_height":10,
                 "fee_zatoshis":10000,"seed":"{seed}","account":0,
                 "spend_notes":[{{"value_zatoshis":100000}}],
                 "outputs":[{{"address":"zregtest","value_zatoshis":90000}}]}}"#,
        seed = TEST_SEED_HEX,
    );
    let v = build_sapling_value(&request);
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "experimental_feature_disabled");
    assert!(
        !v.to_string().contains(TEST_SEED_HEX),
        "disabled build must not echo the supplied seed"
    );
}

#[test]
#[cfg(not(feature = "sapling-spend-build"))]
fn build_sapling_transaction_disabled_rejects_null_pointer() {
    let v = result_value(zcash_ffi_build_sapling_transaction(std::ptr::null()));
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "null_pointer");
}

#[cfg(feature = "sapling-spend-build")]
fn regtest_sapling_address() -> String {
    let regtest = cptr("regtest");
    viewing_keys_value(TEST_SEED_HEX, &regtest, 0)["sapling"]["default_address"]
        .as_str()
        .expect("regtest sapling default address")
        .to_owned()
}

#[test]
#[cfg(feature = "sapling-spend-build")]
fn build_sapling_transaction_builds_spend_regtest_vector() {
    let to = regtest_sapling_address();
    let request = format!(
        r#"{{"sapling_build_version":1,"network":"regtest","target_height":10,
                 "fee_zatoshis":10000,"seed":"{seed}","account":0,
                 "spend_notes":[{{"value_zatoshis":100000}}],
                 "outputs":[{{"address":"{to}","value_zatoshis":90000}}]}}"#,
        seed = TEST_SEED_HEX,
        to = to,
    );
    let v = build_sapling_value(&request);
    assert_eq!(v["status"], "ok", "build should succeed: {v}");
    assert_eq!(v["network"], "regtest");
    assert_eq!(v["version"], "v5");
    assert_eq!(
        v["consensus_branch_id"], "nu6.2",
        "a regtest chain this repo starts runs to NU6.2 at height 1, and \
             this transaction has to be signed for the branch it will be mined \
             under: {v}"
    );
    assert_eq!(v["fee_zatoshis"], 10000);
    assert_eq!(v["total_spent_zatoshis"], 100000);
    assert_eq!(v["total_output_zatoshis"], 90000);
    assert_eq!(v["sapling"]["spends"], 1);
    assert!(
        v["sapling"]["outputs"].as_u64().unwrap() >= 1,
        "expected at least the requested Sapling output"
    );
    assert_eq!(v["transparent"]["vin"], 0);
    assert_eq!(v["transparent"]["vout"], 0);
    assert_eq!(v["proof_validity"], "placeholder");

    let tx_hex = v["transaction"].as_str().expect("transaction hex");
    let net = cptr("regtest");
    let decoded = result_value(zcash_ffi_decode_transaction(
        cptr(tx_hex).as_ptr(),
        net.as_ptr(),
    ));
    assert_eq!(decoded["status"], "ok");
    assert_eq!(decoded["version"], "v5");
    assert_eq!(decoded["txid"], v["txid"]);
    assert_eq!(decoded["sapling"]["present"], true);
    assert_eq!(decoded["sapling"]["spends"], v["sapling"]["spends"]);
    assert_eq!(decoded["sapling"]["outputs"], v["sapling"]["outputs"]);
    assert_eq!(decoded["orchard"]["present"], false);

    assert!(
        !v.to_string().contains(TEST_SEED_HEX),
        "build output must not echo the seed"
    );
}

#[test]
#[cfg(feature = "sapling-spend-build")]
fn build_sapling_transaction_follows_the_staged_regtest_branch() {
    let to = regtest_sapling_address();
    let build_at = |height: u32| {
        let request = format!(
            r#"{{"sapling_build_version":1,"network":"regtest","target_height":{height},
                     "regtest_nu63_activation_height":130,
                     "fee_zatoshis":10000,"seed":"{seed}","account":0,
                     "spend_notes":[{{"value_zatoshis":100000}}],
                     "outputs":[{{"address":"{to}","value_zatoshis":90000}}]}}"#,
            height = height,
            seed = TEST_SEED_HEX,
            to = to,
        );
        build_sapling_value(&request)
    };

    let below = build_at(129);
    assert_eq!(below["status"], "ok", "{below}");
    assert_eq!(below["consensus_branch_id"], "nu6.2");
    assert_eq!(below["version"], "v5");

    let above = build_at(130);
    assert_eq!(above["status"], "ok", "{above}");
    assert_eq!(
        above["consensus_branch_id"], "nu6.3",
        "at and above the declared activation height the chain is on \
             NU6.3, and a Sapling spend is still an ordinary payment there: {above}"
    );
    assert_eq!(
        above["version"], "v6",
        "NU6.3 selects the v6 transaction format for every pool, Sapling \
             included: {above}"
    );
    assert_eq!(above["sapling"]["spends"], 1);
    assert_ne!(
        above["txid"], below["txid"],
        "the same spend signed for two branches is two transactions"
    );

    let net = cptr("regtest");
    let decoded = result_value(zcash_ffi_decode_transaction(
        cptr(above["transaction"].as_str().expect("transaction hex")).as_ptr(),
        net.as_ptr(),
    ));
    assert_eq!(decoded["status"], "ok");
    assert_eq!(decoded["version"], "v6");
    assert_eq!(decoded["consensus_branch_id"], "nu6.3");
    assert_eq!(decoded["sapling"]["present"], true);
    assert_eq!(decoded["sapling"]["spends"], above["sapling"]["spends"]);
    assert!(
        !above.to_string().contains(TEST_SEED_HEX),
        "build output must not echo the seed"
    );
}

#[test]
#[cfg(feature = "sapling-spend-build")]
fn build_sapling_transaction_shields_a_transparent_input_into_the_pool() {
    let to = regtest_sapling_address();
    let request = format!(
        r#"{{"sapling_build_version":1,"network":"regtest","target_height":140,
                 "regtest_nu63_activation_height":130,
                 "fee_zatoshis":15000,"seed":"{seed}","account":0,
                 "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,
                   "secret_key":"{sk}"}}],
                 "outputs":[{{"address":"{to}","value_zatoshis":85000}}]}}"#,
        seed = TEST_SEED_HEX,
        txid = "33".repeat(32),
        sk = BUILD_TEST_SECRET_KEY,
        to = to,
    );
    let v = build_sapling_value(&request);
    assert_eq!(v["status"], "ok", "shielding build should succeed: {v}");
    assert_eq!(v["consensus_branch_id"], "nu6.3");
    assert_eq!(v["version"], "v6");
    assert_eq!(v["transparent"]["vin"], 1);
    assert_eq!(v["transparent"]["vout"], 0);
    assert_eq!(
        v["transparent"]["input_zatoshis"], 100000,
        "the value has to be reported somewhere: no Sapling note was spent, \
             so `total_spent_zatoshis` is legitimately zero here: {v}"
    );
    assert_eq!(v["total_spent_zatoshis"], 0);
    assert_eq!(v["total_output_zatoshis"], 85000);
    assert_eq!(
        v["sapling"]["spends"], 0,
        "a shielding transaction spends no note, which is what makes the \
             bundle's anchor unserialized and therefore harmless: {v}"
    );
    assert!(v["sapling"]["outputs"].as_u64().unwrap() >= 1);

    let net = cptr("regtest");
    let decoded = result_value(zcash_ffi_decode_transaction(
        cptr(v["transaction"].as_str().expect("transaction hex")).as_ptr(),
        net.as_ptr(),
    ));
    assert_eq!(decoded["status"], "ok");
    assert_eq!(decoded["version"], "v6");
    assert_eq!(decoded["sapling"]["present"], true);
    assert_eq!(
        decoded["sapling"]["spends"], 0,
        "the decoded bundle carries no spend, so the v5/v6 serialization \
             wrote no anchor: the `empty_tree()` value the build passed is not \
             in the transaction and constrains nothing: {decoded}"
    );
    assert_eq!(decoded["transparent"]["vin"], 1);
    assert_eq!(decoded["txid"], v["txid"]);

    assert!(
        !v.to_string().contains(BUILD_TEST_SECRET_KEY),
        "a build must never echo an input signing key"
    );
    assert!(
        !v.to_string().contains(TEST_SEED_HEX),
        "build output must not echo the seed"
    );
}

#[test]
#[cfg(feature = "sapling-spend-build")]
fn build_sapling_transaction_tops_a_spend_up_with_a_transparent_input() {
    let rseed = [43u8; 32];
    let (recipient, rseed_hex, witness_hex, anchor_hex) =
        super::sapling_build::real_note_fixture(&test_seed_bytes(), 0, 100000, rseed);
    let request = format!(
        r#"{{"sapling_build_version":1,"network":"regtest","target_height":10,
                 "fee_zatoshis":10000,"seed":"{seed}","account":0,
                 "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":50000,
                   "secret_key":"{sk}"}}],
                 "spend_notes":[{{"value_zatoshis":100000,"recipient":"{recipient}",
                   "rseed":"{rseed}","witness":"{witness}","anchor":"{anchor}"}}],
                 "outputs":[{{"address":"{recipient}","value_zatoshis":140000}}]}}"#,
        seed = TEST_SEED_HEX,
        txid = "34".repeat(32),
        sk = BUILD_TEST_SECRET_KEY,
        recipient = recipient,
        rseed = rseed_hex,
        witness = witness_hex,
        anchor = anchor_hex,
    );
    let v = build_sapling_value(&request);
    assert_eq!(v["status"], "ok", "{v}");
    assert_eq!(v["sapling"]["spends"], 1);
    assert_eq!(v["transparent"]["vin"], 1);
    assert_eq!(v["transparent"]["input_zatoshis"], 50000);
    assert_eq!(v["total_spent_zatoshis"], 100000);
    assert_eq!(v["total_output_zatoshis"], 140000);
}

#[test]
#[cfg(feature = "sapling-spend-build")]
fn build_sapling_transaction_refuses_a_build_that_spends_nothing() {
    let to = regtest_sapling_address();
    let request = format!(
        r#"{{"sapling_build_version":1,"network":"regtest","target_height":10,
                 "fee_zatoshis":10000,"seed":"{seed}","account":0,
                 "outputs":[{{"address":"{to}","value_zatoshis":90000}}]}}"#,
        seed = TEST_SEED_HEX,
        to = to,
    );
    let v = build_sapling_value(&request);
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "invalid_request");
    assert!(
        !v.to_string().contains(TEST_SEED_HEX),
        "refusal must not echo the seed"
    );
}

#[test]
#[cfg(feature = "sapling-spend-build")]
fn build_sapling_transaction_rejects_a_malformed_input_without_echo() {
    let to = regtest_sapling_address();
    let request = format!(
        r#"{{"sapling_build_version":1,"network":"regtest","target_height":10,
                 "fee_zatoshis":10000,"seed":"{seed}","account":0,
                 "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,
                   "secret_key":"{sk}"}}],
                 "outputs":[{{"address":"{to}","value_zatoshis":90000}}]}}"#,
        seed = TEST_SEED_HEX,
        txid = "35".repeat(32),
        sk = "ff".repeat(32),
        to = to,
    );
    let v = build_sapling_value(&request);
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "invalid_secret_key");
    assert!(
        !v.to_string().contains(&"ff".repeat(32)),
        "a rejected key must not be echoed back"
    );
}

#[test]
#[cfg(feature = "sapling-spend-build")]
fn sapling_fee_quote_equals_the_fee_the_build_charges() {
    let to = regtest_sapling_address();
    let request = |quote: bool| {
        format!(
            r#"{{"sapling_build_version":1,"network":"regtest","target_height":140,
                     "regtest_nu63_activation_height":130,
                     "quote_only":{quote},
                     "seed":"{seed}","account":0,
                     "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,
                       "secret_key":"{sk}"}}],
                     "outputs":[{{"address":"{to}"}}]}}"#,
            quote = quote,
            seed = TEST_SEED_HEX,
            txid = "36".repeat(32),
            sk = BUILD_TEST_SECRET_KEY,
            to = to,
        )
    };

    let quoted = build_sapling_value(&request(true));
    assert_eq!(quoted["status"], "ok", "{quoted}");
    assert_eq!(quoted["quote_only"], true);
    assert_eq!(quoted["fee_rule"], "zip317");
    assert_eq!(quoted["consensus_branch_id"], "nu6.3");
    assert_eq!(quoted["total_input_zatoshis"], 100000);
    assert_eq!(quoted["stated_output_zatoshis"], 0);
    assert!(quoted["transaction"].is_null(), "a quote is not a build");
    let fee = quoted["fee_zatoshis"].as_u64().expect("fee");
    let max_output = quoted["max_output_zatoshis"].as_u64().expect("max output");
    assert_eq!(max_output, 100000 - fee);

    let built = build_sapling_value(&request(false));
    assert_eq!(built["status"], "ok", "{built}");
    assert_eq!(
        built["fee_zatoshis"], quoted["fee_zatoshis"],
        "the quote must be the fee the build charges: {built}"
    );
    assert_eq!(
        built["total_output_zatoshis"], max_output,
        "the remainder output takes exactly what the quote said was payable"
    );
    assert_eq!(built["fee_rule"], "zip317");
}

#[test]
#[cfg(feature = "sapling-spend-build")]
fn sapling_fee_quote_tracks_the_shape_and_not_the_values() {
    let to = regtest_sapling_address();
    let quote = |outputs: &str| {
        let request = format!(
            r#"{{"sapling_build_version":1,"network":"regtest","target_height":140,
                     "regtest_nu63_activation_height":130,"quote_only":true,
                     "seed":"{seed}","account":0,
                     "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":1000000,
                       "secret_key":"{sk}"}}],
                     "outputs":{outputs}}}"#,
            seed = TEST_SEED_HEX,
            txid = "37".repeat(32),
            sk = BUILD_TEST_SECRET_KEY,
            outputs = outputs,
        );
        let v = build_sapling_value(&request);
        assert_eq!(v["status"], "ok", "{v}");
        v["fee_zatoshis"].as_u64().expect("fee")
    };

    let one = quote(&format!(r#"[{{"address":"{to}"}}]"#));
    let one_again = quote(&format!(
        r#"[{{"address":"{to}","value_zatoshis":900000}}]"#
    ));
    let two = quote(&format!(
        r#"[{{"address":"{to}","value_zatoshis":400000}},{{"address":"{to}"}}]"#
    ));
    let three = quote(&format!(
        r#"[{{"address":"{to}","value_zatoshis":100000}},
                {{"address":"{to}","value_zatoshis":200000}},
                {{"address":"{to}"}}]"#
    ));

    assert_eq!(one, one_again, "the fee is a function of the shape");
    assert_eq!(
        one, two,
        "one output is padded to two, so it already pays for two: {one} vs {two}"
    );
    assert!(
        three > two,
        "the third output is past the padding and must cost more: {three} vs {two}"
    );
}

#[test]
#[cfg(feature = "sapling-spend-build")]
fn build_sapling_transaction_refuses_two_remainder_outputs() {
    let to = regtest_sapling_address();
    let request = format!(
        r#"{{"sapling_build_version":1,"network":"regtest","target_height":140,
                 "regtest_nu63_activation_height":130,
                 "seed":"{seed}","account":0,
                 "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":100000,
                   "secret_key":"{sk}"}}],
                 "outputs":[{{"address":"{to}"}},{{"address":"{to}"}}]}}"#,
        seed = TEST_SEED_HEX,
        txid = "38".repeat(32),
        sk = BUILD_TEST_SECRET_KEY,
        to = to,
    );
    let v = build_sapling_value(&request);
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "invalid_request");
}

#[test]
#[cfg(feature = "sapling-spend-build")]
fn sapling_fee_quote_reports_a_shortfall_as_a_null_rather_than_an_error() {
    let to = regtest_sapling_address();
    let request = format!(
        r#"{{"sapling_build_version":1,"network":"regtest","target_height":140,
                 "regtest_nu63_activation_height":130,"quote_only":true,
                 "seed":"{seed}","account":0,
                 "inputs":[{{"txid":"{txid}","vout":0,"value_zatoshis":1000,
                   "secret_key":"{sk}"}}],
                 "outputs":[{{"address":"{to}"}}]}}"#,
        seed = TEST_SEED_HEX,
        txid = "39".repeat(32),
        sk = BUILD_TEST_SECRET_KEY,
        to = to,
    );
    let v = build_sapling_value(&request);
    assert_eq!(v["status"], "ok", "a shortfall is an answer: {v}");
    assert!(
        v["fee_zatoshis"].as_u64().expect("fee") > 1000,
        "this selection cannot even cover the fee, which is the point"
    );
    assert!(v["max_output_zatoshis"].is_null());
}

#[test]
#[cfg(feature = "sapling-spend-build")]
fn build_sapling_transaction_refuses_an_activation_override_off_regtest() {
    let request = format!(
        r#"{{"sapling_build_version":1,"network":"main","target_height":10,
                 "regtest_nu63_activation_height":130,
                 "fee_zatoshis":10000,"seed":"{seed}","account":0,
                 "spend_notes":[{{"value_zatoshis":100000}}],
                 "outputs":[{{"address":"zs1invalid","value_zatoshis":90000}}]}}"#,
        seed = TEST_SEED_HEX,
    );
    let v = build_sapling_value(&request);
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "unsupported_activation_override");
    assert!(
        !v.to_string().contains(TEST_SEED_HEX),
        "refusal must not echo the seed"
    );
}

#[test]
#[cfg(feature = "sapling-spend-build")]
fn build_sapling_transaction_real_proving_with_supplied_params() {
    let spend_path = match std::env::var("ZCASH_SAPLING_SPEND_PARAMS") {
        Ok(p) if !p.is_empty() => p,
        _ => {
            eprintln!(
                "skipping real Sapling proving test: set \
                     ZCASH_SAPLING_SPEND_PARAMS and ZCASH_SAPLING_OUTPUT_PARAMS \
                     to the real Sapling parameter files to run it"
            );
            return;
        }
    };
    let output_path = match std::env::var("ZCASH_SAPLING_OUTPUT_PARAMS") {
        Ok(p) if !p.is_empty() => p,
        _ => {
            eprintln!(
                "skipping real Sapling proving test: \
                     ZCASH_SAPLING_OUTPUT_PARAMS is not set"
            );
            return;
        }
    };

    let to = regtest_sapling_address();
    let base = format!(
        r#""sapling_build_version":1,"network":"regtest","target_height":10,
               "fee_zatoshis":10000,"seed":"{seed}","account":0,
               "spend_notes":[{{"value_zatoshis":100000}}],
               "outputs":[{{"address":"{to}","value_zatoshis":90000}}]"#,
        seed = TEST_SEED_HEX,
        to = to,
    );
    let real_request = format!(
        r#"{{{base},"spend_params_path":{spend:?},"output_params_path":{output:?}}}"#,
        base = base,
        spend = spend_path,
        output = output_path,
    );
    let real = build_sapling_value(&real_request);
    assert_eq!(real["status"], "ok", "real build should succeed: {real}");
    assert_eq!(
        real["proof_validity"], "real",
        "caller-supplied parameters must yield real proofs"
    );
    assert_eq!(real["version"], "v5");
    assert_eq!(real["sapling"]["spends"], 1);

    let tx_hex = real["transaction"].as_str().expect("transaction hex");
    let net = cptr("regtest");
    let decoded = result_value(zcash_ffi_decode_transaction(
        cptr(tx_hex).as_ptr(),
        net.as_ptr(),
    ));
    assert_eq!(decoded["status"], "ok");
    assert_eq!(decoded["sapling"]["present"], true);
    assert_eq!(decoded["txid"], real["txid"]);

    let placeholder_request = format!("{{{base}}}", base = base);
    let placeholder = build_sapling_value(&placeholder_request);
    assert_eq!(placeholder["proof_validity"], "placeholder");
    assert_ne!(
        real["transaction"], placeholder["transaction"],
        "real proofs must differ from the all-zero placeholder proofs"
    );

    let out = real.to_string();
    assert!(!out.contains(TEST_SEED_HEX), "must not echo the seed");
    assert!(!out.contains(&spend_path), "must not echo the spend path");
    assert!(!out.contains(&output_path), "must not echo the output path");
}

#[test]
#[cfg(feature = "sapling-spend-build")]
fn build_sapling_transaction_rejects_missing_params_without_echo() {
    let to = regtest_sapling_address();
    let missing = "/nonexistent/zcash/sapling-spend.params";
    let request = format!(
        r#"{{"sapling_build_version":1,"network":"regtest","target_height":10,
                 "fee_zatoshis":10000,"seed":"{seed}","account":0,
                 "spend_notes":[{{"value_zatoshis":100000}}],
                 "outputs":[{{"address":"{to}","value_zatoshis":90000}}],
                 "spend_params_path":"{missing}","output_params_path":"{missing}"}}"#,
        seed = TEST_SEED_HEX,
        to = to,
        missing = missing,
    );
    let v = build_sapling_value(&request);
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "params_not_found");
    assert!(
        !v.to_string().contains(missing),
        "error must not echo the supplied parameter path"
    );
}

#[test]
#[cfg(feature = "sapling-spend-build")]
fn build_sapling_transaction_rejects_half_specified_params() {
    let to = regtest_sapling_address();
    let request = format!(
        r#"{{"sapling_build_version":1,"network":"regtest","target_height":10,
                 "fee_zatoshis":10000,"seed":"{seed}","account":0,
                 "spend_notes":[{{"value_zatoshis":100000}}],
                 "outputs":[{{"address":"{to}","value_zatoshis":90000}}],
                 "spend_params_path":"/some/path"}}"#,
        seed = TEST_SEED_HEX,
        to = to,
    );
    let v = build_sapling_value(&request);
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "invalid_request");
}

#[test]
#[cfg(feature = "sapling-spend-build")]
fn build_sapling_transaction_randomness_repeats_only_when_asked() {
    let to = regtest_sapling_address();
    let request = |seeded: &str| {
        format!(
            r#"{{"sapling_build_version":1,"network":"regtest","target_height":10,
                     {seeded}"fee_zatoshis":10000,"seed":"{seed}","account":0,
                     "spend_notes":[{{"value_zatoshis":100000}}],
                     "outputs":[{{"address":"{to}","value_zatoshis":90000}}]}}"#,
            seeded = seeded,
            seed = TEST_SEED_HEX,
            to = to,
        )
    };

    let first = build_sapling_value(&request(""));
    let second = build_sapling_value(&request(""));
    assert_eq!(first["status"], "ok", "{first}");
    assert_eq!(first["rng"], "os");
    assert_ne!(
        first["transaction"], second["transaction"],
        "two identical requests must not produce the same transaction"
    );
    assert_ne!(first["txid"], second["txid"]);

    let seeded = format!(r#""rng_seed":"{}","#, "0c".repeat(32));
    let a = build_sapling_value(&request(&seeded));
    let b = build_sapling_value(&request(&seeded));
    assert_eq!(a["status"], "ok", "{a}");
    assert_eq!(a["rng"], "deterministic");
    assert_eq!(
        a["transaction"], b["transaction"],
        "one stated seed, one artifact"
    );
    assert_ne!(a["transaction"], first["transaction"]);
}

#[test]
#[cfg(feature = "sapling-spend-build")]
fn build_sapling_transaction_supports_transparent_output() {
    let regtest = cptr("regtest");
    let t_addr = viewing_keys_value(TEST_SEED_HEX, &regtest, 0)["transparent"]
        ["default_external_address"]
        .as_str()
        .expect("regtest transparent default address")
        .to_owned();
    let request = format!(
        r#"{{"sapling_build_version":1,"network":"regtest","target_height":10,
                 "fee_zatoshis":10000,"seed":"{seed}","account":0,
                 "spend_notes":[{{"value_zatoshis":100000}}],
                 "outputs":[{{"address":"{to}","value_zatoshis":90000}}]}}"#,
        seed = TEST_SEED_HEX,
        to = t_addr,
    );
    let v = build_sapling_value(&request);
    assert_eq!(v["status"], "ok", "build should succeed: {v}");
    assert_eq!(v["sapling"]["spends"], 1);
    assert_eq!(v["transparent"]["vout"], 1);
}

#[test]
#[cfg(feature = "sapling-spend-build")]
fn build_sapling_transaction_rejects_unified_output_without_echo() {
    let main = cptr("main");
    let ufvk = account_ufvk(&main);
    let ua = ufvk_to_address_value(&ufvk, &main, 0)["ua"]
        .as_str()
        .expect("mainnet ua")
        .to_owned();
    let request = format!(
        r#"{{"sapling_build_version":1,"network":"main","target_height":2500000,
                 "fee_zatoshis":10000,"seed":"{seed}","account":0,
                 "spend_notes":[{{"value_zatoshis":100000}}],
                 "outputs":[{{"address":"{to}","value_zatoshis":90000}}]}}"#,
        seed = TEST_SEED_HEX,
        to = ua,
    );
    let v = build_sapling_value(&request);
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "unsupported_shielded_output");
    assert!(
        !v.to_string().contains(TEST_SEED_HEX),
        "shielded rejection must not echo the seed"
    );
}

#[test]
#[cfg(feature = "sapling-spend-build")]
fn build_sapling_transaction_rejects_unbalanced_inputs() {
    let to = regtest_sapling_address();
    let request = format!(
        r#"{{"sapling_build_version":1,"network":"regtest","target_height":10,
                 "fee_zatoshis":10000,"seed":"{seed}","account":0,
                 "spend_notes":[{{"value_zatoshis":100000}}],
                 "outputs":[{{"address":"{to}","value_zatoshis":95000}}]}}"#,
        seed = TEST_SEED_HEX,
        to = to,
    );
    let v = build_sapling_value(&request);
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "insufficient_funds");
}

#[test]
#[cfg(feature = "sapling-spend-build")]
fn build_sapling_transaction_rejects_short_seed_without_echo() {
    let to = regtest_sapling_address();
    let short_seed = "00".repeat(16);
    let request = format!(
        r#"{{"sapling_build_version":1,"network":"regtest","target_height":10,
                 "fee_zatoshis":10000,"seed":"{seed}","account":0,
                 "spend_notes":[{{"value_zatoshis":100000}}],
                 "outputs":[{{"address":"{to}","value_zatoshis":90000}}]}}"#,
        seed = short_seed,
        to = to,
    );
    let v = build_sapling_value(&request);
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "invalid_seed");
    assert!(!v.to_string().contains(&short_seed));
}

#[test]
#[cfg(feature = "sapling-spend-build")]
fn build_sapling_transaction_rejects_unsupported_version_and_bad_json() {
    let v = build_sapling_value(r#"{"sapling_build_version":2}"#);
    assert_eq!(v["category"], "unsupported_sapling_build_version");

    let v = build_sapling_value("not json");
    assert_eq!(v["category"], "invalid_json");

    let v = build_sapling_value(r#"{"network":"regtest"}"#);
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "invalid_request");
}

#[cfg(feature = "sapling-spend-build")]
fn test_seed_bytes() -> Vec<u8> {
    hex::decode(TEST_SEED_HEX).expect("seed hex")
}

#[test]
#[cfg(feature = "sapling-spend-build")]
fn build_sapling_transaction_builds_with_caller_supplied_real_note() {
    let rseed = [42u8; 32];
    let (recipient, rseed_hex, witness_hex, anchor_hex) =
        super::sapling_build::real_note_fixture(&test_seed_bytes(), 0, 100000, rseed);
    let request = format!(
        r#"{{"sapling_build_version":1,"network":"regtest","target_height":10,
                 "fee_zatoshis":10000,"seed":"{seed}","account":0,
                 "spend_notes":[{{"value_zatoshis":100000,"recipient":"{recipient}",
                   "rseed":"{rseed}","witness":"{witness}","anchor":"{anchor}"}}],
                 "outputs":[{{"address":"{recipient}","value_zatoshis":90000}}]}}"#,
        seed = TEST_SEED_HEX,
        recipient = recipient,
        rseed = rseed_hex,
        witness = witness_hex,
        anchor = anchor_hex,
    );
    let v = build_sapling_value(&request);
    assert_eq!(v["status"], "ok", "real-note build should succeed: {v}");
    assert_eq!(v["version"], "v5");
    assert_eq!(v["sapling"]["spends"], 1);
    assert_eq!(v["total_spent_zatoshis"], 100000);
    assert_eq!(v["total_output_zatoshis"], 90000);
    assert_eq!(v["proof_validity"], "placeholder");

    let tx_hex = v["transaction"].as_str().expect("transaction hex");
    let net = cptr("regtest");
    let decoded = result_value(zcash_ffi_decode_transaction(
        cptr(tx_hex).as_ptr(),
        net.as_ptr(),
    ));
    assert_eq!(decoded["status"], "ok");
    assert_eq!(decoded["sapling"]["present"], true);
    assert_eq!(decoded["sapling"]["spends"], v["sapling"]["spends"]);
    assert_eq!(decoded["txid"], v["txid"]);

    assert!(
        !v.to_string().contains(TEST_SEED_HEX),
        "real-note build must not echo the seed"
    );
}

#[test]
#[cfg(feature = "sapling-spend-build")]
fn build_sapling_real_note_rejects_anchor_mismatch_without_echo() {
    let rseed = [7u8; 32];
    let (recipient, rseed_hex, witness_hex, anchor_hex) =
        super::sapling_build::real_note_fixture(&test_seed_bytes(), 0, 100000, rseed);
    let mut bad = hex::decode(&anchor_hex).unwrap();
    bad[0] ^= 0xff;
    let bad_anchor = hex::encode(&bad);
    let request = format!(
        r#"{{"sapling_build_version":1,"network":"regtest","target_height":10,
                 "fee_zatoshis":10000,"seed":"{seed}","account":0,
                 "spend_notes":[{{"value_zatoshis":100000,"recipient":"{recipient}",
                   "rseed":"{rseed}","witness":"{witness}","anchor":"{anchor}"}}],
                 "outputs":[{{"address":"{recipient}","value_zatoshis":90000}}]}}"#,
        seed = TEST_SEED_HEX,
        recipient = recipient,
        rseed = rseed_hex,
        witness = witness_hex,
        anchor = bad_anchor,
    );
    let v = build_sapling_value(&request);
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "witness_anchor_mismatch");
    assert!(
        !v.to_string().contains(TEST_SEED_HEX),
        "rejection must not echo the seed"
    );
}

#[test]
#[cfg(feature = "sapling-spend-build")]
fn build_sapling_real_note_rejects_unspendable_recipient_without_echo() {
    let other_seed = vec![0x99u8; 32];
    let rseed = [3u8; 32];
    let (recipient, rseed_hex, witness_hex, anchor_hex) =
        super::sapling_build::real_note_fixture(&other_seed, 0, 100000, rseed);
    let request = format!(
        r#"{{"sapling_build_version":1,"network":"regtest","target_height":10,
                 "fee_zatoshis":10000,"seed":"{seed}","account":0,
                 "spend_notes":[{{"value_zatoshis":100000,"recipient":"{recipient}",
                   "rseed":"{rseed}","witness":"{witness}","anchor":"{anchor}"}}],
                 "outputs":[{{"address":"{recipient}","value_zatoshis":90000}}]}}"#,
        seed = TEST_SEED_HEX,
        recipient = recipient,
        rseed = rseed_hex,
        witness = witness_hex,
        anchor = anchor_hex,
    );
    let v = build_sapling_value(&request);
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "note_not_spendable");
    assert!(!v.to_string().contains(TEST_SEED_HEX));
}

#[test]
#[cfg(feature = "sapling-spend-build")]
fn build_sapling_real_note_rejects_malformed_witness_without_echo() {
    let rseed = [11u8; 32];
    let (recipient, rseed_hex, _witness_hex, anchor_hex) =
        super::sapling_build::real_note_fixture(&test_seed_bytes(), 0, 100000, rseed);
    let request = format!(
        r#"{{"sapling_build_version":1,"network":"regtest","target_height":10,
                 "fee_zatoshis":10000,"seed":"{seed}","account":0,
                 "spend_notes":[{{"value_zatoshis":100000,"recipient":"{recipient}",
                   "rseed":"{rseed}","witness":"zzzz","anchor":"{anchor}"}}],
                 "outputs":[{{"address":"{recipient}","value_zatoshis":90000}}]}}"#,
        seed = TEST_SEED_HEX,
        recipient = recipient,
        rseed = rseed_hex,
        anchor = anchor_hex,
    );
    let v = build_sapling_value(&request);
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "invalid_request");
    assert!(!v.to_string().contains(TEST_SEED_HEX));
}

#[test]
#[cfg(feature = "sapling-spend-build")]
fn build_sapling_rejects_mixed_real_and_synthesized_notes() {
    let rseed = [5u8; 32];
    let (recipient, rseed_hex, witness_hex, anchor_hex) =
        super::sapling_build::real_note_fixture(&test_seed_bytes(), 0, 60000, rseed);
    let request = format!(
        r#"{{"sapling_build_version":1,"network":"regtest","target_height":10,
                 "fee_zatoshis":10000,"seed":"{seed}","account":0,
                 "spend_notes":[
                   {{"value_zatoshis":60000,"recipient":"{recipient}","rseed":"{rseed}",
                     "witness":"{witness}","anchor":"{anchor}"}},
                   {{"value_zatoshis":40000}}],
                 "outputs":[{{"address":"{recipient}","value_zatoshis":90000}}]}}"#,
        seed = TEST_SEED_HEX,
        recipient = recipient,
        rseed = rseed_hex,
        witness = witness_hex,
        anchor = anchor_hex,
    );
    let v = build_sapling_value(&request);
    assert_eq!(v["status"], "error");
    assert_eq!(v["category"], "invalid_request");
}

#[test]
#[cfg(feature = "sapling-spend-build")]
fn build_sapling_real_note_is_deterministic() {
    let rseed = [21u8; 32];
    let (recipient, rseed_hex, witness_hex, anchor_hex) =
        super::sapling_build::real_note_fixture(&test_seed_bytes(), 0, 100000, rseed);
    let request = format!(
        r#"{{"sapling_build_version":1,"network":"regtest","target_height":10,
                 "rng_seed":"0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d",
                 "fee_zatoshis":10000,"seed":"{seed}","account":0,
                 "spend_notes":[{{"value_zatoshis":100000,"recipient":"{recipient}",
                   "rseed":"{rseed}","witness":"{witness}","anchor":"{anchor}"}}],
                 "outputs":[{{"address":"{recipient}","value_zatoshis":90000}}]}}"#,
        seed = TEST_SEED_HEX,
        recipient = recipient,
        rseed = rseed_hex,
        witness = witness_hex,
        anchor = anchor_hex,
    );
    let first = build_sapling_value(&request);
    let second = build_sapling_value(&request);
    assert_eq!(first["status"], "ok", "build should succeed: {first}");
    assert_eq!(
        first["transaction"], second["transaction"],
        "one stated seed, one artifact — even spending a real note"
    );
}
