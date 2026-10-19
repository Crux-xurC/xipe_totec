# `lib/command_line.exs`

`xipe do`'s arguments to a command list: groups separated by `--`, each a method followed by `key=value` pairs, and the rules for a
value.

**Decisions homed here**: [D-cli-values](#d-cli-values)
**Takes part in**: D-command-list ([`lib/runner.exs`](lib-runner.exs.md))

<a id="d-cli-values"></a>

## D-cli-values — `[...]` is always a list; `row/add` checks what it is given

**Decided** (2026-09-24, crux chose among three):

- **`[...]` is always a list**: `[]` empty, `[10]` one element, `[1,2]` two. The only way to write zero or one element (`args` of a 0- or
  1-argument function, `call_ids` of one row)
- A bare value with a comma is a list (`args=1,2`); anything else is a string
- **`row/add` makes a row only for a node that exists, and with as many arguments as the node accepts** (its arity, or what `arity/set`
  declared): `not_found` otherwise, or `invalid_params` naming `Module.name/arity` and the arguments given
- The `--` groups are shared with the window's input lines (`groups/1`)

**Why**: a one-argument row could not be written at all, and `args=3,` silently made a two-argument row `["3", ""]`; a row for a node
that did not exist was accepted too (the code did not check what `Old.md` §16.1 said it did).

**Alternatives**: repeating a key (`args[]=10`, long); JSON in the value (`args='["10"]'`, shell quoting).

**Files**: `lib/command_line.exs` (`parse/1`, `parse_value/1`, `groups/1`), `lib/dispatch.exs` (`check_args/4`); tests
`test/command_line_test.exs`, `test/dispatch_test.exs`.

**Earlier**: `Old.md` §31.1-3, §32.

## Notes

- An element that itself contains a comma (an Elixir list as one argument) cannot be written on one line; `dialogue do` takes a list one
  element a line (`scope.md`)
- Quotes are the shell's: `args=["hi"]` loses its quotes before `xipe` sees it
- Verified: not yet verified cold (written from the code, 2026-10-19)
