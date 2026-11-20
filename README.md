# Xipe Totec

Keep the calls you try at a REPL as **calc rows** — a function, its arguments, its value — and evaluate them again in your project's own
REPL whenever you like. A row's argument can be another row's value (`⟦id⟧`), so a change upstream shows where it reaches downstream,
as in a spreadsheet. A scan also gives every function's callers.

A local server and CLI (`xipe`), written in Elixir. It works alone from the command line;
[tezcatl](https://github.com/Crux-xurC/tezcatl) can be its window, and an AI agent can use it over MCP.

The whole README — the commands, how far it works, the principles, the structure and the terms — is
[README.full.md](README.full.md).

## Languages

| Evaluated | Scanned only (cards and callers) |
|---|---|
| Elixir (mix or scripts), OCaml (dune), Haskell (cabal, stack), Python (uv, poetry, pip), F# and C# (dotnet), Scala 3 (sbt, scala-cli), Java (maven) | JavaScript, TypeScript, Go, PHP |

Every language but Elixir is evaluated through [embody](https://github.com/Crux-xurC/embody), a separate repository cloned next to this
one. C# is called from F# Interactive and Java from Scala's REPL, so their arguments are written in F# and in Scala.

## Before you use it

- **It runs your code for real.** Nothing is sandboxed: a function that writes files or sends messages really does
- **Only functions you classified are evaluated** (`pure` / `reads` / `writes`, `effect/set`), and only for the body you classified:
  when a function's body changes, it waits for you again. `writes` run only when you ask (`--include-writes`)
- **An AI agent only proposes.** Over MCP an agent proposes a class with a reason; nothing of it is evaluated until you approve it
- **Local only, no authentication**: `127.0.0.1`, browsers refused. Use it on a machine only you log in to
- **No network of its own.** Build tools are started offline. **Scala and Java: build the project once yourself, online, before the
  first evaluation** — `sbt compile` or `scala-cli compile .` (`mvn compile` for Java) — or the build tool finds its cache empty and the
  rows fail with `Error downloading …`
- **Its state lives in this directory** (`tables/`), not in your project

What is promised to work, and what happens outside it: [document/scope.md](document/scope.md).

## Quick start

With Nix (flakes, x86_64-linux):

```
git clone https://github.com/Crux-xurC/xipe_totec.git
git clone https://github.com/Crux-xurC/embody.git       # for every language but Elixir
cd xipe_totec
nix develop                                            # gives the `xipe` command

cp -r test/fixtures/calc_sample ~/calc                 # a small Elixir target
xipe choice project ~/calc                             # register and choose it
xipe scan                                              # its functions become cards
xipe show                                              # find the node id of Calc.add/2
xipe do row/add node=<id> args=[2,3] -- effect/set id=<id> effect=pure -- eval 'call_ids=[$0.id]'
                                                       # a row, its class, evaluated: 5
```

Without Nix: [tezcatlipoca](https://github.com/Crux-xurC/tezcatlipoca) (a tarball with tezcatl, Xipe Totec and the rest), or
[xipe_totec_without_nix](https://github.com/Crux-xurC/xipe_totec_without_nix) (this repository as a Mix project).

Each language's requirements (the REPL, the build tool, the target's environment) are in [document/how-to-use.md](document/how-to-use.md)
§9, which goes on from here.

## With an AI agent (MCP)

`xipe mcp` is an MCP server over stdio for the running `xipe start`: an agent searches functions, reads them with their callers, adds
rows and evaluates them in the same Book you see. Start `xipe start` on the project, then, for Claude Code, in its `.mcp.json`
(without Nix: `"command": "<xipe_totec_without_nix>/bin/xipe", "args": ["mcp"]`):

```json
{ "mcpServers": { "xipe-totec": { "command": "nix",
    "args": ["develop", "<xipe_totec>", "-c", "elixir", "<xipe_totec>/main.exs", "mcp"] } } }
```

The agent's class proposals wait for you: `xipe do effect/approve ids=[…]`, or tezcatl's `matrix get xipe_classes:all` and
`matrix approve`. More: [document/mcp.md](document/mcp.md).

## Documents

| Document | |
|---|---|
| [README.full.md](README.full.md) | the whole README |
| [document/how-to-use.md](document/how-to-use.md) | using it with the code as it is |
| [document/scope.md](document/scope.md) | what is promised, what happens outside it, what is not started |
| [document/mcp.md](document/mcp.md) | an AI agent through MCP |
| [document/extending.md](document/extending.md) | adding a language or a command |
| [document/verification/](document/verification/README.md) | every decision and every file |

## License

MIT ([LICENSE](LICENSE)).
