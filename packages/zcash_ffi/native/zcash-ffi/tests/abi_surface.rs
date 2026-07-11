const LIB_RS: &str = include_str!("../src/lib.rs");

const EXPECTED_SYMBOLS: &[&str] = &[
    "zcash_ffi_free_string",
    "zcash_ffi_hex_decode",
    "zcash_ffi_network_constants",
    "zcash_ffi_version",
];

fn exported_symbols() -> Vec<String> {
    const MARKER: &str = "extern \"C\" fn ";
    let mut names = Vec::new();
    for (idx, _) in LIB_RS.match_indices(MARKER) {
        let rest = &LIB_RS[idx + MARKER.len()..];
        let name: String = rest
            .chars()
            .take_while(|c| c.is_alphanumeric() || *c == '_')
            .collect();
        if !name.is_empty() {
            names.push(name);
        }
    }
    names.sort();
    names.dedup();
    names
}

#[test]
fn no_mangle_marks_every_export() {
    let extern_count = LIB_RS.matches("extern \"C\" fn ").count();
    let no_mangle_count = LIB_RS.matches("#[no_mangle]").count();
    assert_eq!(
        extern_count, no_mangle_count,
        "every `extern \"C\" fn` must be paired with `#[no_mangle]` to be a \
         stable exported symbol (found {extern_count} extern fns, \
         {no_mangle_count} #[no_mangle] attributes)"
    );
}

#[test]
fn exported_symbol_set_is_pinned() {
    let actual = exported_symbols();
    let expected: Vec<String> = EXPECTED_SYMBOLS.iter().map(|s| s.to_string()).collect();

    let missing: Vec<&String> = expected.iter().filter(|s| !actual.contains(s)).collect();
    let unexpected: Vec<&String> = actual.iter().filter(|s| !expected.contains(s)).collect();

    assert!(
        missing.is_empty() && unexpected.is_empty(),
        "exported C ABI surface drifted from the pinned list.\n  missing (in \
         expected list, not in source): {missing:?}\n  unexpected (in source, \
         not in expected list): {unexpected:?}\n\nThis is an ABI change. Update \
         EXPECTED_SYMBOLS in the same commit."
    );

    assert_eq!(
        actual.len(),
        EXPECTED_SYMBOLS.len(),
        "duplicate or miscounted symbols: {actual:?}"
    );
}
