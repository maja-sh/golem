defmodule PinnedStatus.Scenario do
  @moduledoc """
  Tiny script format for exercising `PinnedStatus` without an LLM in
  the loop. A scenario is a list of `step` tuples. Tests `play/3`
  scripts against a recorder IO; the `mix pinned_status.demo` task
  plays them against the real terminal at real time.

  ## Step types

      {:pin, [iodata]}        — call set_status/2
      {:println, iodata}      — call println/2
      {:sleep, milliseconds}  — wait (only honored when real_time: true)
      {:mark, atom}           — bookmark the current byte offset
                                 (when the IO device is a StringIO)
  """

  @type step ::
          {:pin, [IO.chardata()]}
          | {:println, IO.chardata()}
          | {:sleep, non_neg_integer()}
          | {:mark, atom()}

  @doc """
  Play `steps` against the given PinnedStatus server.

  ## Options

    * `:real_time` — when true, `{:sleep, n}` actually sleeps n ms.
      Defaults to false (sleeps are skipped — good for tests).

    * `:io` — pass a StringIO pid to enable `{:mark, _}` step recording.
      Returns a map of `mark_name => byte_offset` as the second element
      of `{:ok, marks}`.
  """
  @spec play(server :: term(), [step()], keyword()) ::
          :ok | {:ok, %{atom() => non_neg_integer()}}
  def play(server, steps, opts \\ []) do
    real_time = Keyword.get(opts, :real_time, false)
    io = Keyword.get(opts, :io)

    marks =
      Enum.reduce(steps, %{}, fn step, marks ->
        apply_step(step, server, real_time, io, marks)
      end)

    if io, do: {:ok, marks}, else: :ok
  end

  defp apply_step({:pin, lines}, server, _real_time, _io, marks) do
    PinnedStatus.set_status(lines, name: server)
    marks
  end

  defp apply_step({:println, text}, server, _real_time, _io, marks) do
    PinnedStatus.println(text, name: server)
    marks
  end

  defp apply_step({:sleep, ms}, _server, true, _io, marks) do
    Process.sleep(ms)
    marks
  end

  defp apply_step({:sleep, _ms}, _server, false, _io, marks), do: marks

  defp apply_step({:mark, name}, _server, _real_time, io, marks) when is_pid(io) do
    {_, written} = StringIO.contents(io)
    Map.put(marks, name, byte_size(written))
  end

  defp apply_step({:mark, _name}, _server, _real_time, _io, marks), do: marks

  @doc """
  Load a scenario from a `.exs` file. The file's last expression must
  be a list of steps.
  """
  @spec load(Path.t()) :: [step()]
  def load(path) do
    {steps, _bindings} = Code.eval_file(path)
    unless is_list(steps), do: raise("scenario file must evaluate to a list of steps: #{path}")
    steps
  end
end
