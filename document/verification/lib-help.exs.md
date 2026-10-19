# `lib/help.exs`

What `help` prints, for the CLI (`xipe help`) and the window (`input` `help`) from the same tables: the CLI commands (name, arguments,
summary, the longer text of `help <command>`, whether the window takes it), then every implemented method from `Methods`.

**Decisions homed here**: [D-help-table](#d-help-table)
**Takes part in**: D-input-line ([`lib/serve_input.exs`](lib-serve_input.exs.md)), D-method-criteria ([`lib/methods.exs`](lib-methods.exs.md))

<a id="d-help-table"></a>

## D-help-table — one command a line, from one table

**Decided** (2026-09-27, with tezcatl's dictionary):

- **One line per command**: `<command>: <what it does>  <how its arguments are written>`. No headings, no wrapped lines, no `:` in a command
  name — tezcatl's users yank lines into the dictionary, which takes what is before the first `:` as the word
- **One table for CLI and window**: the window's list shows only what the window runs; the `eval` pseudo-method is left out (the `eval`
  command covers it); methods not implemented are not listed. `help <command>` prints the long text
- A method's `args` text is made from its declared `params`, never written by hand; `test/help_test.exs` fails when an implemented method
  has no summary
- Messages and help text are in English (since 2026-10-10)

**Why**: tezcatl never parses Xipe Totec's text (D-envelope); a person makes the dictionary from lines that are already one entry each.

**Alternatives**: a sectioned, wrapped help (cannot be yanked line by line); a separate help for the window.

**Files**: `lib/help.exs`, `lib/methods.exs`; tests `test/help_test.exs`.

**Earlier**: `Old.md` §40.1.

## Notes

- Verified: not yet verified cold (written from the code, 2026-10-19)
