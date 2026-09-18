# Provenance policy

Format knowledge should identify its source.

Priority: Microsoft/Open Specifications; controlled Publisher fixtures and binary diffs; independent corpora/implementations; existing open-source implementations; explicit hypotheses.

## libmspub
libmspub is MPL-2.0 and is used as a behavioral/reference oracle. Do not mechanically translate substantial source or large tables into Apache-2.0 files without reviewing licensing consequences.

## Unknown data
Unknown does not mean disposable. Preserve raw identifiers, flags, payloads and source ranges whenever practical.

## Fixtures
Committed fixtures need origin, redistribution rationale, SHA-256, known format family and the behavior they prove. Large corpora should normally stay external and be referenced by manifest/hash.
