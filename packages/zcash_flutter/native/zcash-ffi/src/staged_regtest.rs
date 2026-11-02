use zcash_protocol::consensus::BlockHeight;
use zcash_protocol::local_consensus::LocalNetwork;

pub(crate) fn params(nu6_3: Option<u32>) -> LocalNetwork {
    LocalNetwork {
        overwinter: Some(BlockHeight::from_u32(1)),
        sapling: Some(BlockHeight::from_u32(1)),
        blossom: Some(BlockHeight::from_u32(1)),
        heartwood: Some(BlockHeight::from_u32(1)),
        canopy: Some(BlockHeight::from_u32(1)),
        nu5: Some(BlockHeight::from_u32(1)),
        nu6: Some(BlockHeight::from_u32(1)),
        nu6_1: Some(BlockHeight::from_u32(1)),
        nu6_2: Some(BlockHeight::from_u32(1)),
        nu6_3: nu6_3.map(BlockHeight::from_u32),
        nu7: None,
    }
}

#[cfg(all(
    test,
    any(feature = "orchard-tx-build", feature = "ironwood-tx-build")
))]
pub(crate) fn nu7_params(nu6_3: Option<u32>) -> LocalNetwork {
    LocalNetwork {
        nu7: Some(BlockHeight::from_u32(1)),
        ..params(nu6_3)
    }
}

#[cfg(any(
    feature = "orchard-tx-build",
    feature = "ironwood-tx-build",
    feature = "sapling-spend-build"
))]
pub(crate) fn read_activation_height(
    request: &serde_json::Value,
    network: zcash_protocol::consensus::NetworkType,
) -> Result<Option<u32>, (String, String)> {
    let raw = match request.get("regtest_nu63_activation_height") {
        None => return Ok(None),
        Some(v) => v,
    };
    if network != zcash_protocol::consensus::NetworkType::Regtest {
        return Err((
            "unsupported_activation_override".to_string(),
            "regtest_nu63_activation_height applies to regtest only; on \
                 mainnet and testnet the NU6.3 activation height is consensus \
                 (3,428,143 and 4,134,000), and overriding it would sign the \
                 transaction under a branch that is not in effect"
                .to_string(),
        ));
    }
    let height = raw
        .as_u64()
        .filter(|h| *h > 0 && *h <= u64::from(u32::MAX))
        .ok_or_else(|| {
            (
                "invalid_height".to_string(),
                "regtest_nu63_activation_height is out of range".to_string(),
            )
        })?;
    Ok(Some(height as u32))
}
