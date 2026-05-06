defmodule Golem.Jira.Evaluator do
  @moduledoc """
  Pre-flight ticket evaluation. Uses Claude to assess whether a Jira ticket
  is suitable for autonomous work and which projects are relevant.
  """

  require Logger

  @doc """
  Evaluate a ticket for autonomous work.

  Image attachments fetched by `Golem.Jira.image_blocks/1` can be passed
  via `:image_blocks` so the evaluator can read screenshots that the
  ticket description references (e.g. "see the attached list").

  Returns:
  - `{:ok, %{decision: "accept", reason: String.t(), selected_projects: [String.t()]}}`
  - `{:ok, %{decision: "reject", reason: String.t(), selected_projects: []}}`
  - `{:error, reason}`
  """
  def evaluate(ticket, config, opts \\ []) do
    model = Application.get_env(:golem, :planner_model)
    image_blocks = Keyword.get(opts, :image_blocks, [])
    text = build_message(ticket, config.projects, image_blocks)
    content = [%{type: "text", text: text} | image_blocks]

    case Golem.Claude.call(
           [%{role: "user", content: content}],
           model: model,
           max_tokens: 1024,
           system: system_prompt(),
           tools: [evaluation_tool()]
         ) do
      {:ok, %{tool_use: [%{name: "evaluate_ticket", input: input} | _]} = response} ->
        decision = input["decision"]
        reason = input["reason"] || ""
        projects = input["selected_projects"] || []
        cost = Golem.Runner.usage_cost(Map.get(response, :usage, %{}), model)

        # Accept with zero projects is effectively a rejection
        result =
          if decision == "accept" and projects == [] do
            %{decision: "reject", reason: "Accepted but no projects selected — nothing to change.", selected_projects: []}
          else
            %{decision: decision, reason: reason, selected_projects: projects}
          end

        {:ok, Map.put(result, :cost, cost)}

      {:ok, %{text: text}} ->
        Logger.warning("Evaluator returned text instead of tool call: #{String.slice(text, 0, 200)}")
        {:error, :no_tool_call}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Prompts ---

  defp system_prompt do
    """
    You are evaluating a Jira ticket to decide whether an autonomous AI agent can implement it.

    ## Reject if:
    - The ticket is too vague — no clear deliverable, missing key details about what to build or change
    - The ticket requires extensive architectural decisions that need human judgment
    - The ticket involves infrastructure, deployments, database migrations with data backfill, or other ops work the agent can't do in a dev container
    - The ticket requires access to external systems, credentials, or APIs the agent doesn't have
    - The ticket is a meta-task (planning, discussion, decision-making) rather than implementation work

    ## Attachments
    Image attachments on the ticket (screenshots of UI bugs, error logs,
    mockups, lists of warnings) are embedded directly in the user
    message — read them as primary context, just like the description.
    Don't reject on the assumption that "the attached X" is unavailable
    without first checking the embedded images. Non-image attachments
    (PDFs, CSVs, etc.) are listed by filename but cannot be read by the
    agent; rejecting is appropriate if the ticket genuinely depends on
    their contents.

    ## Accept if:
    - The ticket describes a clear, scoped code change (feature, bug fix, refactor)
    - The deliverable is concrete enough to verify (new endpoint, UI change, test, etc.)
    - The work can be done by reading existing code and making changes

    ## Project selection:
    When accepting, select which projects from the available list are relevant. Choose only projects that will need code changes for this ticket. If you're unsure, include the project — the agent can skip it if no changes are needed.

    Use the `evaluate_ticket` tool to submit your evaluation.
    """
  end

  defp build_message(ticket, projects, image_blocks) do
    project_list =
      projects
      |> Enum.map(fn p ->
        desc = if p.description, do: " — #{p.description}", else: ""
        "- `#{p.repo}`#{desc}"
      end)
      |> Enum.join("\n")

    comments_section =
      case Map.get(ticket, :comments, []) do
        [] -> nil
        comments ->
          formatted = Enum.map_join(comments, "\n\n", fn c ->
            "**#{c.author}:** #{c.body}"
          end)
          "**Comments:**\n#{formatted}"
      end

    parts = [
      "## Ticket: #{ticket.key}",
      "**Summary:** #{ticket.summary}",
      "**Type:** #{ticket.issue_type} | **Priority:** #{ticket.priority}",
      if(ticket.description && ticket.description != "", do: "**Description:**\n#{ticket.description}"),
      if(ticket.acceptance_criteria, do: "**Acceptance Criteria:**\n#{ticket.acceptance_criteria}"),
      comments_section,
      attachments_section(ticket, image_blocks),
      "## Available Projects\n\n#{project_list}"
    ]

    parts
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp attachments_section(ticket, image_blocks) do
    attachments = Map.get(ticket, :attachments, [])
    if attachments == [] do
      nil
    else
      images = Golem.Jira.image_attachments(attachments)
      others = attachments -- images
      embedded_count = length(image_blocks)

      lines =
        Enum.map(images, fn a ->
          "- `#{a.filename}` (#{a.mime_type}) — image, embedded below"
        end) ++
          Enum.map(others, fn a ->
            "- `#{a.filename}` (#{a.mime_type}) — non-image, contents not available"
          end)

      header =
        if embedded_count > 0,
          do: "**Attachments** (#{embedded_count} image(s) embedded after this text):",
          else: "**Attachments:**"

      "#{header}\n#{Enum.join(lines, "\n")}"
    end
  end

  # --- Tool ---

  defp evaluation_tool do
    %{
      name: "evaluate_ticket",
      description: "Submit your evaluation of the Jira ticket.",
      input_schema: %{
        type: "object",
        properties: %{
          decision: %{
            type: "string",
            enum: ["accept", "reject"],
            description: "Whether this ticket is suitable for autonomous implementation."
          },
          reason: %{
            type: "string",
            description: "Brief explanation of the decision."
          },
          selected_projects: %{
            type: "array",
            items: %{type: "string"},
            description: "List of repo identifiers (e.g. 'hrdl/api') that need changes for this ticket. Empty if rejecting."
          }
        },
        required: ["decision", "reason", "selected_projects"]
      }
    }
  end
end
