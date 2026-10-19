# Verification — one record per file, and the decisions homed in them

What each file does, why it is written that way, and the decisions it is home to. This directory replaces `Old.md` (the history of
decisions, Japanese, to 2026-10-10) as the place a decision is read from. The decisions were taken out of it into these records;
`Old.md` is kept locally as `work_history/旧Old.md` (not in git) for how a decision came about, and is not added to. "Earlier:
`Old.md` §N" in a record names its section there. Decisions made after 2026-10-10 come from the commit messages and `document/scope.md`.

When a record and the code disagree, trust the code and fix the record (keep the disagreement in its notes).

## The files here

| File | What |
|---|---|
| [`decisions.md`](decisions.md) | every decision (`D-…`): what, its home record, where it came from in `Old.md`, and the withdrawn proposals |
| [`index.md`](index.md) | every file of the repository, one line, with its record when it has one |
| `<path with / as ->.md` | the record of one file (`lib/core.exs` → `lib-core.exs.md`) |

## What a record says

```
# `lib/<path>`

One or two sentences: what it does.

**Decisions homed here**: [D-name](#d-name), …    (or: **Takes part in**: …)

<a id="d-name"></a>

## D-name — the decision in one line

**Decided** (date, who): what was decided, as it holds in the code now.
- the rules, one bullet each

**Why**: the reason, in a few sentences.

**Alternatives**: what was considered and not taken, and why not.

**Files**: the files that carry it, and the tests that guard it.

**Earlier**: `Old.md` §N (… §M) — where the history is.

## Notes

- Pitfalls: what only reading the code reveals
- Difference from the documents: where `README.md`, `how-to-use.md`, `internals.md` or `scope.md` say otherwise; "none" if none
- Verified: date and commit, or "not yet verified cold"
```

- A decision has **one home**: the record of the file that carries its main part. Other records name it under **Takes part in**
- Decision names are short English (`D-named-rows-only`); `decisions.md` keeps the `Old.md` section each came from, since the other
  documents still cite `Old.md §N`
- Records are in English; quotes from `Old.md` are translated, not copied
- A file that is plain enough needs no record — its one line in `index.md` is enough

## Order of work

1. `decisions.md` — the map (done)
2. the records, layer by layer, and `index.md` (done, 2026-10-19; not yet verified cold)
3. the documents that cited `Old.md §N` pointed at the records and put into English: `scope.md`, `how-to-use.md`, `internals.md`,
   `extending.md`, `repl-adapter-guide.md`, `CLAUDE.md` (done, 2026-10-19; `work_history/` stays as it was)
