defmodule Golem.Output do
  @moduledoc """
  Behaviour for output backends. The active backend is selected via
  `Application.get_env(:golem, :output_backend, Golem.TUI)` — `Golem.TUI`
  is the only implementation today.
  """

  @callback init_display(run_id :: String.t(), goal :: String.t()) :: :ok
  @callback stop_display() :: :ok
  @callback planning(label :: String.t()) :: :ok
  @callback plan_created(plan :: String.t()) :: :ok
  @callback step_header(step :: integer(), max_steps :: integer(), cost :: String.t()) :: :ok
  @callback agent_text(text :: String.t() | nil) :: :ok
  @callback tool_call(name :: String.t(), detail :: String.t()) :: :ok
  @callback tool_result(name :: String.t(), detail :: String.t(), result :: String.t(), elapsed :: integer(), tokens :: any()) :: :ok
  @callback tool_error(name :: String.t(), detail :: String.t(), error :: String.t()) :: :ok
  @callback show_diff(path :: String.t(), old :: String.t(), new :: String.t()) :: :ok
  @callback set_progress(items :: list()) :: :ok
  @callback show_phase_costs(costs :: list()) :: :ok
  @callback sub_agent_status(goal :: String.t(), tool :: String.t(), detail :: String.t(), step :: integer(), max_steps :: integer()) :: :ok
  @callback tool_batch_result(results :: list(), elapsed :: integer()) :: :ok
  @callback update_tokens(count :: integer()) :: :ok
  @callback update_cost(cost :: String.t()) :: :ok
  @callback run_complete(success :: boolean(), summary :: String.t()) :: :ok
  @callback run_paused(run_id :: String.t()) :: :ok
  @callback run_error(reason :: any()) :: :ok
  @callback pr_opened(repo :: String.t(), url :: String.t()) :: :ok
  @callback pr_skipped(repo :: String.t(), reason :: String.t()) :: :ok

  @doc """
  Final closing block listing every PR created during the run. Called
  by the Jira integration after `push_all` completes so the operator
  doesn't have to scroll back through post-PR Jira logging to find
  the URLs to click. `prs` is a list of `{repo, url}` tuples; an empty
  list is a no-op (handler should print nothing).
  """
  @callback pr_summary(prs :: [{String.t(), String.t()}]) :: :ok

  @doc """
  Announce a batch of tool calls that are about to run in parallel. Each
  item is `%{id: String.t(), name: String.t(), detail: String.t()}`. The
  TUI should render them as pending entries so the user sees what the
  agent is doing before results come back.
  """
  @callback tool_batch_start(items :: [map()]) :: :ok

  @doc """
  Report completion of a single item from a previously-announced batch.
  Outcomes: `{:ok, elapsed_ms}` or `{:error, elapsed_ms}`.
  """
  @callback tool_batch_item_done(
              id :: String.t(),
              outcome :: {:ok, integer()} | {:error, integer()}
            ) :: :ok

  @doc """
  Signal that a Claude API call is waiting to retry after a transient
  failure (overload, transport error). The TUI uses the `started_at`
  plus `delay_ms` to tick down a visible countdown under the spinner
  so the user knows the agent is alive but throttled, not hung.
  """
  @callback api_retry(
              attempt :: integer(),
              max :: integer(),
              delay_ms :: integer(),
              reason :: String.t()
            ) :: :ok

  @doc "Clear any pending retry indicator — the call succeeded or gave up."
  @callback api_retry_cleared() :: :ok

  @doc """
  Synchronously prompt the operator with a yes/no question. Used at
  step caps so a long-running run can ask whether to keep spending
  money. Implementations should pause any spinner/status redraws while
  reading input and block until the user replies — there's no
  timeout, on the assumption that the operator may be AFK and a
  default-abort would be safer than a default-continue but neither is
  what they actually want. Anything other than `"y"` / `"yes"` returns
  `:abort`.
  """
  @callback confirm_continue(question :: String.t(), opts :: keyword()) :: :continue | :abort

  @doc """
  Print an entire sub-agent's activity in one synchronized block:
  header, every buffered tool line, and a success/fail footer. Used
  for parallel sub-agents where streaming would interleave several
  agents' tool calls under whichever header was printed last.
  `entries` is a list of `{tool, detail, step}` tuples in the order
  they ran.
  """
  @callback sub_agent_block(
              label :: String.t(),
              entries :: [{tool :: String.t(), detail :: String.t(), step :: integer()}],
              success :: boolean(),
              steps :: integer()
            ) :: :ok

  @doc """
  Live heartbeat for a buffered sub-agent: update the spinner's action
  line to show the latest tool call, but don't print to scrollback. Lets
  the operator see that a long-running sub-agent is still alive while
  its full output stays buffered until completion. With multiple
  parallel sub-agents the action line just shows whichever fired most
  recently — that's enough as an "is it alive" indicator.
  """
  @callback sub_agent_heartbeat(label :: String.t(), tool :: String.t(), detail :: String.t()) :: :ok

  @doc """
  Returns the currently active output backend module.
  """
  def current do
    Application.get_env(:golem, :output_backend, Golem.TUI)
  end
end
