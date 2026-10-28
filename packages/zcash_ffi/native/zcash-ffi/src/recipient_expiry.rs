//! ZIP 316 Revision 2 recipient expiry, enforced with the rules of
//! `zcash_client_backend::data_api::wallet::check_recipient_expiry`.

use serde_json::Value;
use zcash_keys::address::UnifiedAddress;
use zcash_protocol::consensus::BlockHeight;

pub(crate) struct Refusal {
    pub category: &'static str,
    pub message: String,
}

fn refuse(category: &'static str, message: String) -> Refusal {
    Refusal { category, message }
}

/// Reads `current_unix_time`, which a payment to an address carrying an expiry time
/// needs; the builders have no clock of their own.
pub(crate) fn read_current_unix_time(request: &Value) -> Result<Option<u64>, Refusal> {
    match request.get("current_unix_time") {
        None => Ok(None),
        Some(v) => v.as_u64().map(Some).ok_or_else(|| {
            refuse(
                "invalid_request",
                "current_unix_time must be a non-negative integer".to_string(),
            )
        }),
    }
}

/// The chain tip that expiry is judged against is one below `target_height`, as
/// upstream. The transaction expiry is never lowered to fit the address: an expiry
/// derived from the recipient's metadata would reveal it on chain.
pub(crate) fn check(
    ua: &UnifiedAddress,
    target_height: BlockHeight,
    tx_expiry_height: BlockHeight,
    current_unix_time: Option<u64>,
) -> Result<(), Refusal> {
    if let Some(address_expiry) = ua.expiry_height() {
        let chain_height = target_height.saturating_sub(1);
        if chain_height > address_expiry {
            return Err(refuse(
                "recipient_address_expired",
                format!(
                    "the recipient address expired at height {address_expiry}, and the \
                     chain has reached height {chain_height}"
                ),
            ));
        }
        if u32::from(tx_expiry_height) == 0 {
            return Err(refuse(
                "recipient_expiry_conflict",
                format!(
                    "the recipient address expires at height {address_expiry}, which \
                     requires the transaction to carry a nonzero expiry height"
                ),
            ));
        }
        if tx_expiry_height > address_expiry {
            return Err(refuse(
                "recipient_expiry_conflict",
                format!(
                    "the transaction would expire at height {tx_expiry_height}, after the \
                     recipient address's expiry height {address_expiry}"
                ),
            ));
        }
    }

    if let Some(expiry_time) = ua.expiry_time() {
        let Some(now) = current_unix_time else {
            return Err(refuse(
                "recipient_expiry_time_unchecked",
                format!(
                    "the recipient address expires at Unix time {expiry_time}; pass \
                     current_unix_time so the payment can be checked against it"
                ),
            ));
        };
        if now > expiry_time {
            return Err(refuse(
                "recipient_address_expired",
                format!("the recipient address expired at Unix time {expiry_time}"),
            ));
        }
    }

    Ok(())
}
