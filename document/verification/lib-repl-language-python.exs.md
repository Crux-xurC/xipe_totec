# `lib/repl/language/python.exs`

Python's declaration: extension `py`, REPL `python -i` with `embody.py`, build tools `uv` (`uv.lock`) over `poetry` (`poetry.lock`) over
`pip` (`pyproject.toml`, `requirements.txt`, `setup.py`), scanner `Scanner.Python`; `launch_opts/3` maps each file to its module name and
writes the init file that installs `embody.py`'s import hook. The adapter is `lib/repl/python/launch.exs`,
`lib/repl/python/eval_template.exs` and the iex scan / field_drip it delegates to.

**Decisions homed here**: [D-python-adapter](#d-python-adapter)
**Takes part in**: D-embody ([`lib/repl/embody.exs`](lib-repl-embody.exs.md)), D-language-adapter
([`lib/repl/language.exs`](lib-repl-language.exs.md)), D-scanners ([`lib/scanner/lsp.exs`](lib-scanner-lsp.exs.md)),
D-source-sanitize ([`lib/repl/source_sanitize.exs`](lib-repl-source_sanitize.exs.md): the same idea, in the target's own language)

<a id="d-python-adapter"></a>

## D-python-adapter — `python -i` with `embody.py`; project modules imported without their top level

**Decided** (2026-11-16; checked on Python 3.13.12):

- **`python -i -q -u <init file>`**, `PYTHONDONTWRITEBYTECODE=1` (no `__pycache__` written into the project): no banner; `ready_probe`,
  `quit()`, `interruptible: true` (SIGINT raises `KeyboardInterrupt` in the running statement and the REPL reads on). The `>>> ` / `... `
  prompts go to stderr and stay in the buffer, inert to `Repl.Eval.Scan`
- **One entry is one line**, `_xt_embody.run(id, var, timeout_ms, module, call, basis)`: the call travels as a string compiled inside
  `run`, so an argument that does not parse is that entry's `SyntaxError` crash, never a REPL waiting for more input. `run` imports the
  module, binds its top-level package name in `__main__`, evaluates under SIGALRM (`setitimer`), binds the value to `xt_<id>` whatever
  its repr, and prints the record in one write. repr: `repr()` → `ast.literal_eval` → equal → `exact`; else `pickle` → loads back equal
  → `binary`; else `unsupported`. compare: the previous value rebuilt from text or pickle; floats within `1e-9`, containers element by
  element, types must match; a value with a cycle compared by its pickle bytes
- **Loading**: `embody.install` puts an import hook first on `sys.meta_path` for the project's modules (name → file, from
  `launch_opts/3`). A module is executed with only its `def`, `async def`, `class`, `import`, `from … import`, assignments of literal
  values (`FACTOR = 3`, `NAMES: list = ["a"]`), aliases (`comp = compose`, `join = os.path.join`: a name or a chain of
  attributes, no call; 2026-11-17) and `try` blocks made of those — not `print(…)`, not `if __name__ == "__main__":`, not
  `X = f()`. `run` imports the module's top-level package before the module itself, so a package whose `__init__.py` fails is that
  failure in every entry (a submodule left in `sys.modules` by the failed import would otherwise hide it as `KeyError`). Imports between project files go through the same hook; other packages import as usual (their top level runs, as OCaml's
  dune dependencies do)
- **Module names** (`Scanner.Python.module_name/2`): the path, `/` as `.`, `__init__.py` as its package, a leading `src/` left out unless
  `src/__init__.py` exists. One file per name
- **Interpreter**: the project's `.venv/bin/python` when it exists, else `python3` on PATH (a project's environment decides it,
  `project_env.json`). The build tool does not change the start; nothing is installed or synced
- **Scanning**: `Scanner.Python` reads the text, like Haskell's and OCaml's: top-level `def` / `async def` (methods and nested functions
  are not nodes), `anykey` `nil`, every node `public`; links from same-module names, `from … import` (aliased, relative) and
  `module.attribute` chains of imported project modules

**Why**: Python's `ast` gives the same "definitions only" loading Elixir's `SourceSanitize` gives, inside the target's own interpreter and
its own version of the language; an import hook makes it hold for imports between the project's files too, which loading files one by
one would not. Passing the call as a string removes the REPL's continuation prompt from the picture. A text scanner needs no language
server installed (D-scanners); pyright gives the same links (checked: `documentSymbol`, `callHierarchy` in and out) and can be added as a
`Scanner.Lsp` dialect later, which would need the dialect to be told the file (pyright reports no module container).

