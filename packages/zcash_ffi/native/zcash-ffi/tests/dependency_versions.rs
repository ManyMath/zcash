const CARGO_TOML: &str = include_str!("../Cargo.toml");

const PINNED_UPSTREAM: &[(&str, &str)] = &[
    ("zcash_client_backend", "0.25.0"),
    ("zcash_keys", "0.17.0"),
    ("zcash_primitives", "0.31.0"),
    ("zcash_proofs", "0.31"),
    ("zcash_address", "0.14"),
    ("zcash_protocol", "0.11.0"),
    ("zcash_script", "0.6"),
    ("zcash_transparent", "0.11"),
    ("zip32", "0.3"),
    ("equihash", "0.3"),
];

fn declared_version(crate_name: &str) -> Option<String> {
    for line in CARGO_TOML.lines() {
        let trimmed = line.trim_start();
        let prefix = format!("{crate_name} =");
        if !trimmed.starts_with(&prefix) {
            continue;
        }
        let rest = &trimmed[prefix.len()..];
        let search = if let Some(idx) = rest.find("version") {
            &rest[idx..]
        } else {
            rest
        };
        let start = search.find('"')? + 1;
        let end = search[start..].find('"')? + start;
        return Some(search[start..end].to_string());
    }
    None
}

#[test]
fn upstream_zcash_crate_versions_are_pinned() {
    let mut drift = Vec::new();
    for (name, expected) in PINNED_UPSTREAM {
        match declared_version(name) {
            Some(actual) if actual == *expected => {}
            Some(actual) => drift.push(format!(
                "{name}: Cargo.toml declares \"{actual}\", this test pins \"{expected}\""
            )),
            None => drift.push(format!("{name}: not found in Cargo.toml")),
        }
    }
    assert!(
        drift.is_empty(),
        "upstream Zcash dependency constraints drifted.\n  {}\n\n\
         Upgrade the Zcash crates together and update this pinned list in the same \
         commit.",
        drift.join("\n  ")
    );
}

#[test]
fn rust_edition_is_pinned() {
    assert!(
        CARGO_TOML.contains("edition = \"2021\""),
        "Rust edition changed"
    );
}
