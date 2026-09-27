defmodule XipeTotec.Dialogue do
  @moduledoc """
  The contract a multi-turn dialogue program implements to plug into
  `InOut` (this file's sibling, Old.md §17, 2026-09-20 co-design).

  A program never encodes the wire-level 2-bit message type itself --
  `InOut` infers it mechanically from which of the two return shapes below
  comes back:

    * `:hold` -- bit1 (保持)=1. `InOut` keeps `{module, state}` around and
      waits for the next `"dialogue/answer"` input before calling this
      program again.
    * `:done` with `commands == []` -- bit1=0, bit2=1 (`01`, xipe_totec内
      で完結). Nothing further happens; `text` is the whole result.
    * `:done` with a non-empty `commands` -- bit1=0, bit2=0 (`00`, REPLへ
      投下). `InOut` immediately hands `commands` to `Runner.run/4` and
      folds its outcomes into the reply, in the same turn.

  `text` in both shapes is the human-readable line `InOut` appends to the
  `:out` side of the dialogue log (Old.md §17's `{:in, text} | {:out,
  text}` entries) -- a question ("Xに値を入れて評価しますか？(y/n)") while
  holding, a closing remark ("以上の内容で評価を行います" and similar)
  when done. The program owns its own `state` shape entirely; `InOut`
  never inspects it, only threads it back on the next `answer/2` call.

  No program exists yet that implements this (Old.md §16.4's
  dependency-chain negotiation is designed but not built -- it's step 4 of
  §16.4's agreed order, this behaviour and `InOut` are step 3).
  `test/in_out_test.exs`'s `ToyDialogue` is the only implementation today,
  proving the wiring independent of any real program (same reasoning as
  `Repl.Evaluator`'s `ToyLanguage` test).
  """

  @doc "Starts a dialogue from the method name that named this program in `InOut`'s registry. `params` is that request's own params, unexamined by InOut."
  @callback start(params :: map()) ::
              {:hold, state :: term(), text :: String.t()}
              | {:done, text :: String.t(), commands :: [map()]}

  @doc "Continues a held dialogue with the next \"dialogue/answer\" input's params."
  @callback answer(state :: term(), params :: map()) ::
              {:hold, state :: term(), text :: String.t()}
              | {:done, text :: String.t(), commands :: [map()]}

  @doc """
  One typed line (the CLI's prompt, or the dialogue window's `input` while
  this dialogue is held, 2026-09-27) as `answer/2`'s params. Optional:
  without it the line arrives as `%{"text" => line}`.
  """
  @callback parse_answer(line :: String.t()) :: map()

  ## Reading the Book, and passing a line on (2026-09-27, for Dialogue.Search)
  #
  # A program that needs to read the Book on every turn implements
  # start/2 / answer/3 instead of start/1 / answer/2: `InOut` then hands it
  # a read-only `ctx` (`%{book:, root:, project_dir:}`). It still never
  # changes the Book itself -- changes go through commands, as before.
  #
  # Besides :hold and :done, a turn may return `{:pass, state, line}`: the
  # line is an ordinary command line (read the way the CLI reads one,
  # `XipeTotec.Input`), to be run by whoever drives the dialogue (the CLI's
  # prompt, `Serve.Input`) while the dialogue stays held. The driver runs it
  # rather than `InOut`, so an evaluation in it doesn't hold the server.

  @type ctx :: %{book: XipeTotec.Book.t(), root: String.t(), project_dir: Path.t() | nil}
  @type turn ::
          {:hold, term(), String.t()}
          | {:done, String.t(), [map()]}
          | {:pass, term(), String.t()}

  @callback start(params :: map(), ctx()) :: turn()
  @callback answer(state :: term(), params :: map(), ctx()) :: turn()

  @optional_callbacks parse_answer: 1, start: 1, start: 2, answer: 2, answer: 3

  @doc "`mod.parse_answer/1` if it has one, else `%{\"text\" => line}`."
  @spec answer_params(module(), String.t()) :: map()
  def answer_params(mod, line) do
    Code.ensure_loaded(mod)
    if function_exported?(mod, :parse_answer, 1), do: mod.parse_answer(line), else: %{"text" => line}
  end

  @doc """
  A typed line to a held dialogue, as the request `InOut.handle/6` takes:
  `quit dialogue` (`xipe quit dialogue`) ends any dialogue
  (`"dialogue/quit"`, next_step §1.1); anything else is the answer.
  """
  @spec line_request(module(), String.t()) :: map()
  def line_request(mod, line) do
    case String.split(line) do
      w when w in [["quit", "dialogue"], ["xipe", "quit", "dialogue"]] -> %{"method" => "dialogue/quit", "params" => %{}}
      _ -> %{"method" => "dialogue/answer", "params" => answer_params(mod, line)}
    end
  end
end
