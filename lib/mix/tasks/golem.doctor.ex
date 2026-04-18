defmodule Mix.Tasks.Golem.Doctor do
  @moduledoc """
  Validate Golem's configuration and runtime environment.

  Runs a sequence of checks against `.golem/config.yml`, required
  host binaries, the container image + state, and optional external
  services (Jira, MCP servers, Anthropic API). Each check prints
  `✓`/`⚠`/`✗` with a short reason. Exits non-zero if any check fails.

      mix golem.doctor
  """
  use Mix.Task

  @shortdoc "Validate Golem config + runtime"

  @impl Mix.Task
  def run(_args) do
    Application.ensure_all_started(:golem)

    IO.puts("")
    IO.puts(IO.ANSI.format([:bright, "Golem doctor", :reset]))
    IO.puts("")

    results =
      [
        check_config_file(),
        check_anthropic_key(),
        check_runtime(),
        check_image(),
        check_container()
      ] ++
        check_mounts() ++
        [
          check_env_entries(),
          check_projects(),
          check_jira(),
          check_bitbucket()
        ] ++ check_mcp_servers()

    Enum.each(results, &print_result/1)

    IO.puts("")
    summary(results)

    if Enum.any?(results, &match?({:error, _, _}, &1)) do
      exit({:shutdown, 1})
    end
  end

  # --- checks ---

  defp check_config_file do
    path = ".golem/config.yml"

    cond do
      not File.exists?(path) ->
        {:warn, "Config file",
         "#{path} not found (using defaults + legacy yml files). Copy .golem/config.example.yml to get started."}

      true ->
        case YamlElixir.read_from_file(path) do
          {:ok, _} -> {:ok, "Config file", "#{path} parses"}
          {:error, e} -> {:error, "Config file", "#{path}: #{inspect(e)}"}
        end
    end
  end

  defp check_anthropic_key do
    case System.get_env("ANTHROPIC_API_KEY") do
      nil -> {:error, "ANTHROPIC_API_KEY", "not set — agent can't call Claude"}
      "" -> {:error, "ANTHROPIC_API_KEY", "empty — agent can't call Claude"}
      key -> {:ok, "ANTHROPIC_API_KEY", "set (#{mask(key)})"}
    end
  end

  defp check_runtime do
    runtime = Golem.Runtime.cmd()

    case System.find_executable(runtime) do
      nil -> {:error, "Container runtime", "#{runtime} not found in PATH"}
      path -> {:ok, "Container runtime", "#{runtime} at #{path}"}
    end
  end

  defp check_image do
    image = Application.get_env(:golem, :container_image, "golem-vm:latest")
    runtime = Golem.Runtime.cmd()

    case System.find_executable(runtime) do
      nil ->
        {:skip, "Image", "skipped (runtime missing)"}

      exe ->
        case System.cmd(exe, ["image", "exists", image], stderr_to_stdout: true) do
          {_, 0} -> {:ok, "Image", "#{image} present"}
          {_, _} -> {:warn, "Image", "#{image} not built yet — will build on first run"}
        end
    end
  end

  defp check_container do
    name = Application.get_env(:golem, :container, "golem-vm")
    runtime = Golem.Runtime.cmd()

    case System.find_executable(runtime) do
      nil ->
        {:skip, "Container", "skipped (runtime missing)"}

      exe ->
        case System.cmd(exe, ["inspect", "-f", "{{.State.Status}}", name], stderr_to_stdout: true) do
          {out, 0} ->
            case String.trim(out) do
              "running" -> {:ok, "Container", "#{name} running"}
              status -> {:warn, "Container", "#{name} exists but #{status} (will be started on next run)"}
            end

          {_, _} ->
            {:warn, "Container", "#{name} not created yet (will be created on first run)"}
        end
    end
  end

  defp check_mounts do
    mounts = Golem.Config.raw_yaml() |> get_in(["container", "mounts"]) || []

    Enum.map(mounts, fn entry ->
      src = Map.get(entry, "src", "")
      required = Map.get(entry, "required", false)
      label = "Mount #{src}"

      cond do
        src == "" ->
          {:error, label, "missing src field in config"}

        File.exists?(src) or File.dir?(src) ->
          {:ok, label, "exists"}

        required ->
          {:error, label, "required but not found on host"}

        true ->
          {:warn, label, "not found (skipped — not required)"}
      end
    end)
  end

  defp check_env_entries do
    entries = Golem.Config.raw_yaml() |> get_in(["container", "env"]) || []
    defined = count_defined_env(entries)
    total = length(entries)

    if total == 0,
      do: {:ok, "Container env", "no entries"},
      else: {:ok, "Container env", "#{defined}/#{total} entries resolvable"}
  end

  defp count_defined_env(entries) do
    Enum.count(entries, fn
      name when is_binary(name) ->
        v = System.get_env(name)
        v != nil and v != ""

      %{"name" => _, "value" => _} = e ->
        case Map.get(e, "when_file") do
          nil -> true
          path -> File.exists?(path)
        end

      _ ->
        false
    end)
  end

  defp check_projects do
    case Golem.ProjectSetup.load_config() do
      {:ok, %{projects: []}} ->
        {:warn, "Projects", "no projects configured"}

      {:ok, %{projects: projects}} ->
        bad =
          Enum.filter(projects, fn p ->
            is_nil(p.repo) or is_nil(p.path) or p.repo == "" or p.path == ""
          end)

        if bad == [] do
          {:ok, "Projects", "#{length(projects)} configured"}
        else
          {:error, "Projects",
           "#{length(bad)} entries missing repo or path: #{Enum.map_join(bad, ", ", &(&1.repo || "<no repo>"))}"}
        end

      {:error, reason} ->
        {:error, "Projects", reason}
    end
  end

  defp check_jira do
    unified = Golem.Config.raw_yaml()

    jira_config =
      cond do
        is_map(unified["jira"]) -> unified["jira"]
        File.exists?(".golem/jira.yml") -> legacy_jira_config()
        true -> nil
      end

    case jira_config do
      nil ->
        {:warn, "Jira", "not configured (fine unless you use --jira)"}

      %{"base_url" => url} when is_binary(url) and url != "" ->
        email = System.get_env("JIRA_EMAIL")
        token = System.get_env("JIRA_API_TOKEN")

        missing =
          Enum.reject(["JIRA_EMAIL", "JIRA_API_TOKEN"], fn v ->
            val = System.get_env(v)
            val != nil and val != ""
          end)

        cond do
          missing == [] ->
            {:ok, "Jira", "#{url} + creds set"}

          email == nil or token == nil ->
            {:error, "Jira", "#{url} configured but missing env: #{Enum.join(missing, ", ")}"}
        end

      _ ->
        {:error, "Jira", "jira.base_url missing or empty"}
    end
  end

  defp legacy_jira_config do
    case YamlElixir.read_from_file(".golem/jira.yml") do
      {:ok, config} -> config["jira"] || %{}
      _ -> %{}
    end
  end

  defp check_bitbucket do
    case Golem.ProjectSetup.load_config() do
      {:ok, %{bitbucket_workspace: ws}} when is_binary(ws) and ws != "" ->
        case System.get_env("BITBUCKET_API_TOKEN") do
          nil -> {:error, "Bitbucket", "workspace=#{ws} but BITBUCKET_API_TOKEN not set"}
          "" -> {:error, "Bitbucket", "workspace=#{ws} but BITBUCKET_API_TOKEN empty"}
          _ -> {:ok, "Bitbucket", "workspace=#{ws}, token set"}
        end

      _ ->
        {:warn, "Bitbucket", "no workspace configured"}
    end
  end

  defp check_mcp_servers do
    case Golem.MCP.status() do
      [] ->
        [{:ok, "MCP", "no servers configured"}]

      entries ->
        Enum.map(entries, fn
          {:ok, name, count} -> {:ok, "MCP #{name}", "#{count} tools"}
          {:error, name, reason} -> {:error, "MCP #{name}", reason}
        end)
    end
  rescue
    _ -> [{:warn, "MCP", "status check failed (MCP manager not running)"}]
  end

  # --- output ---

  defp print_result({level, label, msg}) do
    {icon, color} =
      case level do
        :ok -> {"✓", :green}
        :warn -> {"⚠", :yellow}
        :error -> {"✗", :red}
        :skip -> {"·", :faint}
      end

    # Pad to 28 for column alignment; labels longer than that get a
    # single trailing space so the message doesn't collide with them.
    padded =
      if String.length(label) >= 28,
        do: label <> " ",
        else: String.pad_trailing(label, 28)

    IO.puts(
      IO.ANSI.format([
        "  ",
        color,
        icon,
        " ",
        :white,
        padded,
        :reset,
        :faint,
        msg,
        :reset
      ])
    )
  end

  defp summary(results) do
    counts = Enum.frequencies_by(results, &elem(&1, 0))
    errors = Map.get(counts, :error, 0)
    warns = Map.get(counts, :warn, 0)

    cond do
      errors > 0 ->
        IO.puts(IO.ANSI.format([:red, :bright, "✗ #{errors} error(s)", :reset, :faint, ", #{warns} warning(s)", :reset]))

      warns > 0 ->
        IO.puts(IO.ANSI.format([:yellow, :bright, "⚠ #{warns} warning(s)", :reset]))

      true ->
        IO.puts(IO.ANSI.format([:green, :bright, "✓ all checks passed", :reset]))
    end

    IO.puts("")
  end

  defp mask(key) when byte_size(key) > 8 do
    head = binary_part(key, 0, 4)
    tail = binary_part(key, byte_size(key) - 4, 4)
    "#{head}…#{tail}"
  end

  defp mask(_), do: "***"
end
