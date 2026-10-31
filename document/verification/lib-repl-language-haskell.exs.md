# `lib/repl/language/haskell.exs`

Haskell's declaration: extension `hs`, REPL GHCi with `embody.hs`, build tools `stack` (`stack.yaml`) over `cabal` (`*.cabal`,
`cabal.project`), scanner `Scanner.Haskell`; `launch_opts/3` finds each file's module and source root and writes the GHCi script
(`:load` + `:module + *M …`). The adapter is `lib/repl/haskell/launch.exs`, `lib/repl/haskell/eval_template.exs` and the iex scan /
field_drip it delegates to.

**Decisions homed here**: [D-haskell-adapter](#d-haskell-adapter)
**Takes part in**: D-embody ([`lib/repl/embody.exs`](lib-repl-embody.exs.md)), D-language-adapter
([`lib/repl/language.exs`](lib-repl-language.exs.md)), D-scanners ([`lib/scanner/lsp.exs`](lib-scanner-lsp.exs.md))

<a id="d-haskell-adapter"></a>

## D-haskell-adapter — one entry as `let` bindings; cabal and stack only lend the environment

**Decided** (2026-09-27; checked on GHC 9.10.3, cabal-install 3.16.1.0, stack 3.9.3):

- **GHCi** with `-v0 -w -fdefer-type-errors -Wno-deferred-type-errors -Wno-deferred-out-of-scope-variables -i<dirs> -ghci-script <s>`:
  no banner, no prompt; `ready_probe`, `:quit`, `interruptible: true` (SIGINT stops the evaluation, GHCi reads on)
- **One entry is five `let` lines and one `Embody.run`**: the call, then `whnf`, `exact`, `shown`, `typed` of it, each bound with `let`.
  `-fdefer-type-errors` works only on `let` bindings, not on an expression run at the prompt — written directly, a missing `Show` makes
  the whole line a compile error with no marker. `run` tries whnf → exact (`Read`, `Show`, `Eq`, reading back equal) → shown (`show` cut
  to 2,000 characters) → the type (`Typeable`), skipping a stage whose binding is a deferred type error. Newlines inside an argument become
  spaces (a `let` line must not end early)
- **Loading**: GHCi `:load`s the files (no top-level effects; `main` is not run), each file's source root on `-i`, every module in scope
  as `*M` (unexported functions can be called). Several files without a `module` line (or `module Main`) cannot load together: none of
  them is loaded
- **cabal / stack**: GHCi is started under `cabal exec --offline --` / `stack exec --`, which only make the dependencies visible; loading
  stays Xipe Totec's, all components at once. cabal needs the project built once, so `cabal build --offline all` runs first (output
  dropped, failure not stopping GHCi). `--offline`: evaluating fetches nothing

**Why**: GHCi decides instances at type-checking time, so the stages must be bound and tried at run time to always print a marker.
`cabal repl` cannot add `embody.hs` in its multi-component mode (`:add` is not supported there).

**Alternatives**: `cabal repl` + `:add embody.hs` (one component only); `:type` on a separate line (would break one entry = one round
trip); HLS for scanning (text scanning is enough, D-scanners); GHC's allocation limit as a memory limit (it limits total allocation, not
live memory — not used).

**Files**: `lib/repl/language/haskell.exs`, `lib/repl/haskell/launch.exs`, `lib/repl/haskell/eval_template.exs`,
`lib/scanner/haskell.exs`, embody's `embody.hs`; tests `test/haskell_adapter_test.exs`, `test/live/repl_haskell_test.exs`; fixture
`test/fixtures/haskell_sample/`.

## Notes

- Functions returning `IO` are not run; their type is the display (`observeIO` is not designed). No float tolerance in `compare`
- stack has no global offline switch: a configuration that needs a snapshot fetched may go to the network
- cabal writes `dist-newstyle/`, stack `.stack-work/` into the project
- Out of scope (`scope.md`): an exception whose own message throws cuts embody's `crash` line
- Verified: not yet verified cold (written from the code, 2026-10-19)
