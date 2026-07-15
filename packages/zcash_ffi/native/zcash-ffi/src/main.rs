use std::ffi::CString;

fn call(ptr: *mut std::os::raw::c_char) -> String {
    unsafe {
        let s = std::ffi::CStr::from_ptr(ptr).to_str().unwrap().to_owned();
        zcash_ffi::zcash_ffi_free_string(ptr);
        s
    }
}

fn main() {
    let seed_hex: String = (0u8..64).map(|b| format!("{b:02x}")).collect();
    let network = "main";

    println!("=== zcash-ffi smoke test ===\n");

    let version = call(zcash_ffi::zcash_ffi_version());
    println!("version: {version}");

    let seed_c = CString::new(seed_hex.as_str()).unwrap();
    let net_c = CString::new(network).unwrap();

    let ufvk_json = call(zcash_ffi::zcash_ffi_seed_to_account_ufvk(
        seed_c.as_ptr(),
        net_c.as_ptr(),
        0,
    ));
    println!("\nUFVK (account 0):\n  {ufvk_json}");

    let ufvk_val: serde_json::Value = serde_json::from_str(&ufvk_json).unwrap();
    let ufvk_str = ufvk_val["ufvk"].as_str().unwrap();
    let ufvk_c = CString::new(ufvk_str).unwrap();

    let ua_json = call(zcash_ffi::zcash_ffi_ufvk_to_address(
        ufvk_c.as_ptr(),
        net_c.as_ptr(),
        0,
    ));
    println!("\nUnified address (diversifier 0):");
    let ua_val: serde_json::Value = serde_json::from_str(&ua_json).unwrap();
    for field in ["ua", "sapling", "orchard", "transparent"] {
        if let Some(v) = ua_val[field].as_str() {
            println!("  {field:<12}: {v}");
        }
    }

    let xpub_json = call(zcash_ffi::zcash_ffi_seed_to_transparent_xpub(
        seed_c.as_ptr(),
        net_c.as_ptr(),
        0,
    ));
    println!("\nxpub (account 0):\n  {xpub_json}");

    let xpub_val: serde_json::Value = serde_json::from_str(&xpub_json).unwrap();
    let xpub_str = xpub_val["xpub"].as_str().unwrap();
    let xpub_c = CString::new(xpub_str).unwrap();

    println!("\nTransparent child addresses:");
    for child in 0..3u32 {
        let addr_json = call(zcash_ffi::zcash_ffi_transparent_address(
            xpub_c.as_ptr(),
            net_c.as_ptr(),
            child,
        ));
        let v: serde_json::Value = serde_json::from_str(&addr_json).unwrap();
        println!(
            "  child {child}: {}",
            v["address"].as_str().unwrap_or("ERROR")
        );
    }

    println!("\nAddress classification:");
    let test_addrs = [
        ("t1c8oqrzA1kYPdgVhfDNUZn3buAbk6rXxiX", "transparent"),
        (
            "zs1zt3mq96vp65l8ch54r78nc50ml68qsyg3pkteq8pn8sfgzakhgw4vqn6px5w08hrf2uzuam5kmj",
            "sapling",
        ),
        (ua_val["ua"].as_str().unwrap_or(""), "unified"),
        ("notanaddress", "invalid"),
    ];
    for (addr, label) in test_addrs {
        let c = CString::new(addr).unwrap();
        let t = zcash_ffi::zcash_ffi_address_type(c.as_ptr());
        let is_t = zcash_ffi::zcash_ffi_is_transparent_address(c.as_ptr());
        let is_s = zcash_ffi::zcash_ffi_is_shielded_address(c.as_ptr());
        println!("  {label:<12}: type={t} transparent={is_t} shielded={is_s}");
    }
}
