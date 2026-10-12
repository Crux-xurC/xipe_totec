defmodule XipeTotec.Dialogue do
  @moduledoc """
  The contract a multi-turn dialogue program implements to plug into
  `InOut`.

  A program never encodes the wire-level 2-bit message type itself --
  `InOut` infers it mechanically from which of the two return shapes below
  comes back:

    * `:hold` -- hold=1. `InOut` keeps `{module, state}` around and waits
      for the next `"dialogue/answer"` input before calling this program
      again.
    * `:done` with `commands == []` -- hold=0, via_repl=0 (finished inside
      xipe_totec). Nothing further happens; `text` is the whole result.
    * `:done` with a non-empty `commands` -- hold=0, via_repl=1. `InOut`
      immediately hands `commands` to `Runner.run/4` and folds its outcomes
      into the reply, in the same turn.

  `text` in both shapes is the human-readable line `InOut` appends to the
  `:out` side of the dialogue log -- a question while holding, a closing
  remark when done. The program owns its own `state` shape entirely;
  `InOut` never inspects it, only threads it back on the next `answer/2`
  call.

  Programs: `Dialogue.Depends`, `Dialogue.Search`, `Dialogue.Do`,
  `Dialogue.Rewrite`, `Dialogue.Update` (`InOut.programs/0`).
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
  this dialogue is held) as `answer/2`'s params. Optional:
  without it the line arrives as `%{"text" => line}`.
  """
  @callback parse_answer(line :: String.t()) :: map()

  ## Reading the Book, and passing a line on
  #
  # A program that needs to read the Book on every turn implements
  # start/2 / answer/3 instead of start/1 / answer/2: `InOut` then hands it
  # a read-only `ctx` (`%{book:, root:, project_dir:, log_file:}` --
  # `log_file` is XipeTotec.LogBuffer's file, nil when nothing is logged). It still never
  # changes the Book itself -- changes go through commands.
  #
  # Besides :hold and :done, a turn may return `{:pass, state, line}`: the
  # line is an ordinary command line (read the way the CLI reads one,
  # `XipeTotec.Input`), to be run by whoever drives the dialogue (the CLI's
  # prompt, `Serve.Input`) while the dialogue stays held. The driver runs it
  # rather than `InOut`, so an evaluation in it doesn't hold the server.

  @type ctx :: %{book: XipeTotec.Book.t(), root: String.t(), project_dir: Path.t() | nil, log_file: Path.t() | nil}
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
  (`"dialogue/quit"`); anything else is the answer.
  """
  @spec line_request(module(), String.t()) :: map()
  def line_request(mod, line) do
    case String.split(line) do
      w when w in [["quit", "dialogue"], ["xipe", "quit", "dialogue"]] -> %{"method" => "dialogue/quit", "params" => %{}}
      _ -> %{"method" => "dialogue/answer", "params" => answer_params(mod, line)}
    end
  end
end
