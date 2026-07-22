#[cfg(any(
    feature = "orchard-tx-build",
    feature = "ironwood-tx-build",
    feature = "sapling-spend-build"
))]
pub enum BuildRng {
    Os(rand_core::OsRng),
    Deterministic(Box<rand_chacha::ChaCha20Rng>),
}

#[cfg(any(
    feature = "orchard-tx-build",
    feature = "ironwood-tx-build",
    feature = "sapling-spend-build"
))]
impl rand_core::RngCore for BuildRng {
    fn next_u32(&mut self) -> u32 {
        match self {
            BuildRng::Os(r) => r.next_u32(),
            BuildRng::Deterministic(r) => r.next_u32(),
        }
    }
    fn next_u64(&mut self) -> u64 {
        match self {
            BuildRng::Os(r) => r.next_u64(),
            BuildRng::Deterministic(r) => r.next_u64(),
        }
    }
    fn fill_bytes(&mut self, dest: &mut [u8]) {
        match self {
            BuildRng::Os(r) => r.fill_bytes(dest),
            BuildRng::Deterministic(r) => r.fill_bytes(dest),
        }
    }
    fn try_fill_bytes(&mut self, dest: &mut [u8]) -> Result<(), rand_core::Error> {
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
impl rand_core::CryptoRng for BuildRng {}

/// Only for transparent-only builds, which consume no randomness (RFC 6979 nonces).
#[cfg(feature = "transparent-tx-build")]
pub struct ZeroRng;

#[cfg(feature = "transparent-tx-build")]
impl rand_core::RngCore for ZeroRng {
    fn next_u32(&mut self) -> u32 {
        0
    }
    fn next_u64(&mut self) -> u64 {
        0
    }
    fn fill_bytes(&mut self, dest: &mut [u8]) {
        for byte in dest.iter_mut() {
            *byte = 0;
        }
    }
    fn try_fill_bytes(&mut self, dest: &mut [u8]) -> Result<(), rand_core::Error> {
        self.fill_bytes(dest);
        Ok(())
    }
}

#[cfg(feature = "transparent-tx-build")]
impl rand_core::CryptoRng for ZeroRng {}

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

    fn create_proof<R: rand_core::RngCore>(
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

    fn create_proof<R: rand_core::RngCore>(
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
