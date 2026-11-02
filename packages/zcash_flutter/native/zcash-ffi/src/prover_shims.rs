#[cfg(any(
    feature = "orchard-tx-build",
    feature = "ironwood-tx-build",
    feature = "sapling-spend-build"
))]
pub enum BuildRng {
    Os(rand_core::UnwrapErr<rand::rngs::SysRng>),
    Deterministic(Box<rand_chacha::ChaCha20Rng>),
}

#[cfg(any(
    feature = "orchard-tx-build",
    feature = "ironwood-tx-build",
    feature = "sapling-spend-build"
))]
impl BuildRng {
    pub fn os() -> Self {
        Self::Os(rand_core::UnwrapErr(rand::rngs::SysRng))
    }
}

#[cfg(any(
    feature = "orchard-tx-build",
    feature = "ironwood-tx-build",
    feature = "sapling-spend-build"
))]
impl rand_core::TryRng for BuildRng {
    type Error = core::convert::Infallible;

    fn try_next_u32(&mut self) -> Result<u32, Self::Error> {
        match self {
            BuildRng::Os(r) => r.try_next_u32(),
            BuildRng::Deterministic(r) => r.try_next_u32(),
        }
    }
    fn try_next_u64(&mut self) -> Result<u64, Self::Error> {
        match self {
            BuildRng::Os(r) => r.try_next_u64(),
            BuildRng::Deterministic(r) => r.try_next_u64(),
        }
    }
    fn try_fill_bytes(&mut self, dest: &mut [u8]) -> Result<(), Self::Error> {
        match self {
            BuildRng::Os(r) => r.try_fill_bytes(dest),
            BuildRng::Deterministic(r) => r.try_fill_bytes(dest),
        }
    }
}

#[cfg(any(
    feature = "orchard-tx-build",
    feature = "ironwood-tx-build",
    feature = "sapling-spend-build"
))]
impl rand_core::TryCryptoRng for BuildRng {}

/// Only for transparent-only builds, which consume no randomness (RFC 6979 nonces).
#[cfg(feature = "transparent-tx-build")]
pub struct ZeroRng;

#[cfg(feature = "transparent-tx-build")]
impl rand_core::TryRng for ZeroRng {
    type Error = core::convert::Infallible;

    fn try_next_u32(&mut self) -> Result<u32, Self::Error> {
        Ok(0)
    }
    fn try_next_u64(&mut self) -> Result<u64, Self::Error> {
        Ok(0)
    }
    fn try_fill_bytes(&mut self, dest: &mut [u8]) -> Result<(), Self::Error> {
        for byte in dest.iter_mut() {
            *byte = 0;
        }
        Ok(())
    }
}

#[cfg(feature = "transparent-tx-build")]
impl rand_core::TryCryptoRng for ZeroRng {}

#[cfg(any(
    feature = "transparent-tx-build",
    feature = "orchard-tx-build",
    feature = "ironwood-tx-build"
))]
pub struct NoProver;

#[cfg(any(
    feature = "transparent-tx-build",
    feature = "orchard-tx-build",
    feature = "ironwood-tx-build"
))]
impl sapling::prover::SpendProver for NoProver {
    type Proof = sapling::bundle::GrothProofBytes;

    fn prepare_circuit(
        _proof_generation_key: sapling::ProofGenerationKey,
        _diversifier: sapling::Diversifier,
        _rseed: sapling::Rseed,
        _value: sapling::value::NoteValue,
        _alpha: jubjub::Fr,
        _rcv: sapling::value::ValueCommitTrapdoor,
        _anchor: bls12_381::Scalar,
        _merkle_path: sapling::MerklePath,
    ) -> Option<sapling::circuit::Spend> {
        None
    }

    fn create_proof<R: rand_core::Rng>(
        &self,
        _circuit: sapling::circuit::Spend,
        _rng: &mut R,
    ) -> Self::Proof {
        unreachable!("this build path never proves Sapling spends")
    }

    fn encode_proof(proof: Self::Proof) -> sapling::bundle::GrothProofBytes {
        proof
    }
}

#[cfg(any(
    feature = "transparent-tx-build",
    feature = "orchard-tx-build",
    feature = "ironwood-tx-build"
))]
impl sapling::prover::OutputProver for NoProver {
    type Proof = sapling::bundle::GrothProofBytes;

    fn prepare_circuit(
        _esk: &sapling::keys::EphemeralSecretKey,
        _payment_address: sapling::PaymentAddress,
        _rcm: jubjub::Fr,
        _value: sapling::value::NoteValue,
        _rcv: sapling::value::ValueCommitTrapdoor,
    ) -> sapling::circuit::Output {
        unreachable!("this build path never proves Sapling outputs")
    }

    fn create_proof<R: rand_core::Rng>(
        &self,
        _circuit: sapling::circuit::Output,
        _rng: &mut R,
    ) -> Self::Proof {
        unreachable!("this build path never proves Sapling outputs")
    }

    fn encode_proof(proof: Self::Proof) -> sapling::bundle::GrothProofBytes {
        proof
    }
}
