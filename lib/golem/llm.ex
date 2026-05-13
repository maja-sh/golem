defmodule Golem.LLM do
  @moduledoc """
  Entry point for model calls. Dispatches to the configured
  `Golem.Provider` implementation based on the `:provider` opt (or the
  role-derived default).

  ## Usage

      Golem.LLM.call(messages,
        provider: :anthropic,
        model: "claude-opus-4-7",
        max_tokens: 16_000,
        system: prompt,
        tools: tools
      )

      Golem.LLM.call(messages,
        provider: :openrouter,
        model: "qwen/qwen-2.5-coder-32b-instruct"
      )

  Omitting `:provider` defaults to `:anthropic`.

  ## Per-role helpers

      Golem.LLM.call_as(:planner, messages, ...)   # uses :planner_provider + :planner_model
      Golem.LLM.call_as(:executor, messages, ...)  # uses :executor_provider + :executor_model
  """

  @providers %{
    anthropic: Golem.Claude,
    openrouter: Golem.OpenRouter
  }

  @doc """
  Call the configured provider directly with an explicit
  `provider:` opt.
  """
  @spec call(list(), keyword()) :: {:ok, Golem.Provider.response()} | {:error, term()}
  def call(messages, opts \\ []) do
    {provider, opts} = Keyword.pop(opts, :provider, :anthropic)

    case Map.fetch(@providers, provider) do
      {:ok, mod} -> mod.call(messages, opts)
      :error -> {:error, {:unknown_provider, provider}}
    end
  end

  @doc """
  Call using the provider + model configured for a role. Other opts
  (max_tokens, system, tools, thinking_budget, …) are forwarded.
  Returns `{:error, :no_model_for_role}` if the role isn't configured.
  """
  @spec call_as(:planner | :executor | :compaction, list(), keyword()) ::
          {:ok, Golem.Provider.response()} | {:error, term()}
  def call_as(role, messages, opts \\ []) when role in [:planner, :executor, :compaction] do
    provider = Application.get_env(:golem, :"#{role}_provider", :anthropic)
    model = opts[:model] || Application.get_env(:golem, :"#{role}_model")

    if is_nil(model) do
      {:error, :no_model_for_role}
    else
      opts
      |> Keyword.put(:provider, provider)
      |> Keyword.put(:model, model)
      |> then(&call(messages, &1))
    end
  end

  @doc "Module mapping for known providers, exposed for diagnostics."
  def providers, do: @providers
end
