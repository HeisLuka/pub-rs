# Architecture

`pub-rs` separates persistence truth from convenient rendering models.

## Evidence gate

Foundation code may encode only facts whose evidence and scope are explicit.

- A raw fact stays raw until its semantics are demonstrated.
- A relationship stays as separate identities until the join is demonstrated.
- A fact proven for one binary family does not silently become universal.
- Hypotheses belong in research notes, experiments or explicitly marked decoders, not in canonical foundation types.
- New discoveries should extend the model rather than require reinterpreting previously preserved bytes.

## Layers
1. **RawPublication** — immutable byte-backed stream/record tree; unknown data is preserved.
2. **IdentityGraph** — native identifiers and demonstrated cross-stream relationships.
3. **SemanticPublication** — pages, shapes, stories, styles and assets lifted from raw projections.
4. **ResolvedPublication** — effective values after defaults/inheritance.
5. **Projection writers** — Contents, Quill, Escher and other native projections.
6. **Render/export adapters** — consumers only; never canonical storage.

## Identity rule

There is no universal Publisher `native_id` type.

Contents sequence/object identifiers, Quill story/text identifiers, OfficeArt shape/text identifiers and other native namespaces remain separate until a specific mapping is evidenced. Physical offsets are provenance, not semantic identity.

## Raw-byte rule

A `RawSpan` is a locator into an immutable `RawPublication`. Unknown and malformed items may therefore remain lossless without forcing every parser node to duplicate its payload.

Container paths are represented as `StreamPath`; they are not called `StreamId` because MS-CFB already defines stream ID as the numeric directory-entry identifier.

## First milestone
A lossless 0x2C-family inspector: enumerate CFB streams, retain provenance, decode Contents/Quill/Escher incrementally, emit deterministic JSON, preserve unknowns.

## Writer direction
`existing PUB -> semantic mutation -> dirty graph -> selective projection rebuild -> valid PUB`.
