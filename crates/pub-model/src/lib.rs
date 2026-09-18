//! Semantic-model boundary for PUB.
//!
//! This crate intentionally does not define a universal `native_id`, a
//! canonical text owner, or other guessed cross-projection fields yet.
//! Current evidence shows multiple native identity namespaces across Contents,
//! Quill and OfficeArt/Escher. Namespace-specific identities and joins should
//! be added only when their scope and evidence are explicit.
//!
//! The raw byte-backed layer lives in `pub-core`; low-level projection
//! parsers live in their respective crates. The semantic model will be lifted
//! from those projections rather than replacing them as the source of truth.
