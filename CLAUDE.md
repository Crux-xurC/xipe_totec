# xipe_totec — where to start

Only the entrances, so work can resume with no memory. The documents themselves are authoritative; this is the way to them.

## Read in this order

1. `README.md` — what it is for, what it is not, the design principles P1–P10, how far it works now
2. `document/scope.md` — **what is promised to work, what happens outside it, and the work not started (planned, ideas)**; each row links to
   the decision records. tezcatl's: `../tezcatl/docs/scope.md`
3. `document/verification/` — **where decisions live**. `decisions.md` lists every decision in force (`D-…`) and the withdrawn proposals,
   `index.md` every file in one line, `<path with / as ->.md` the record of a file (what it does, why, its decisions, what was not chosen).
   A decision added or changed goes into the record of its main file, with a row in `decisions.md`
4. Adding a language or a command: `document/extending.md` (what to start from, what behaviour to meet, the promises not to break), with
   `document/repl-adapter-guide.md` for the REPL adapter's details
5. Only when needed: `document/internals.md` (what is called in what order), `document/how-to-use.md` (how to use it)

**`work_history/` is the record up to 2026-10-10** (Japanese; moved there by crux on 2026-10-10): `課題.md` (the open items then and how the
overall review was handled), `next_step.md` (plans for the next stage, with crux's comments), `xipe_totec_spec_v0.4.html` (the draft spec;
where it disagrees with `document/verification/`, the decisions win). **Do not read it day to day. Do not add to it.**

Documents whose content moved elsewhere are kept locally as `work_history/旧<name>` and left out of git (`.gitignore`): `旧Old.md` (the
history of decisions — taken out into `document/verification/`), `旧範囲.md`, `旧How_to_use.md`, `旧動作原理.md`, `旧拡張の手引き.md`,
`旧repl-adapter-guide.md`, `旧CLAUDE.md` (the Japanese originals of the English documents, 2026-10-19). "`Old.md` §N" in older text is a
section of 旧Old.md; which decision it is can be looked up in the "Earlier" column of `decisions.md`.

From now on: history in git commit messages, decisions in `document/verification/`, the scope in `document/scope.md`.

**When reviewing or verifying**, read `document/scope.md` (and `../tezcatl/docs/scope.md`) first. What happens outside the scope exactly as
written there is not a defect (when it may still be raised: "How to read it" in that document). Past findings and how they were handled:
`work_history/課題.md` §6 ("全体レビュー", 2026-10-02/03).

Poca (the browser that opens tezcatl) is a separate project (`~/my_app_no_nix/poca/`); not read for xipe_totec work.

The conversation with crux is in Japanese; documents, code comments and messages are in English.

## Tests

```
./test/run.sh                           # everything (runs with XIPE_TOTEC_LSP=off; starts nothing)
elixir test/live/repl_iex_test.exs      # with a real iex (not in run.sh)
nix shell nixpkgs#ocaml nixpkgs#dune_3 -c elixir test/live/repl_ocaml_test.exs   # with a real ocaml and dune (skipped without them)
nix shell nixpkgs#ghc -c elixir test/live/repl_haskell_test.exs                   # with a real GHCi (skipped without it)
```

## Trying it for real (without touching the real environment)

xipe_totec keeps its state in fixed places relative to `__DIR__` (`tables/project/…/book.jsonl`, `tables/session.json`,
`tables/logging_buffer.txt`, `info.json`). They cannot be redirected by environment variables, so to try the CLI:

1. Copy `lib/`, `main.exs`, `info.json`, `pipelines.json`, `defaults.json`, `project_env.json` to a work directory (to evaluate OCaml or
   Haskell, also `XIPE_TOTEC_EMBODY_DIR=~/my_app/embody`; embody is a separate repository, looked for next to xipe_totec by default)
2. Use a copy of `test/fixtures/calc_sample/` as the target too
3. In the copy: `XIPE_TOTEC_LSP=off elixir main.exs choice project <the copied target>` → `scan` → `do …` → `eval …`

To check it from tezcatl's screen: `../tezcatl/test/e2e/README.md` (the relay, a fake Xipe server and headless Chromium on isolated ports; the
work copy is made there too).

## git

xipe_totec is its own git repository in this directory (since 2026-10-01; `origin` = `git@github.com:Crux-xurC/xipe_totec.git`, branch
`main`). Plain `git commit` / `git push origin main`. The git of `~/my_app` no longer tracks xipe_totec (`~/my_app` is a separate, local-only
repository).

`tables/` (the project registry, Books, the chosen project `selection.json`, `session.json`) is per-machine data, not in git; nor are
`work_history/旧*`.

**Commit and push only when crux explicitly asks.**

## With tezcatl

- tezcatl (`../tezcatl`) is the window. Which project is open is decided by xipe_totec (`xipe choice project`)
- tezcatl does not interpret xipe_totec's text for people (D-envelope in `document/verification/lib-protocol.exs.md`: "I/O is not for parsing")
- tezcatl's dialogue window sends only `input` `{"text": "<the line typed>"}`; xipe_totec decides what the line means. Openings not yet
  implemented: "Work not started" in `document/scope.md`
