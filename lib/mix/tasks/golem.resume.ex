defmodule Mix.Tasks.Golem.Resume do
  @moduledoc """
  Resume a paused run.

  ## Usage

      mix golem.resume <run_id>
      mix golem.resume <run_id> --max-steps 200
      mix golem.resume <run_id> --budget 30
      mix golem.resume <run_id> --message "also handle the fallback case"
      mix golem.resume --list

  ## Options

    * `--max-steps` / `-s` — additional steps on top of the saved step count
    * `--budget` / `-b` — raise the cost ceiling (USD). Useful when a run
      paused at `:budget_exceeded` and you want to give it more headroom
      to finish.
    * `--message` / `-m` — inject a system message before the next turn
    * `--list` / `-l` — list all saved runs
  """

  use Mix.Task

  @shortdoc "Resume a paused run"

  @impl true
  def run(args) do
    {opts, rest, _} =
      OptionParser.parse(args,
        strict: [max_steps: :integer, list: :boolean, message: :string, budget: :float],
        aliases: [s: :max_steps, l: :list, m: :message, b: :budget]
      )

    Mix.Task.run("app.start")

    # Apply budget override before starting — the runner reads max_cost
    # from Application env on every loop iteration, so setting it here
    # takes effect immediately for the resumed run.
    if opts[:budget], do: Application.put_env(:golem, :max_cost, opts[:budget])

    if opts[:list] do
      list_runs()
    else
      run_id = List.first(rest)

      if is_nil(run_id) do
        Mix.shell().error("Usage: mix golem.resume <run_id>")
        Mix.shell().error("       mix golem.resume --list")
        exit({:shutdown, 1})
      end

      runner_opts =
        (if opts[:max_steps], do: [max_steps: opts[:max_steps]], else: []) ++
        (if opts[:message], do: [inject_message: opts[:message]], else: [])

      Mix.shell().info("Resuming run #{run_id}...\n")

      case Golem.resume(run_id, runner_opts) do
        {:ok, _} ->
          :ok  # TUI handles completion message

        {:error, :max_steps_reached} ->
          :ok  # TUI handles pause message

        {:error, {:load_failed, reason}} ->
          Mix.shell().error("\n✗ Failed to load run: #{inspect(reason)}")

        {:error, _reason} ->
          :ok  # TUI handles error message
      end
    end
  end

  defp list_runs do
    runs = Golem.runs()

    if runs == [] do
      Mix.shell().info("No saved runs.")
    else
      Mix.shell().info("Saved runs:\n")

      for run <- runs do
        Mix.shell().info(
          "  #{run.id}  step #{run.step}/#{run.max_steps}  #{run.goal}"
        )
      end
    end
  end
end
