# Decisions
___


One entry per choice. A choice is changed only by a new entry, so the old reasoning stays.

| # | Decision | Values | Why | Source | Change |
| --- | --- | --- | --- | --- | --- |
| 1 | v2 built beside v1 in the same repo, v1 kept as branch `v1` | Recovery, Management | old install keeps working, every version can be compared | judgment | [compare](https://github.com/surs-k/nug/compare/v1...v2) |
| 2 | The changelog is a window app, `changes`, reading the commit history, no CHANGELOG.md | Visuals, Concise, Educating | plain words first, exact lines on a click, notes copied to Claude, nothing to keep in sync by hand | judgment | `scripts/changes.py` |
| 3 | Changes manages any number of projects, any git repo, and is a project in itself | Management, Educating, Visuals | one calm place for every project, the app is held to the same standard it shows | judgment | `scripts/changes.py` |
