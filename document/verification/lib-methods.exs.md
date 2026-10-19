# `lib/methods.exs`

Every method a command list or the server accepts, declared once: where it is handled (`:dispatch`, `:repl`, `:pipeline`,
`:not_implemented`), whether it writes the Book, whether it needs a y/n (`confirm`), whether the server runs it as a pass, its parameters
as data, and the one-line `args` / `summary` that `help` prints. `test/methods_test.exs` checks this against `Dispatch` both ways.

**Decisions homed here**: [D-method-criteria](#d-method-criteria)
**Takes part in**: D-help-table ([`lib/help.exs`](lib-help.exs.md)), D-dialogue-do ([`lib/dialogue/do.exs`](lib-dialogue-do.exs.md))

<a id="d-method-criteria"></a>

## D-method-criteria — what may be added as a method

**Decided** (2026-10-11 and 2026-10-12, crux): Xipe Totec is **what uses the target's environment**, gathered in one place. Looking at
what it fetches is the job of each tool (the CLI, tezcatl's tables). A method may be added only when it is one of:

1. **using the target's environment** (the REPL, a language server, a build)
2. **writing the Book** (only Xipe Totec keeps it consistent)
3. **reading something whole** (choosing by a list of ids at most). **New information comes as columns, not commands** (`row/list`'s
   columns …)
4. **the minimum to look at it simply** — first see whether `show`, `search`, `eval/status` are enough; if not, add to the CLI side, not a
   method

- Narrowing, sorting, following and reshaping are the receiver's (tezcatl's table filters and sorts; `jq`, `grep` in a terminal)
- The query methods that exist (`card/get`, `card/search`, `node/resolve`, `row/depends`, `row/check`, `graph/*`) stay, but no more are
  added; `search` gets no new kinds of turns
- **Tables and columns may be added**: giving information in a clear shape is Xipe Totec's job, and the whole reads (3) and `search` (4) use
  the same tables (`lib/tables.exs`, `roster`)
- Parameters are declared as data (`params`: name, kind, required, list …): `help`'s argument text is made from them, and `dialogue do`
  asks for the required ones a line left out

**Why**: P7 (the input experience is the client's) and P9 (states as columns). Query commands multiply without end; columns on a few whole
reads serve every client.

**Alternatives**: an SQL-like query method; more `search` turn kinds.

**Files**: `lib/methods.exs`, `lib/tables.exs`, `lib/dispatch.exs`, `lib/help.exs`; tests `test/methods_test.exs`,
`test/help_test.exs`, `test/dialogue_do_test.exs`.

**Earlier**: `document/拡張の手引き.md` §3.0, `document/範囲.md`; commit f59d4d8.

## Notes

- Not listed here: what `Serve.Socket` handles itself (`initialize`, `subscribe`, `input`) and the dialogue methods (`InOut`)
- Verified: not yet verified cold (written from the code, 2026-10-19)
