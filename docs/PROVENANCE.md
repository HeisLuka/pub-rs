# Provenance policy

Format knowledge should identify its source, confidence and scope.

Priority: Microsoft/Open Specifications; controlled Publisher fixtures and binary diffs; independent corpora/implementations; existing open-source implementations; explicit hypotheses.

## Foundation admission rule

A fact may enter foundation code only when all of the following are explicit:

- **source** — where the fact comes from;
- **status** — confirmed fact, implementation fact, hypothesis, open question, etc.;
- **scope** — the binary family/version/object classes for which it is supported;
- **guardrail** — what must not be inferred from the evidence.

Implementation facts about another parser are not automatically facts about native Publisher.

If evidence proves only framing, width, offsets or raw flag layout, the code should preserve that physical fact without inventing stronger semantic names.

## libmspub
libmspub is MPL-2.0 and is used as a behavioral/reference oracle. Do not mechanically translate substantial source or large tables into Apache-2.0 files without reviewing licensing consequences.

## Unknown data
Unknown does not mean disposable. Preserve raw identifiers, flags, payloads and source ranges. Prefer references into the immutable raw backing when possible so future decoders can reinterpret the original bytes.

## Fixtures
Committed fixtures need origin, redistribution rationale, SHA-256, known format family and the behavior they prove. Large corpora should normally stay external and be referenced by manifest/hash.
