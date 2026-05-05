defmodule Golem.CLI.Doctor do
  @moduledoc """
  Validate Golem's configuration and runtime environment.

  Runs a sequence of checks against `.golem/config.yml`, required host
  binaries, the container image + state, and optional external services
  (Jira, MCP servers, Anthropic API). Each check prints `✓`/`⚠`/`✗`
  with a short reason. Exits non-zero if any check fails.
  """

  def run(_argv) do
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
    path = Golem.Config.resolved_config_path()
    label = "Config file"

    cond do
      not File.exists?(path) ->
        {:warn, label,
         "no config found in #{Enum.join(["./.golem/config.yml", "~/.golem/config.yml"], " or ")}. " <>
           "Copy .golem/config.example.yml to get started."}

      true ->
        case YamlElixir.read_from_file(path) do
          {:ok, _} -> {:ok, label, "#{display_path(path)} parses"}
          {:error, e} -> {:error, label, "#{display_path(path)}: #{inspect(e)}"}
        end
    end
  end

  # Render `~/...` instead of `/Users/<you>/...` when the config lives
  # under home — keeps the doctor output portable in screenshots.
  defp display_path(path) do
    home = System.user_home!()
    if String.starts_with?(path, home), do: "~" <> String.replace_prefix(path, home, ""), else: path
  end

  defp check_anthropic_key do
    case System.get_env("ANTHROPIC_API_KEY") do
      nil ->
        {:error, "ANTHROPIC_API_KEY", "not set — agent can't call Claude"}

      "" ->
        {:error, "ANTHROPIC_API_KEY", "empty — agent can't call Claude"}

      key ->
        case ping_anthropic(key) do
          :ok -> {:ok, "ANTHROPIC_API_KEY", "valid (#{mask(key)})"}
          {:error, reason} -> {:error, "ANTHROPIC_API_KEY", "set but rejected: #{reason}"}
        end
    end
  end

  # Cheap auth check — `/v1/models` is a token-free GET. 401 means bad
  # key; any other error is treated as a transient warning so a flaky
  # network doesn't fail doctor outright.
  defp ping_anthropic(key) do
    headers = [
      {"x-api-key", key},
      {"anthropic-version", "2023-06-01"}
    ]

    case Req.get("https://api.anthropic.com/v1/models", headers: headers, receive_timeout: 5_000) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: 401}} -> {:error, "401 unauthorized (typo? expired key?)"}
      {:ok, %{status: code}} -> {:error, "HTTP #{code}"}
      {:error, reason} -> {:error, "network: #{inspect(reason)}"}
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
      raw = Map.get(entry, "src", "")
      src = Golem.Config.expand_path(raw)
      required = Map.get(entry, "required", false)
      label = "Mount #{raw}"

      cond do
        raw == "" ->
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
    case Golem.Config.raw_yaml()["jira"] do
      nil ->
        {:warn, "Jira", "not configured (fine unless you use --jira)"}

      %{"base_url" => url} when is_binary(url) and url != "" ->
        # Presence-only check: Jira's API endpoints have been churning
        # (deprecations, scope changes), so a "validity" ping here is
        # more trouble than it's worth. Wrong creds surface during
        # ticket evaluation, before any expensive runner work.
        missing =
          Enum.reject(["JIRA_EMAIL", "JIRA_API_TOKEN"], fn v ->
            val = System.get_env(v)
            val != nil and val != ""
          end)

        if missing == [],
          do: {:ok, "Jira", "#{url} + creds set"},
          else: {:error, "Jira", "#{url} configured but missing env: #{Enum.join(missing, ", ")}"}

      _ ->
        {:error, "Jira", "jira.base_url missing or empty"}
    end
  end

  defp check_bitbucket do
    case Golem.ProjectSetup.load_config() do
      {:ok, %{bitbucket_workspace: ws}} when is_binary(ws) and ws != "" ->
        token = System.get_env("BITBUCKET_API_TOKEN")
        email = System.get_env("JIRA_EMAIL")

        cond do
          token in [nil, ""] ->
            {:error, "Bitbucket", "workspace=#{ws} but BITBUCKET_API_TOKEN not set"}

          email in [nil, ""] ->
            {:error, "Bitbucket", "workspace=#{ws} but JIRA_EMAIL not set (Bitbucket basic-auth uses it)"}

          true ->
            # Hit the workspace-scoped repos endpoint, which the
            # documented scope (repository:read) actually allows.
            # `/2.0/user` requires `account`, which our tokens don't have.
            url = "https://api.bitbucket.org/2.0/repositories/#{ws}?pagelen=1"

            case ping_basic_auth(url, "JIRA_EMAIL", "BITBUCKET_API_TOKEN") do
              :ok -> {:ok, "Bitbucket", "workspace=#{ws}, creds valid"}
              {:error, reason} -> {:error, "Bitbucket", "workspace=#{ws} creds rejected: #{reason}"}
            end
        end

      _ ->
        {:warn, "Bitbucket", "no workspace configured"}
    end
  end

  # Generic basic-auth GET ping. Used for both Jira /myself and
  # Bitbucket /2.0/user — both return 200 on valid creds, 401 on bad.
  defp ping_basic_auth(url, user_env, pass_env) do
    user = System.get_env(user_env)
    pass = System.get_env(pass_env)
    encoded = Base.encode64("#{user}:#{pass}")

    case Req.get(url, headers: [{"authorization", "Basic #{encoded}"}], receive_timeout: 5_000) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: 401}} -> {:error, "401 unauthorized"}
      {:ok, %{status: 403}} -> {:error, "403 forbidden (token scope?)"}
      {:ok, %{status: code}} -> {:error, "HTTP #{code}"}
      {:error, reason} -> {:error, "network: #{inspect(reason)}"}
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
