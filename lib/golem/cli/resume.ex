defmodule Golem.CLI.Resume do
  @moduledoc """
  Resume a paused run.

  Usage:

      golem resume <run_id>
      golem resume <run_id> --max-steps 200
      golem resume <run_id> --budget 30
      golem resume <run_id> --message "also handle the fallback case"
      golem resume --list
  """

  def run(argv) do
    {opts, rest, _} =
      OptionParser.parse(argv,
        strict: [max_steps: :integer, list: :boolean, message: :string, budget: :float],
        aliases: [s: :max_steps, l: :list, m: :message, b: :budget]
      )

    Application.ensure_all_started(:golem)

    if opts[:budget], do: Application.put_env(:golem, :max_cost, opts[:budget])

    if opts[:list] do
      list_runs()
    else
      run_id = List.first(rest)

      if is_nil(run_id) do
        IO.puts(:stderr, "Usage: golem resume <run_id>")
        IO.puts(:stderr, "       golem resume --list")
        exit({:shutdown, 1})
      end

      runner_opts =
        (if opts[:max_steps], do: [max_steps: opts[:max_steps]], else: []) ++
          (if opts[:message], do: [inject_message: opts[:message]], else: [])

      IO.puts("Resuming run #{run_id}...\n")

      case Golem.resume(run_id, runner_opts) do
        {:ok, _} -> :ok
        {:error, :max_steps_reached} -> :ok
        {:error, {:load_failed, reason}} ->
          IO.puts(:stderr, "\n✗ Failed to load run: #{inspect(reason)}")

        {:error, _reason} -> :ok
      end
    end
  end

  defp list_runs do
    runs = Golem.runs()

    if runs == [] do
      IO.puts("No saved runs.")
    else
      IO.puts("Saved runs:\n")

      for run <- runs do
        IO.puts("  #{run.id}  step #{run.step}/#{run.max_steps}  #{run.goal}")
      end
    end
  end
end
