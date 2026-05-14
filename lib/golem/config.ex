defmodule Golem.Config do
  @moduledoc """
  Loads user config from `.golem/config.yaml` and `GOLEM_*` env vars into
  `Application.put_env(:golem, …)` at boot.

  Precedence (highest first):
    1. `GOLEM_*` environment variable
    2. Value in `.golem/config.yaml`
    3. Hard-coded default in `Golem.Application.ensure_defaults/0`

  Missing file or missing keys are not errors — each setting is
  independent and falls through to the next layer.
  """

  require Logger

  # Lookup order — the first existing file wins. Project-local beats
  # the home-dir fallback so a developer in their golem clone sees their
  # repo config, not a stray ~/.golem/config.yaml.
  @config_paths [
    ".golem/config.yaml",
    "~/.golem/config.yaml"
  ]

  # Each entry: {yaml_path, app_env_key, type, env_var_name}
  #
  # Adding a new setting: add a row here, document it in the example
  # file (`.golem/config.example.yaml`) and AGENTS.md. `ensure_defaults/0`
  # in `Golem.Application` still needs the hard-coded fallback.
  @settings [
    # models — each role is a map `{provider, model}` handled by
    # `load_models_block/1`, NOT by the generic @settings loader,
    # because cast_value can't write two app-env keys from one YAML
    # value. (The `:planner_model` / `:executor_model` /
    # `:compaction_model` app-env keys are still written; they just
    # come from the helper.)

    # limits
    {["limits", "max_steps"], :max_steps, :int, "GOLEM_MAX_STEPS"},
    {["limits", "max_cost"], :max_cost, :float, "GOLEM_MAX_COST"},
    {["limits", "thinking_budget"], :thinking_budget, :int, "GOLEM_THINKING_BUDGET"},
    {["limits", "command_timeout"], :command_timeout, :int, "GOLEM_COMMAND_TIMEOUT"},
    {["limits", "stall_timeout"], :stall_timeout, :int, "GOLEM_STALL_TIMEOUT"},
    {["limits", "planner_max_tokens"], :planner_max_tokens, :int, "GOLEM_PLANNER_MAX_TOKENS"},
    {["limits", "planner_max_steps"], :planner_max_steps, :int, "GOLEM_PLANNER_MAX_STEPS"},
    {["limits", "executor_max_tokens"], :executor_max_tokens, :int, "GOLEM_EXECUTOR_MAX_TOKENS"},
    {["limits", "context_window"], :context_window, :int, "GOLEM_CONTEXT_WINDOW"},
    {["limits", "max_escalations"], :max_escalations, :int, "GOLEM_MAX_ESCALATIONS"},

    # container
    {["container", "name"], :container, :string, "GOLEM_CONTAINER"},
    {["container", "image"], :container_image, :string, "GOLEM_CONTAINER_IMAGE"},
    {["container", "user"], :container_user, :string, "GOLEM_CONTAINER_USER"},

    # jira
    {["jira", "comment_on_ticket"], :jira_comment_on_ticket, :bool, "GOLEM_JIRA_COMMENT_ON_TICKET"}
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

    load_models_block(yaml)
    load_providers_block(yaml)

    :ok
  end

  # Handle the `models:` block. Each role is a map of the form
  # `{provider: "...", model: "..."}`. Env vars override either field
  # independently.
  defp load_models_block(yaml) do
    models = get_in(yaml, ["models"]) || %{}

    for role <- ~w(planner executor compaction escalation) do
      {yaml_model, yaml_provider} = parse_model_entry(Map.get(models, role))
      env_model = nonempty(System.get_env("GOLEM_#{String.upcase(role)}_MODEL"))
      env_provider = nonempty(System.get_env("GOLEM_#{String.upcase(role)}_PROVIDER"))

      if model = env_model || yaml_model do
        Application.put_env(:golem, :"#{role}_model", model)
      end

      if provider = env_provider || yaml_provider do
        Application.put_env(:golem, :"#{role}_provider", to_provider_atom(provider))
      end
    end
  end

  defp parse_model_entry(nil), do: {nil, nil}

  defp parse_model_entry(%{} = m) do
    {m["model"] || m[:model], m["provider"] || m[:provider]}
  end

  defp parse_model_entry(other) do
    raise """
    Invalid model entry in .golem/config.yaml: #{inspect(other)}

    Each role under `models:` must be a map with `provider` and `model` keys:

        models:
          executor:
            provider: anthropic
            model: claude-sonnet-4-6
    """
  end

  # Whitelisted set — String.to_atom on untrusted YAML input would
  # silently accept typos and then explode in Golem.LLM's provider
  # lookup. Be loud here instead.
  @known_providers ~w(anthropic openrouter)

  defp to_provider_atom(p) when is_atom(p) and p in [:anthropic, :openrouter], do: p

  defp to_provider_atom(p) when is_binary(p) do
    if p in @known_providers do
      String.to_atom(p)
    else
      Logger.warning("Unknown provider #{inspect(p)} — defaulting to :anthropic")
      :anthropic
    end
  end

  defp to_provider_atom(_), do: :anthropic

  # Handle the `providers:` block. Each provider currently exposes
  # `api_key_env` (env var to look up the key in) and, for OpenRouter,
  # `base_url` (override for testing or self-hosted gateways).
  defp load_providers_block(yaml) do
    providers = get_in(yaml, ["providers"]) || %{}

    if anthropic = providers["anthropic"] do
      maybe_put_env(:anthropic_api_key_env, anthropic["api_key_env"])
    end

    if openrouter = providers["openrouter"] do
      maybe_put_env(:openrouter_api_key_env, openrouter["api_key_env"])
      maybe_put_env(:openrouter_base_url, openrouter["base_url"])
    end
  end

  defp maybe_put_env(_key, nil), do: :ok
  defp maybe_put_env(_key, ""), do: :ok
  defp maybe_put_env(key, value), do: Application.put_env(:golem, key, value)

  defp nonempty(nil), do: nil
  defp nonempty(""), do: nil
  defp nonempty(s), do: s

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

  defp cast_value(v, :bool) when is_boolean(v), do: v

  defp cast_value(v, :bool) when is_binary(v) do
    case String.downcase(v) do
      x when x in ~w(true 1 yes on) -> true
      x when x in ~w(false 0 no off) -> false
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
