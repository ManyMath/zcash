use super::parse_network_type_label;
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine as _;
use prost::Message as _;
use serde_json::{json, Value};
use zcash_client_backend::proto::compact_formats::{
    ChainMetadata, CompactBlock, CompactOrchardAction, CompactSaplingOutput, CompactSaplingSpend,
    CompactTx,
};
use zcash_primitives::block::Block;
use zcash_protocol::consensus::{Network, NetworkType, Parameters};
use zcash_protocol::local_consensus::LocalNetwork;

const COMPACT_BLOCK_VERSION: u64 = 1;

const COMPACT_NOTE_SIZE: usize = 52;

macro_rules! compact_action {
    ($action:expr) => {
        CompactOrchardAction {
            nullifier: $action.nullifier().to_bytes().to_vec(),
            cmx: $action.cmx().to_bytes().to_vec(),
            ephemeral_key: $action.encrypted_note().epk_bytes.to_vec(),
            ciphertext: $action.encrypted_note().enc_ciphertext.as_ref()[..COMPACT_NOTE_SIZE]
                .to_vec(),
        }
    };
}

type ConvertError = (String, String);

fn err(category: &str, message: &str) -> ConvertError {
    (category.to_string(), message.to_string())
}

#[derive(Clone, Copy, Default)]
struct TreeSizes {
    sapling: u64,
    orchard: u64,
    ironwood: u64,
}

fn read_size(request: &Value, field: &str) -> Result<u64, ConvertError> {
    match request.get(field) {
        None => Ok(0),
        Some(v) => v.as_u64().ok_or_else(|| {
            err(
                "invalid_request",
                &format!("{field} must be a non-negative integer"),
            )
        }),
    }
}

fn regtest_params(nu6_3: Option<u32>) -> LocalNetwork {
    super::staged_regtest::params(nu6_3)
}

pub fn compact_blocks_from_raw_blocks_json(request: &Value) -> Result<Value, ConvertError> {
    if !request.is_object() {
        return Err(err("invalid_request", "request must be a JSON object"));
    }
    if let Some(version) = request.get("compact_block_version") {
        match version.as_u64() {
            Some(v) if v == COMPACT_BLOCK_VERSION => {}
            _ => {
                return Err(err(
                    "unsupported_compact_block_version",
                    "compact_block_version must be 1",
                ))
            }
        }
    }

    let network_label = request
        .get("network")
        .and_then(Value::as_str)
        .ok_or_else(|| err("invalid_request", "network must be a string"))?;
    let network = parse_network_type_label(network_label).ok_or_else(|| {
        err(
            "unsupported_network",
            "network must be 'main', 'test', or 'regtest'",
        )
    })?;

    let activation = match request.get("regtest_nu63_activation_height") {
        None => None,
        Some(v) => {
            if network != NetworkType::Regtest {
                return Err(err(
                    "unsupported_activation_override",
                    "regtest_nu63_activation_height applies to regtest only; on \
                         mainnet and testnet the NU6.3 activation height is consensus",
                ));
            }
            Some(
                v.as_u64()
                    .filter(|h| *h > 0 && *h <= u64::from(u32::MAX))
                    .ok_or_else(|| {
                        err(
                            "invalid_height",
                            "regtest_nu63_activation_height is out of range",
                        )
                    })? as u32,
            )
        }
    };

    let sizes = TreeSizes {
        sapling: read_size(request, "prior_sapling_size")?,
        orchard: read_size(request, "prior_orchard_size")?,
        ironwood: read_size(request, "prior_ironwood_size")?,
    };

    let raw_blocks = request
        .get("blocks")
        .and_then(Value::as_array)
        .ok_or_else(|| err("invalid_request", "blocks must be an array"))?;

    match network {
        NetworkType::Main => convert(Network::MainNetwork, network, raw_blocks, sizes),
        NetworkType::Test => convert(Network::TestNetwork, network, raw_blocks, sizes),
        NetworkType::Regtest => convert(regtest_params(activation), network, raw_blocks, sizes),
    }
}

