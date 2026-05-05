defmodule Golem.Config do
  @moduledoc """
  Loads user config from `.golem/config.yml` and `GOLEM_*` env vars into
  `Application.put_env(:golem, …)` at boot.

  Precedence (highest first):
    1. `GOLEM_*` environment variable
    2. Value in `.golem/config.yml`
    3. Hard-coded default in `Golem.Application.ensure_defaults/0`

  Missing file or missing keys are not errors — each setting is
  independent and falls through to the next layer.
  """

  require Logger

  # Lookup order — the first existing file wins. Project-local beats
  # the home-dir fallback so a developer in their golem clone sees their
  # repo config, not a stray ~/.golem/config.yml.
  @config_paths [
    ".golem/config.yml",
    "~/.golem/config.yml"
  ]

  # Each entry: {yaml_path, app_env_key, type, env_var_name}
  #
  # Adding a new setting: add a row here, document it in the example
  # file (`.golem/config.example.yml`) and AGENTS.md. `ensure_defaults/0`
  # in `Golem.Application` still needs the hard-coded fallback.
  @settings [
    # models
    {["models", "planner"], :planner_model, :string, "GOLEM_PLANNER_MODEL"},
    {["models", "executor"], :executor_model, :string, "GOLEM_EXECUTOR_MODEL"},
    {["models", "compaction"], :compaction_model, :string, "GOLEM_COMPACTION_MODEL"},

    # limits
    {["limits", "max_steps"], :max_steps, :int, "GOLEM_MAX_STEPS"},
    {["limits", "max_cost"], :max_cost, :float, "GOLEM_MAX_COST"},
    {["limits", "thinking_budget"], :thinking_budget, :int, "GOLEM_THINKING_BUDGET"},
    {["limits", "command_timeout"], :command_timeout, :int, "GOLEM_COMMAND_TIMEOUT"},
    {["limits", "stall_timeout"], :stall_timeout, :int, "GOLEM_STALL_TIMEOUT"},
    {["limits", "planner_max_tokens"], :planner_max_tokens, :int, "GOLEM_PLANNER_MAX_TOKENS"},
    {["limits", "planner_max_steps"], :planner_max_steps, :int, "GOLEM_PLANNER_MAX_STEPS"},
    {["limits", "executor_max_tokens"], :executor_max_tokens, :int, "GOLEM_EXECUTOR_MAX_TOKENS"},

    # container
    {["container", "name"], :container, :string, "GOLEM_CONTAINER"},
    {["container", "image"], :container_image, :string, "GOLEM_CONTAINER_IMAGE"},
    {["container", "user"], :container_user, :string, "GOLEM_CONTAINER_USER"}
  ]

  @doc """
  Read config file + env vars and apply to the Application env.
  Call once at application boot, BEFORE `ensure_defaults/0`.
  """
  def load do
    yaml = load_yaml()

    Enum.each(@settings, fn {yaml_path, app_key, type, env_var} ->
      value =
        case System.get_env(env_var) do
          nil -> get_in(yaml, yaml_path)
          "" -> get_in(yaml, yaml_path)
          env_value -> env_value
        end

      case cast_value(value, type) do
        :skip -> :ok
        cast -> Application.put_env(:golem, app_key, cast)
      end
    end)

    :ok
  end

  @doc """
  Settings catalogue, used by `Golem.Config` itself and by the
  `mix golem.config` task to print the resolved config.
  """
  def settings, do: @settings

  @doc """
  Returns the raw YAML map (or `%{}` if missing/invalid). Useful for
  introspection tools like `mix golem.config`.
  """
  def raw_yaml, do: load_yaml()

  @doc """
  Path of the config file that was (or would be) loaded — first match
  in the lookup chain, or the project-local default if none exist.
  Useful for error messages and debug tools.
  """
  def resolved_config_path do
    Enum.find(Enum.map(@config_paths, &expand_path/1), &File.exists?/1) ||
      expand_path(hd(@config_paths))
  end

  @doc """
  Expand a leading `~` in `path` to the user's home directory. Other
  paths are returned unchanged so podman, File.exists?, etc. handle
  them as before.
  """
  def expand_path(nil), do: nil
  def expand_path(""), do: ""
  def expand_path("~"), do: System.user_home!()
  def expand_path("~/" <> rest), do: Path.join(System.user_home!(), rest)
  def expand_path(path), do: path

  defp load_yaml do
    path = resolved_config_path()

    case YamlElixir.read_from_file(path) do
      {:ok, config} when is_map(config) ->
        config

      {:ok, _} ->
        %{}

      {:error, %YamlElixir.FileNotFoundError{}} ->
        %{}

      {:error, %YamlElixir.ParsingError{} = e} ->
        Logger.warning("Failed to parse #{path}: #{Exception.message(e)} — using defaults")
        %{}

      {:error, reason} ->
        Logger.warning("Failed to read #{path}: #{inspect(reason)} — using defaults")
        %{}
    end
  end

  defp cast_value(nil, _type), do: :skip
  defp cast_value("", _type), do: :skip

  defp cast_value(v, :string) when is_binary(v), do: v
  defp cast_value(v, :string), do: to_string(v)

  defp cast_value(v, :int) when is_integer(v), do: v

  defp cast_value(v, :int) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> :skip
    end
  end

  defp cast_value(v, :float) when is_float(v), do: v
  defp cast_value(v, :float) when is_integer(v), do: v * 1.0

  defp cast_value(v, :float) when is_binary(v) do
    case Float.parse(v) do
      {n, ""} -> n
      _ -> :skip
    end
  end

  defp cast_value(_, _), do: :skip
end
