# Contributing

## Before coding

For non-trivial format behavior, open or reference an issue that states the evidence source: specification, controlled fixture/diff, independent implementation, or explicit hypothesis.

## Pull requests

Keep changes narrow. Add a regression test whenever behavior can be represented by a small fixture or synthetic byte sequence.

Do not silently discard unknown records/properties. If a parser cannot interpret data yet, preserve enough raw state and provenance for later analysis or writing.

## Licensing

Do not mechanically port substantial libmspub code or large tables into Apache-2.0 files without first documenting the provenance and checking MPL-2.0 obligations.

## CI

Normal CI is intentionally small. Expensive corpus, fuzzing, Miri and differential checks belong in the manual heavy workflow unless there is a strong reason to promote them.
