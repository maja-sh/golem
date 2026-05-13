defmodule Golem.ConfigTest do
  # async: false because load/0 touches the global Application env.
  use ExUnit.Case, async: false

  alias Golem.Config

  @test_dir "test/tmp_config"
  @test_path Path.join(@test_dir, "config.yaml")

  # Settings managed outside the @settings catalogue
  # (load_models_block / load_providers_block). The setup hook needs to
  # snapshot + clear these manually because the catalogue doesn't know
  # about them.
  @extra_app_keys ~w(
    planner_model planner_provider
    executor_model executor_provider
    compaction_model compaction_provider
    anthropic_api_key_env openrouter_api_key_env openrouter_base_url
  )a

  @extra_env_vars ~w(
    GOLEM_PLANNER_MODEL GOLEM_PLANNER_PROVIDER
    GOLEM_EXECUTOR_MODEL GOLEM_EXECUTOR_PROVIDER
    GOLEM_COMPACTION_MODEL GOLEM_COMPACTION_PROVIDER
  )

  setup do
    File.mkdir_p!(@test_dir)

    # Snapshot + restore all settings we might touch.
    snapshot =
      for {_, app_key, _, _} <- Config.settings(), into: %{} do
        {app_key, Application.get_env(:golem, app_key)}
      end

    extra_snapshot =
      for app_key <- @extra_app_keys, into: %{} do
        {app_key, Application.get_env(:golem, app_key)}
      end

    env_snapshot =
      for {_, _, _, env_var} <- Config.settings(), into: %{} do
        {env_var, System.get_env(env_var)}
      end

    extra_env_snapshot =
      for env_var <- @extra_env_vars, into: %{} do
        {env_var, System.get_env(env_var)}
      end

    # Clear any lingering test env vars to isolate precedence tests.
    for {var, _} <- env_snapshot, do: System.delete_env(var)
    for {var, _} <- extra_env_snapshot, do: System.delete_env(var)

    on_exit(fn ->
      for {key, val} <- Map.merge(snapshot, extra_snapshot) do
        if val == nil,
          do: Application.delete_env(:golem, key),
          else: Application.put_env(:golem, key, val)
      end

      for {var, val} <- Map.merge(env_snapshot, extra_env_snapshot) do
        if val == nil, do: System.delete_env(var), else: System.put_env(var, val)
      end

      File.rm_rf!(@test_dir)
    end)

    :ok
  end

  defp write_config(content), do: File.write!(@test_path, content)

  defp with_config_path(fun) do
    # Golem.Config hard-codes the path. We stub by chdir so the relative
    # ".golem/config.yaml" resolves under our test dir.
    original = File.cwd!()
    File.mkdir_p!(Path.join(@test_dir, ".golem"))

    case File.read(@test_path) do
      {:ok, content} -> File.write!(Path.join([@test_dir, ".golem", "config.yaml"]), content)
      _ -> :ok
    end

    File.cd!(@test_dir)

    try do
      fun.()
    after
      File.cd!(original)
    end
  end

  describe "load/0 — no config file" do
    test "leaves Application env untouched when file is missing" do
      # With no file and no ENV, nothing should change.
      with_config_path(fn ->
        Application.delete_env(:golem, :planner_model)
        Config.load()
        assert Application.get_env(:golem, :planner_model) == nil
      end)
    end
  end

  describe "load/0 — YAML" do
    test "applies integer values" do
      write_config("""
      limits:
        max_steps: 42
        thinking_budget: 8000
      """)

      with_config_path(fn ->
        Config.load()
        assert Application.get_env(:golem, :max_steps) == 42
        assert Application.get_env(:golem, :thinking_budget) == 8000
      end)
    end

    test "applies float values" do
      write_config("""
      limits:
        max_cost: 25.5
      """)

      with_config_path(fn ->
        Config.load()
        assert Application.get_env(:golem, :max_cost) == 25.5
      end)
    end

    test "integer YAML value cast to float where expected" do
      write_config("""
      limits:
        max_cost: 30
      """)

      with_config_path(fn ->
        Config.load()
        assert Application.get_env(:golem, :max_cost) == 30.0
      end)
    end

    test "missing keys are not touched" do
      write_config("""
      models:
        planner:
          provider: anthropic
          model: opus-foo
      """)

      with_config_path(fn ->
        Application.put_env(:golem, :executor_model, "preexisting")
        Config.load()
        assert Application.get_env(:golem, :planner_model) == "opus-foo"
        assert Application.get_env(:golem, :executor_model) == "preexisting"
      end)
    end
  end

  describe "load/0 — ENV overrides" do
    test "env var overrides yaml" do
      write_config("""
      models:
        planner:
          provider: anthropic
          model: yaml-planner
      """)

      System.put_env("GOLEM_PLANNER_MODEL", "env-planner")

      with_config_path(fn ->
        Config.load()
        assert Application.get_env(:golem, :planner_model) == "env-planner"
      end)
    end

    test "env var casts string '200' to integer for int settings" do
      System.put_env("GOLEM_MAX_STEPS", "200")

      with_config_path(fn ->
        Config.load()
        assert Application.get_env(:golem, :max_steps) == 200
      end)
    end

    test "env var casts string '12.5' to float" do
      System.put_env("GOLEM_MAX_COST", "12.5")

      with_config_path(fn ->
        Config.load()
        assert Application.get_env(:golem, :max_cost) == 12.5
      end)
    end

    test "empty env var is treated as unset (falls through to yaml)" do
      write_config("""
      models:
        planner:
          provider: anthropic
          model: yaml-planner
      """)

      System.put_env("GOLEM_PLANNER_MODEL", "")

      with_config_path(fn ->
        Config.load()
        assert Application.get_env(:golem, :planner_model) == "yaml-planner"
      end)
    end

    test "invalid int env var is skipped" do
      System.put_env("GOLEM_MAX_STEPS", "not-a-number")

      with_config_path(fn ->
        Application.put_env(:golem, :max_steps, 99)
        Config.load()
        # Invalid value is skipped — preexisting value untouched.
        assert Application.get_env(:golem, :max_steps) == 99
      end)
    end
  end

  describe "settings/0" do
    test "exposes the catalogue" do
      catalogue = Config.settings()
      assert is_list(catalogue)
      # Models are handled by load_models_block/1 outside the catalogue.
      # Check a representative scalar setting is present.
      assert Enum.any?(catalogue, fn {_, key, _, _} -> key == :max_steps end)
      assert Enum.any?(catalogue, fn {_, _, _, env} -> env == "GOLEM_MAX_STEPS" end)
    end
  end

  describe "load/0 — models block" do
    test "string form is rejected with a helpful error" do
      write_config("""
      models:
        planner: claude-opus-4-7
      """)

      with_config_path(fn ->
        assert_raise RuntimeError, ~r/Invalid model entry/, fn -> Config.load() end
      end)
    end

    test "map form sets both provider and model" do
      write_config("""
      models:
        executor:
          provider: openrouter
          model: qwen/qwen-2.5-coder-32b-instruct
      """)

      with_config_path(fn ->
        Config.load()
        assert Application.get_env(:golem, :executor_provider) == :openrouter
        assert Application.get_env(:golem, :executor_model) == "qwen/qwen-2.5-coder-32b-instruct"
      end)
    end

    test "GOLEM_*_PROVIDER env var overrides yaml provider" do
      write_config("""
      models:
        executor:
          provider: anthropic
          model: claude-sonnet-4-6
      """)

      System.put_env("GOLEM_EXECUTOR_PROVIDER", "openrouter")

      with_config_path(fn ->
        Config.load()
        assert Application.get_env(:golem, :executor_provider) == :openrouter
        # Model from yaml is preserved.
        assert Application.get_env(:golem, :executor_model) == "claude-sonnet-4-6"
      end)
    end

    test "unknown provider in yaml falls back to :anthropic with a warning" do
      write_config("""
      models:
        executor:
          provider: bogus
          model: foo
      """)

      with_config_path(fn ->
        Config.load()
        assert Application.get_env(:golem, :executor_provider) == :anthropic
        assert Application.get_env(:golem, :executor_model) == "foo"
      end)
    end
  end

  describe "load/0 — providers block" do
    test "anthropic.api_key_env override is applied" do
      write_config("""
      providers:
        anthropic:
          api_key_env: MY_ANTHROPIC_KEY
      """)

      with_config_path(fn ->
        Config.load()
        assert Application.get_env(:golem, :anthropic_api_key_env) == "MY_ANTHROPIC_KEY"
      end)
    end

    test "openrouter.api_key_env and base_url overrides are applied" do
      write_config("""
      providers:
        openrouter:
          api_key_env: MY_OR_KEY
          base_url: https://openrouter.example.com/api/v1
      """)

      with_config_path(fn ->
        Config.load()
        assert Application.get_env(:golem, :openrouter_api_key_env) == "MY_OR_KEY"
        assert Application.get_env(:golem, :openrouter_base_url) == "https://openrouter.example.com/api/v1"
      end)
    end
  end
end