fn convert<P: Parameters>(
    params: P,
    network: NetworkType,
    raw_blocks: &[Value],
    mut sizes: TreeSizes,
) -> Result<Value, ConvertError> {
    let mut out = Vec::with_capacity(raw_blocks.len());
    for (index, raw) in raw_blocks.iter().enumerate() {
        let hex_str = raw
            .as_str()
            .ok_or_else(|| err("invalid_request", "each block must be a hex string"))?
            .trim();
        let bytes = hex::decode(hex_str)
            .map_err(|_| err("invalid_block", &format!("block {index} is not valid hex")))?;
        let block = Block::read(&bytes[..], &params).map_err(|_| {
            err(
                "invalid_block",
                &format!(
                    "block {index} could not be parsed under these network \
                         parameters; on regtest, check regtest_nu63_activation_height"
                ),
            )
        })?;
        let height = u32::from(block.claimed_height());

        let mut vtx = Vec::new();
        for (tx_index, tx) in block.vtx().iter().enumerate() {
            let mut ctx = CompactTx {
                index: tx_index as u64,
                // Protocol byte order, not the reversed RPC/explorer display form.
                txid: tx.txid().as_ref().to_vec(),
                ..Default::default()
            };

            if let Some(bundle) = tx.sapling_bundle() {
                for spend in bundle.shielded_spends() {
                    ctx.spends.push(CompactSaplingSpend {
                        nf: spend.nullifier().0.to_vec(),
                    });
                }
                for output in bundle.shielded_outputs() {
                    ctx.outputs.push(CompactSaplingOutput {
                        cmu: output.cmu().to_bytes().to_vec(),
                        ephemeral_key: output.ephemeral_key().0.to_vec(),
                        ciphertext: output.enc_ciphertext()[..COMPACT_NOTE_SIZE].to_vec(),
                    });
                }
                sizes.sapling += bundle.shielded_outputs().len() as u64;
            }

            if let Some(bundle) = tx.orchard_bundle() {
                for action in bundle.actions() {
                    ctx.actions.push(compact_action!(action));
                }
                sizes.orchard += bundle.actions().len() as u64;
            }

            if let Some(bundle) = tx.ironwood_bundle() {
                for action in bundle.actions() {
                    ctx.ironwood_actions.push(compact_action!(action));
                }
                sizes.ironwood += bundle.actions().len() as u64;
            }

            vtx.push(ctx);
        }

        let compact = CompactBlock {
            height: u64::from(height),
            hash: block.header().hash().0.to_vec(),
            prev_hash: block.header().prev_block.0.to_vec(),
            time: block.header().time,
            vtx,
            chain_metadata: Some(ChainMetadata {
                sapling_commitment_tree_size: sizes.sapling as u32,
                orchard_commitment_tree_size: sizes.orchard as u32,
                ironwood_commitment_tree_size: sizes.ironwood as u32,
            }),
            ..Default::default()
        };

        let mut encoded = Vec::new();
        compact
            .encode(&mut encoded)
            .map_err(|_| err("encode_failed", "could not encode the compact block"))?;

        out.push(json!({
            "height": height,
            "data": BASE64.encode(&encoded),
            "transactions": compact.vtx.len(),
            "sapling_outputs": compact.vtx.iter().map(|t| t.outputs.len()).sum::<usize>(),
            "orchard_actions": compact.vtx.iter().map(|t| t.actions.len()).sum::<usize>(),
            "ironwood_actions": compact.vtx.iter().map(|t| t.ironwood_actions.len()).sum::<usize>(),
        }));
    }

    Ok(json!({
        "network": super::network_type_label(network),
        "blocks": out,
        "sapling_commitment_tree_size": sizes.sapling,
        "orchard_commitment_tree_size": sizes.orchard,
        "ironwood_commitment_tree_size": sizes.ironwood,
    }))
}
