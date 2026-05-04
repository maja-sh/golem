defmodule Golem.CLI.Config do
  @moduledoc """
  Print the resolved Golem configuration.

  Shows the effective value of each setting along with where it came
  from (env var, config.yml, or built-in default). Useful for verifying
  the precedence chain after editing `.golem/config.yml` or exporting
  GOLEM_* env vars.
  """

  def run(_argv) do
    Application.ensure_all_started(:golem)

    yaml = Golem.Config.raw_yaml()

    IO.puts("")
    IO.puts(IO.ANSI.format([:bright, "Golem config", :reset]))
    IO.puts(IO.ANSI.format([:faint, "  precedence: env > .golem/config.yml > default", :reset]))
    IO.puts("")

    Enum.each(Golem.Config.settings(), fn {yaml_path, app_key, _type, env_var} ->
      value = Application.get_env(:golem, app_key)
      source = source_of(yaml_path, yaml, env_var)

      source_color =
        case source do
          :env -> :magenta
          :yaml -> :cyan
          :default -> :faint
        end

      IO.puts(
        IO.ANSI.format([
          "  ",
          :white,
          String.pad_trailing(to_string(app_key), 22),
          :reset,
          " = ",
          :yellow,
          inspect(value),
          :reset,
          "  ",
          source_color,
          "(",
          to_string(source),
          ")",
          :reset
        ])
      )
    end)

    IO.puts("")
  end

  defp source_of(yaml_path, yaml, env_var) do
    cond do
      is_binary(System.get_env(env_var)) and System.get_env(env_var) != "" -> :env
      not is_nil(get_in(yaml, yaml_path)) -> :yaml
      true -> :default
    end
  end
end
