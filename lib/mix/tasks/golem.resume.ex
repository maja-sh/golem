defmodule Mix.Tasks.Golem.Resume do
  @moduledoc """
  Resume a paused run.

  ## Usage

      mix golem.resume <run_id>
      mix golem.resume <run_id> --max-steps 200
      mix golem.resume --list
  """

  use Mix.Task

  @shortdoc "Resume a paused run"

  @impl true
  def run(args) do
    {opts, rest, _} =
      OptionParser.parse(args,
        strict: [max_steps: :integer, list: :boolean],
        aliases: [s: :max_steps, l: :list]
      )

    Mix.Task.run("app.start")

    if opts[:list] do
      list_runs()
    else
      run_id = List.first(rest)

      if is_nil(run_id) do
        Mix.shell().error("Usage: mix golem.resume <run_id>")
        Mix.shell().error("       mix golem.resume --list")
        exit({:shutdown, 1})
      end

      runner_opts = if opts[:max_steps], do: [max_steps: opts[:max_steps]], else: []

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
