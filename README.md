# pub-rs

A lossless, research-driven Rust implementation of the Microsoft Publisher (`.pub`) file format.

The long-term goal is a native reader **and writer** that preserves unknown data, keeps cross-stream identity intact, and can edit Publisher files without flattening them into a generic drawing model.

> Status: very early. The repository is being bootstrapped from a large reverse-engineering corpus and differential testing against existing implementations.

## Design principles

- **Lossless first.** Unknown records and properties are preserved instead of discarded.
- **Raw + semantic.** Every decoded value should retain provenance back to the source stream and byte range.
- **Native identities matter.** Contents, Quill, Escher and other projections are joined through an explicit identity graph.
- **Rendering is a consumer, not the source of truth.**
- **Writer-oriented architecture.** The model is designed for selective reserialization and eventual native `.pub` writing.
- **Evidence over guesses.** Non-trivial format claims should carry provenance to a public specification, source implementation, or reproducible fixture.

## Initial workspace

The first milestone is deliberately smaller than full Publisher support:

```text
pub-core      raw spans, diagnostics, shared IDs
pub-cfb       Compound File Binary inventory/access
pub-contents  Publisher Contents stream structures
pub-quill     Quill text/style structures
pub-escher    OfficeArt/Escher/FOPT structures
pub-model     canonical Publisher semantic/identity model
pub-cli       inspection and validation commands
```

The first useful command is:

```bash
cargo run -p pub-cli -- inspect path/to/file.pub --json
```

Initially it reports the CFB structure. Contents, Quill, Escher and semantic lifting will be added incrementally.

## Relationship to libmspub

`libmspub` is a valuable behavioral oracle and historical source of format knowledge, but `pub-rs` is not intended to be a line-for-line Rust port. In particular, the canonical model here must preserve raw/unknown state needed by a future writer.

See [docs/PROVENANCE.md](docs/PROVENANCE.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## CI policy

Normal pull-request CI is intentionally cheap: one Linux job runs formatting, check, Clippy and tests. Expensive corpus, fuzzing and differential workflows are manual until they justify their cost.

## License

Apache License 2.0. Individual imported/derived files may carry different compatible notices when required; see provenance documentation.
