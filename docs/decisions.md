# Decisions
___


One entry per choice. A choice is changed only by a new entry, so the old reasoning stays.

| # | Decision | Values | Why | Source | Change |
| --- | --- | --- | --- | --- | --- |
| 1 | v2 built beside v1 in the same repo, v1 kept as branch `v1` | Recovery, Management | old install keeps working, every version can be compared | judgment | [compare](https://github.com/surs-k/nug/compare/v1...v2) |
| 2 | The changelog is a program, `changes`, reading the commit history, no CHANGELOG.md | Visuals, Concise | one click from a line to its exact lines, nothing to keep in sync by hand | judgment | `scripts/changes.sh` |
