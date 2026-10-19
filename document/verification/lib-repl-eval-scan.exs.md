# `lib/repl/eval/scan.exs`

The language- and transport-independent part of reading results: in a buffer already cleaned by the `Scan.<transport>.<REPL>` module
(`Scan.Direct.Iex` removes `XT_EXIT`), find one call id's `XT_BEGIN_<id>` … `XT_END_<id>` body or its `XT_ERROR_<id>` line.

**Decisions homed here**: [D-markers](#d-markers)
**Takes part in**: D-language-adapter ([`lib/repl/language.exs`](lib-repl-language.exs.md))

<a id="d-markers"></a>

## D-markers — fixed markers, the same in every language

**Decided** (2026-09-18, extended to 2026-10-06): what Xipe Totec reads from a REPL is only these markers; any other output (prompts, the
value echoed by iex, a stray print) is ignored.

| Marker | Meaning |
|---|---|
| `XT_BEGIN_<id>` … `XT_END_<id>` | a result; between them one `key=value` a line: `repr=`, `type=`, `compare=`, `display=`, and `bin_base64=` for `binary` |
| `XT_ERROR_<id> timeout` / `crash <one line>` / `max_heap` | a failure |
| `XT_CALLED_<id>` | the call returned; judging its value starts (Elixir only so far) |
| `XT_READY` | the answer to the ready probe |
| `XT_EXIT <status>` | the REPL process ended (made by the Sender) |

- **One write per block**: the whole `XT_BEGIN` … `XT_END` block is printed with one call, so output of other processes cannot land inside
  it (on BEAM one `IO.puts` through the group leader is atomic)
- A value or reason never spans lines: newlines are written as `\n`
- Only the call id asked for is matched; leftovers of another id are inert
- The prefixes, field names and the `key=value` form do not change by language (embody's `ReadMe.md` states the same contract)

**Why**: the receiving side (`Scan`, `FieldDrip`, `Result`, `Parser`) then knows no language, and every adapter knows exactly what to print.

**Alternatives**: several prints per block (another process's output could interleave and break the body); markers per language.

**Files**: `lib/repl/eval/scan.exs`, `lib/repl/eval/scan/direct/*.exs`, `lib/repl/eval/field_drip/*.exs`, `lib/repl/eval/result.exs`,
`lib/repl/eval/parser.exs`, `lib/repl/eval_template.exs`; embody's `embody.ml` / `embody.hs`; tests `test/repl_eval_scan_test.exs`,
`test/repl_eval_scan_direct_iex_test.exs`, `test/repl_eval_parser_test.exs`.

**Earlier**: `Old.md` §10, §10.1, §10.4, §10.6, §14.3, §35.1-6 (`XT_READY`), §51 (`XT_CALLED`); `repl-adapter-guide.md` ("do not change").

## Notes

- `XT_HEARTBEAT` existed until 2026-09-22 and is gone (D-hang-handling)
- Verified: not yet verified cold (written from the code, 2026-10-19)
