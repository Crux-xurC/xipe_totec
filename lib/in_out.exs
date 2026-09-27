Code.require_file("book.exs", __DIR__)
Code.require_file("runner.exs", __DIR__)
Code.require_file("pipeline.exs", __DIR__)
Code.require_file("dialogue.exs", __DIR__)
Code.require_file("dialogue/depends.exs", __DIR__)
Code.require_file("dialogue/search.exs", __DIR__)

defmodule XipeTotec.InOut do
  @moduledoc """
  The "第4層" structured dialogue I/O core (Old.md §16.4/§17,
  2026-09-19/20 co-design). Stays pure like `Runner`/`Dispatch`/`Pipeline`
  -- `handle/6` takes a `Book` and a `dialogue` (the one piece of state
  this layer adds) and returns both back, plus one tagged reply. No
  process of its own; the caller (`main.exs`'s CLI, or -- once wired --
  `Serve.Project`/`Serve.Socket`) is the one holding `book`/`dialogue`
  between calls, the same way `main.exs` already threads `Book` around
  `Runner.run/4` and persists the diff itself.

  ## One dialogue per connection (decided 2026-09-20)

  `dialogue :: nil | {module, term}` is deliberately a single slot, not a
  registry keyed by some correlation id. crux's own use case (tezcatl
  opening a project in several browser tabs, all sharing one relay↔`/xipe`
  connection -- tezcatl.md, `XipeSocket` forwards frames verbatim with no
  per-tab identity) means a second tab's *unrelated* command can arrive
  mid-dialogue on the very same connection; it must NOT be mistaken for
  the pending answer. A second tab starting a *second* dialogue while one
  is already held is out of scope for now (falls through to the ordinary
  pass-through below, which will normally reply `unknown_method` since a
  dialogue-starting method is only recognized while `dialogue == nil`) --
  no real dialogue program exists yet to make this a live problem, and
  CLI usage is unaffected by construction (each terminal is its own OS
  process, so it never shares a `dialogue` slot with another one).

  ## Routing

  Every call is one of four cases, matched on `{dialogue, method}`:

    * `{{mod, state}, "dialogue/answer"}` -- continues the held dialogue:
      `mod.answer(state, params)`.
    * `{nil, "dialogue/answer"}` -- nothing is held; a clean `error`
      reply (`"no_pending_dialogue"`), `dialogue` stays `nil`.
    * `{nil, method}` where `method` is a key in `programs` -- starts a
      new dialogue: `mod.start(params)`.
    * everything else -- passed straight through to `Runner.run/4` as a
      one-command list, `dialogue` unchanged either way. This is how an
      unrelated command reaches `Dispatch`/`Pipeline`/the `"eval"`
      pseudo-method exactly as if `InOut` didn't exist, whether or not a
      dialogue happens to be held at the time.

  ## The programs, and what a turn may ask of its driver (2026-09-27)

  `programs/0` is the one registry of dialogue programs (`dialogue/depends`,
  `dialogue/search`), used by the CLI and the server alike (the server had
  none before, `課題.md` §2). Tests pass their own map.

  `"dialogue/quit"` ends whatever dialogue is held (`quit dialogue`,
  next_step §1.1).

  A program with `start/2`/`answer/3` gets a read-only `ctx` (the book,
  root and project dir -- `Dialogue`). Two things are left to the caller
  (the driver) instead of done here, marked on the outcome as `:run`:

    * `{:line, line}` -- a turn returned `{:pass, state, line}`: an ordinary
      command line to run while the dialogue stays held
    * `{:commands, commands}` -- a `:done` turn's commands, only when the
      caller passes `defer_commands: true` (`Serve.Input`, so an evaluation
      runs in the server's pass queue, not inside this call). Without it
      they run here through `Runner.run/4`, as before (the CLI)

  ## The 2-bit reply tag (Old.md §17)

  A `Dialogue` program never encodes `hold`/`via_repl` itself (see that
  module's own moduledoc) -- `InOut` derives them mechanically:

    * `:hold` from `start/1` or `answer/2` -> `hold: true, via_repl: false`
      (`11`), and the dialogue stays open.
    * `:done` with `commands == []` -> `hold: false, via_repl: false`
      (`01`), dialogue closes, nothing else happens.
    * `:done` with a non-empty `commands` -> `hold: false, via_repl: true`
      (`00`), dialogue closes, and `commands` is immediately handed to
      `Runner.run/4` in the same turn (folded into `result["outcomes"]`).
    * the ordinary pass-through case -> `hold: false`, `via_repl` decided
      by `via_repl?/1` (`true` for `"eval"` and anything
      `Pipeline.handles?/1` says yes to, `false` -- i.e. an ordinary
      `Dispatch` method -- otherwise). This is the same static
      per-execution-path classification Old.md §17.1 already worked
      out for the existing command surface (`Dispatch` Tier1 methods all
      `01`, the `"eval"` pseudo-method `00`); `InOut` doesn't invent a new
      rule here, only applies that one mechanically.

  `notify/*` (the `Serve.Project` broadcast push, tagged `01` per §17.1)
  is explicitly **not** handled here -- it never arrives as an `InOut.handle/6`
  call in the first place (it's pushed independently via
  `Serve.Project`'s own `push/2`, not a reply to any particular `:in`).
  Tagging it on the way out is `Serve.Socket`/`Protocol`'s job, left for
  whenever `Serve.Socket` is actually wired to `InOut`.
  """

  alias XipeTotec.{Book, Pipeline, Runner}

  @type dialogue :: nil | {module(), term()}
  @type command :: %{String.t() => term()}
  @type programs :: %{String.t() => module()}
  @type outcome :: %{
          optional(:run) => {:line, String.t()} | {:commands, [command()]},
          hold: boolean(),
          via_repl: boolean(),
          text: String.t() | nil,
          ok?: boolean(),
          result: map() | nil,
          error: map() | nil
        }

  @answer_method "dialogue/answer"
  @quit_method "dialogue/quit"

  @doc "The dialogue programs, by the method that starts each -- see moduledoc."
  @spec programs() :: programs()
  def programs, do: %{"dialogue/depends" => XipeTotec.Dialogue.Depends, "dialogue/search" => XipeTotec.Dialogue.Search}

  @doc """
  Runs one `%{"method" => ..., "params" => ...}` input against `dialogue`
  (`nil` if none is held) and `book`. `root`/`opts` are forwarded to
  `Runner.run/4` unchanged (same meaning as there: `root` is the target
  project directory, `opts` carries `Repl.Evaluator.run_pass/3` options
  used only when a command actually reaches `"eval"`).

  Returns `{new_dialogue, new_book, outcome}`. The caller is responsible
  for persisting/broadcasting whatever `book` diff results, exactly as it
  already does around `Runner.run/4`/`Dispatch.handle/4` -- this function
  has no side effects of its own beyond running `commands` through
  `Runner.run/4` when a dialogue finishes with some.
  """
  @spec handle(dialogue(), Book.t(), String.t(), command(), keyword(), programs()) ::
          {dialogue(), Book.t(), outcome()}
  def handle(dialogue, book, root, command, opts \\ [], programs \\ programs())

  def handle({mod, state}, book, root, %{"method" => @answer_method, "params" => params}, opts, _programs),
    do: run_program(mod, :answer, [state, params], book, root, opts)

  def handle({_mod, _state}, book, _root, %{"method" => @quit_method}, _opts, _programs),
    do: {nil, book, ok_outcome(false, false, "対話を終了しました。", nil)}

  def handle(nil, book, _root, %{"method" => method}, _opts, _programs) when method in [@answer_method, @quit_method],
    do: {nil, book, error_outcome("no_pending_dialogue", "\"#{method}\" received but no dialogue is held")}

  def handle(nil, book, root, %{"method" => method, "params" => params}, opts, programs) do
    case Map.fetch(programs, method) do
      {:ok, mod} -> run_program(mod, :start, [params], book, root, opts)
      :error -> pass_through(nil, book, root, %{"method" => method, "params" => params}, opts)
    end
  end

  def handle(dialogue, book, root, command, opts, _programs),
    do: pass_through(dialogue, book, root, command, opts)

  @doc """
  Drives one dialogue to completion synchronously, calling `next_answer`
  (0-arity) each time `outcome.hold` comes back `true` and `on_text`
  (1-arity) once per turn whenever `outcome.text` is non-nil. Neither
  callback is IO itself -- `main.exs`'s CLI passes `fn -> ... IO.gets ...
  end` / `&IO.puts/1`, a test passes a canned queue / an accumulator (see
  `test/in_out_test.exs`). This function is the reusable "loop" half of
  what a caller needs; it never touches a terminal or a socket directly,
  so it's the same piece whether the eventual driver is `main.exs`'s CLI
  or (once wired) `Serve.Socket`'s frame handler.

  Returns `{book, outcome}` once `outcome.hold` is `false` -- the caller
  persists the `Book` diff itself, same as every other `Runner.run/4`-
  adjacent call site already does.
  """
  @spec run_to_completion(Book.t(), String.t(), command(), keyword(), programs(), (-> map()), (String.t() -> any())) ::
          {Book.t(), outcome()}
  def run_to_completion(book, root, first_command, opts, programs, next_answer, on_text) do
    {dialogue, book, outcome} = handle(nil, book, root, first_command, opts, programs)
    drive(dialogue, book, root, opts, programs, outcome, next_answer, on_text)
  end

  defp drive(dialogue, book, root, opts, programs, outcome, next_answer, on_text) do
    if outcome.text, do: on_text.(outcome.text)

    if outcome.hold do
      answer = %{"method" => @answer_method, "params" => next_answer.()}
      {dialogue, book, outcome} = handle(dialogue, book, root, answer, opts, programs)
      drive(dialogue, book, root, opts, programs, outcome, next_answer, on_text)
    else
      {book, outcome}
    end
  end

  # --- dialogue-program results -> {dialogue, book, outcome} -----------

  defp run_program(mod, fun, args, book, root, opts) do
    Code.ensure_loaded(mod)
    ctx = %{book: book, root: root, project_dir: Keyword.get(opts, :project_dir)}

    turn =
      if function_exported?(mod, fun, length(args) + 1),
        do: apply(mod, fun, args ++ [ctx]),
        else: apply(mod, fun, args)

    case turn do
      {:hold, state, text} ->
        {{mod, state}, book, ok_outcome(true, false, text, nil)}

      {:pass, state, line} ->
        {{mod, state}, book, Map.put(ok_outcome(true, false, nil, nil), :run, {:line, line})}

      {:done, text, []} ->
        {nil, book, ok_outcome(false, false, text, nil)}

      {:done, text, commands} ->
        if Keyword.get(opts, :defer_commands, false) do
          {nil, book, Map.put(ok_outcome(false, true, text, nil), :run, {:commands, commands})}
        else
          {new_book, outcomes} = Runner.run(book, root, commands, opts)
          {nil, new_book, ok_outcome(false, true, text, %{"outcomes" => outcomes})}
        end
    end
  end

  # --- ordinary (non-dialogue) commands, unchanged dialogue slot -------

  defp pass_through(dialogue, book, root, %{"method" => method} = command, opts) do
    {new_book, [outcome]} = Runner.run(book, root, [command], opts)

    {dialogue, new_book,
     %{
       hold: false,
       via_repl: via_repl?(method),
       text: nil,
       ok?: outcome.ok?,
       result: outcome.result,
       error: outcome.error
     }}
  end

  # Static per-method classification (Old.md §17.1) -- "eval" (the
  # Runner pseudo-method) and anything Pipeline.handles?/1 (its "eval"
  # stage) both do live REPL I/O; every other method that reaches here is
  # an ordinary Dispatch Tier1 call, no REPL involved.
  defp via_repl?("eval"), do: true
  defp via_repl?(method), do: Pipeline.handles?(method)

  defp ok_outcome(hold, via_repl, text, result),
    do: %{hold: hold, via_repl: via_repl, text: text, ok?: true, result: result, error: nil}

  defp error_outcome(code, message),
    do: %{hold: false, via_repl: false, text: nil, ok?: false, result: nil, error: %{"code" => code, "message" => message}}
end
