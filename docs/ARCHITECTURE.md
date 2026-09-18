# Architecture

`pub-rs` separates persistence truth from convenient rendering models.

## Layers
1. **RawPublication** — byte-backed stream/record tree; unknown data is preserved.
2. **IdentityGraph** — native identifiers and cross-stream relationships.
3. **SemanticPublication** — pages, shapes, stories, styles and assets.
4. **ResolvedPublication** — effective values after defaults/inheritance.
5. **Projection writers** — Contents, Quill, Escher and other native projections.
6. **Render/export adapters** — consumers only; never canonical storage.

## First milestone
A lossless 0x2C-family inspector: enumerate CFB streams, retain provenance, decode Contents/Quill/Escher incrementally, emit deterministic JSON, preserve unknowns.

## Writer direction
`existing PUB -> semantic mutation -> dirty graph -> selective projection rebuild -> valid PUB`.
