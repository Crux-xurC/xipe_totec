# Questions asked first, and concerns seen first

The short answers to what a reader — a person, or an AI asked to assess this repository — tends to ask or doubt first. Each answer is
a few lines and points to where it is decided; [`scope.md`](scope.md) is the whole of what is promised and what is not, and wins
where this page is shorter than it. Found a question missing? It belongs here when the answer exists elsewhere and is easy to miss.

## What it is

**Is it not just Tidewave?**
No; they answer different needs and can be used together. Tidewave (by Dashbit) goes inside a running web application (Phoenix,
Rails, and now others) and gives an agent that application's runtime: `project_eval` runs whatever Elixir the agent writes in it,
with logs, SQL and documentation beside it, and an in-browser agent for the pages. Xipe Totec does not run inside your application:
it keeps **calls of your functions as rows** in a Book you can see, evaluates them in a fresh REPL of the project's own language
(Elixir, OCaml, Haskell, Python, F#, C#, Java, Scala — not only web applications), compares each value with the previous one, and
evaluates a function only after **a person classified its side effects**. Tidewave is a live runtime for the agent; Xipe Totec is a
record of calls a person and an agent share, re-run to see what changed. ([README](../README.md#what-it-is-good-for),
[mcp.md](mcp.md))

**How is it different from a plain REPL, or unit tests?**
From a REPL: the calls are kept (the Book), each with its last value, and run again together; a REPL forgets what you typed. From
unit tests: no expected value is written first — the previous value is the comparison, and a change is shown as `changed`, for
you to judge. It is a place to try a function and to notice when its answers move, not a test framework.
([README](../README.md#what-it-is-good-for), [scope.md](scope.md#inside-the-scope-promised-to-work))

**Is it something to keep running while I code, like a REPL?**
No. It is run when work starts or when it has come together: scan, evaluate the rows, look at what changed. Several choices follow
from that (one pass at a time with a new REPL each time; approvals not re-asked when a callee changes, below).

## An AI agent through MCP

**Can the agent run something without my approval?**
Not through MCP: a function is evaluated only after you set or approved its class (`pure` / `reads`); the agent can only propose one, with a reason,
and `writes` never run through MCP ([D-effect-approval](verification/lib-core.exs.md#d-effect-approval), [mcp.md](mcp.md)
concerns 1, 16, 22). **But a row's arguments are code the agent writes, and they run as written, approved by no one** — an
argument that writes a file runs before the function, whatever its class. The agent is told to write values only and to check a
function's class first; you read the arguments of the agent's rows (`origin` `agent`) before evaluating them.
([scope.md](scope.md), Evaluation; turning arguments into data, which would close this, is an idea there). An agent that also has a
shell (Claude Code, Codex) can approve through the CLI itself: restrict that in the agent's own settings ([scope.md](scope.md), "The window
and the server").

**Is it a sandbox? What about the network and my files?**
No. Functions run as you, with your network and your files. To keep tests from going out except where declared, start the REPL behind
[forbidden](https://github.com/Crux-xurC/forbidden) and [Citlalpol](https://github.com/Crux-xurC/Citlalpol) with the project's
`eval.wrap`; for files, back up what a test may change. Xipe Totec does nothing against either ([scope.md](scope.md), "Not a sandbox").

**What if a function I approved calls one that changed later?**
The approval stays: it is tied to the function's own body, and a changed body asks again, a changed callee does not. After the
project changed, evaluate its rows again and look at what `changed`; the agent is told to do the same.
([scope.md](scope.md), Evaluation; [mcp.md](mcp.md) concern 23)

**Why are C# and Java arguments written in F# and Scala?**
Their functions are called from F# Interactive and Scala's REPL, through C#'s and Java's seams (`embody.cs`, `embody.java`); a
row's arguments are in the language of the REPL they run in. `get_function` names it for the agent. ([scope.md](scope.md), the languages row;
[mcp.md](mcp.md) concern 11)

## Languages and results

**In Python, my module's constants are missing.**
Importing a target module runs only its definitions, imports and assignments of literal values (`FACTOR = 3`); `X = f()` and other
top-level statements do not run, so that importing does no work of its own. Compute such values in functions. (embody's
`ReadMe.full.md`, "Python")

**Can rows become tests?**
`graph/export` writes them in a `doctest` format, from the values in the table (nothing is evaluated again).
([scope.md](scope.md), `graph/export`'s row; [how-to-use.md](how-to-use.md))

**Can I see the rows as a table, sorted and filtered?**
In tezcatl (its matrix). Xipe Totec answers the rows; sorting and narrowing are the receiver's
([D-method-criteria](verification/lib-methods.exs.md#d-method-criteria)).

## Running it

**Do I need Nix? Can I install it with Mix?**
This repository is managed with Nix. Without it: [xipe_totec_without_nix](https://github.com/Crux-xurC/xipe_totec_without_nix)
(a Mix project made from this one) or [tezcatlipoca](https://github.com/Crux-xurC/tezcatlipoca) (a tarball with tezcatl, Xipe
Totec and Poca, on Linux x86_64).

**Can I use it on a shared machine?**
No: only on a machine only you log in to. It listens on `127.0.0.1` without authentication, and every user of the machine can reach
that. ([README](../README.md#before-you-use-it), [scope.md](scope.md))