**Alternatives**: `exec` of a whole statement per entry (the template the 2026-11-16 check used — works, but puts the judging code in
every line); `ast.literal_eval` only, without `pickle` (loses `binary` for class instances); importing the files as they are (runs their
top level); a per-entry memory limit (`resource` limits the whole process — not used).

**Files**: `lib/repl/language/python.exs`, `lib/repl/python/launch.exs`, `lib/repl/python/eval_template.exs`,
`lib/repl/eval/scan/direct/python.exs`, `lib/repl/eval/field_drip/python.exs`, `lib/scanner/python.exs`, embody's `embody.py`; tests
`test/python_adapter_test.exs`, `test/live/repl_python_test.exs`; fixture `test/fixtures/python_sample/`.

## The REPL as checked (`extending.md` §2.2), 2026-11-16, Python 3.13.12

| Item | Python |
|---|---|
| Start | `python -i -q -u` over a pipe: no banner; the prompts `>>> ` / `... ` on stderr (harmless); `ready_probe`'s output arrives at once |
| Loading | `embody.install`'s hook: definitions, imports and literal constants only; checked that `print`, a file written at the top level and `if __name__ == "__main__":` do not run, and nothing is written into the project |
| Evaluation and display | `repr()`, then `ast.literal_eval` and equality for `exact`; `pickle` for `binary` (a cyclic list, a class instance with `__eq__`); functions, generators, coroutines, `itertools.count` are `unsupported` |
| Failure | an exception (its message's newlines as `\n`), a `TypeError`, a `SyntaxError` from an unclosed argument: one line each; the REPL reads on |
| Time limit | SIGALRM (`setitimer`) stops `while True: pass`. **A loop inside C code (`sum(itertools.count())`) is stopped by neither SIGALRM nor SIGINT**: the Evaluator's deadline kills the REPL (`session_hung`, the rest `aborted`) |
| SIGINT | `KeyboardInterrupt`, the REPL reads on with its bindings (`interruptible: true`) |

## Notes

- An `async def` gives its coroutine, not awaited (`unsupported`). Awaiting is not designed
- Decorators run when their function is defined (a registering decorator such as a web framework's route runs on load)
- Only top-level functions are nodes: methods, `staticmethod`s and functions in a class are not (a calc row calls a function once with
  literal arguments)
- The value is judged (`repr`, `pickle`) outside the time limit; a value whose `repr` does not end is ended by the Evaluator's deadline
- Verified: `test/live/repl_python_test.exs` (4 tests) and the CLI end to end (`refresh -l`, `choice project`, `scan`, `row/add`, `eval`)
  on a copy, 2026-11-16
- Applied to a project not written for it (2026-11-17): toolz (pytoolz/toolz at 451af60, 51 files, 289 functions), on a copy of Xipe
  Totec with its own `tables/`. Found and fixed: aliases at a package's top level (`comp = compose` in `toolz/__init__.py`) were dropped,
  so the package failed to import, and every later entry was `KeyError: 'toolz'`; a parenthesized `from … import (…)` over several
  lines bound only the names on its first line (links 188 → 270). Then 12 calc rows: `exact` for dicts, tuples and nested dicts
  (`frequencies`, `get_in`, `merge`, `assoc_in`, `groupby`, `countby`, `topk`), `binary` for a `Compose` instance, `unsupported` for
  iterators (`sliding_window`'s `zip`, `interpose`'s `chain`) and a closure (`memoize`), an `IndexError` crash (`nth`); the second
  evaluation `same` for every `exact` and `binary` row
- Seen in that check, left as they are: lazy functions give iterators, which are `unsupported` (a row cannot wrap its call in
  `list(…)`); calls from a class's methods (toolz's tests are `unittest`-style classes) are no node's, so they are not links;
  `toolz/curried/` builds its names with top-level calls (`x = toolz.curry(…)`), which do not run, so `toolz.curried` lacks them;
  an argument containing `,` cannot be written in a one-line `xipe do` (`list("ab")`, `dict(a=1)` written instead — the `args:=[…]`
  idea in `scope.md`)
