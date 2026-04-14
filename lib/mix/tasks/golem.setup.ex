defmodule Mix.Tasks.Golem.Setup do
  @moduledoc """
  Test project setup from .golem/jira.yml without running the agent.

  Loads the config, clones/pulls all projects into the container,
  creates a test branch, and prints the layout.

  ## Usage

      mix golem.setup
      mix golem.setup --branch test-branch-name
  """

  use Mix.Task

  @shortdoc "Test project setup (clone repos, create branch, no agent run)"

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [branch: :string],
        aliases: [b: :branch]
      )

    Mix.Task.run("app.start")

    branch = opts[:branch] || "golem/setup-test"

    case Golem.ProjectSetup.load_config() do
      {:ok, config} ->
        Mix.shell().info("\n=== Config loaded ===")
        Mix.shell().info("Bitbucket workspace: #{config.bitbucket_workspace}")
        Mix.shell().info("Projects: #{length(config.projects)}")

        for p <- config.projects do
          desc = if p.description, do: " — #{p.description}", else: ""
          Mix.shell().info("  #{p.repo}#{desc} (base: #{p.branch_from})")
        end

        Mix.shell().info("\n=== Setting up projects (branch: #{branch}) ===")

        case Golem.ProjectSetup.setup_projects(config, "SETUP", "test") do
          {:ok, actual_branch} ->
            Mix.shell().info("\nBranch: #{actual_branch}")
            for p <- config.projects do
              Mix.shell().info("  #{p.repo} → #{p.path}")
            end
            Mix.shell().info("\nSetup complete. Projects are cloned and ready.")

          {:error, reason} ->
            Mix.shell().error("\nSetup failed: #{inspect(reason)}")
        end

      {:error, reason} ->
        Mix.shell().error("Failed to load config: #{inspect(reason)}")
    end
  end
end
