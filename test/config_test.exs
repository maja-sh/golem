defmodule Golem.ConfigTest do
  # async: false because load/0 touches the global Application env.
  use ExUnit.Case, async: false

  alias Golem.Config

  @test_dir "test/tmp_config"
  @test_path Path.join(@test_dir, "config.yml")

  setup do
    File.mkdir_p!(@test_dir)

    # Snapshot + restore all settings we might touch.
    snapshot =
      for {_, app_key, _, _} <- Config.settings(), into: %{} do
        {app_key, Application.get_env(:golem, app_key)}
      end

    env_snapshot =
      for {_, _, _, env_var} <- Config.settings(), into: %{} do
        {env_var, System.get_env(env_var)}
      end

    # Clear any lingering test env vars to isolate precedence tests.
    for {var, _} <- env_snapshot, do: System.delete_env(var)

    on_exit(fn ->
      for {key, val} <- snapshot do
        if val == nil,
          do: Application.delete_env(:golem, key),
          else: Application.put_env(:golem, key, val)
      end

      for {var, val} <- env_snapshot do
        if val == nil, do: System.delete_env(var), else: System.put_env(var, val)
      end

      File.rm_rf!(@test_dir)
    end)

    :ok
  end

  defp write_config(content), do: File.write!(@test_path, content)

  defp with_config_path(fun) do
    # Golem.Config hard-codes the path. We stub by chdir so the relative
    # ".golem/config.yml" resolves under our test dir.
    original = File.cwd!()
    File.mkdir_p!(Path.join(@test_dir, ".golem"))

    case File.read(@test_path) do
      {:ok, content} -> File.write!(Path.join([@test_dir, ".golem", "config.yml"]), content)
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
    test "applies string values" do
      write_config("""
      models:
        planner: claude-sonnet-4-6
        executor: claude-haiku-4-5
      """)

      with_config_path(fn ->
        Config.load()
        assert Application.get_env(:golem, :planner_model) == "claude-sonnet-4-6"
        assert Application.get_env(:golem, :executor_model) == "claude-haiku-4-5"
      end)
    end

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
        planner: opus-foo
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
        planner: yaml-planner
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
        planner: yaml-planner
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
      assert Enum.any?(catalogue, fn {_, key, _, _} -> key == :planner_model end)
      assert Enum.any?(catalogue, fn {_, _, _, env} -> env == "GOLEM_EXECUTOR_MODEL" end)
    end
  end
end
