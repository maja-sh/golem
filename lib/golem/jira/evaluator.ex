defmodule Golem.Jira.Evaluator do
  @moduledoc """
  Pre-flight ticket evaluation. Uses Claude to assess whether a Jira ticket
  is suitable for autonomous work and which projects are relevant.
  """

  require Logger

  @doc """
  Evaluate a ticket for autonomous work.

  Attachment content blocks fetched by `Golem.Jira.attachment_blocks/1`
  can be passed via `:attachment_blocks` so the evaluator can read
  screenshots and text files that the ticket description references
  (e.g. "see the attached list").

  Returns:
  - `{:ok, %{decision: "accept", reason: String.t(), selected_projects: [String.t()]}}`
  - `{:ok, %{decision: "reject", reason: String.t(), selected_projects: []}}`
  - `{:error, reason}`
  """
  def evaluate(ticket, config, opts \\ []) do
    model = Application.get_env(:golem, :planner_model)
    attachment_blocks = Keyword.get(opts, :attachment_blocks, [])
    nudge = Keyword.get(opts, :nudge)
    text = build_message(ticket, config.projects, attachment_blocks, nudge)
    content = [%{type: "text", text: text} | attachment_blocks]

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
    Attachments on the ticket are embedded directly in the user message:
    images (screenshots of UI bugs, error states, mockups) appear as
    image blocks; text-like files (logs, CSVs, JSON, plain text) are
    inlined verbatim under an `Attachment: <filename>` header. Read
    them as primary context, just like the description. Don't reject on
    the assumption that "the attached X" is unavailable without first
    checking the embedded blocks. Binary, oversized, or unsupported
    attachments (PDFs, spreadsheets, archives) are listed by filename
    only — rejecting is appropriate if the ticket genuinely depends on
    one of those.

    ## Accept if:
    - The ticket describes a clear, scoped code change (feature, bug fix, refactor)
    - The deliverable is concrete enough to verify (new endpoint, UI change, test, etc.)
    - The work can be done by reading existing code and making changes

    ## Project selection:
    When accepting, select which projects from the available list are relevant. Choose only projects that will need code changes for this ticket. If you're unsure, include the project — the agent can skip it if no changes are needed.

    Use the `evaluate_ticket` tool to submit your evaluation.
    """
  end

  defp build_message(ticket, projects, attachment_blocks, nudge) do
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

    nudge_section =
      if nudge do
        "**Operator note:** #{nudge}\n\nThe operator who started this run provided the note above. If it resolves an ambiguity in the ticket, treat the ambiguity as resolved when deciding whether to accept."
      end

    parts = [
      "## Ticket: #{ticket.key}",
      "**Summary:** #{ticket.summary}",
      "**Type:** #{ticket.issue_type} | **Priority:** #{ticket.priority}",
      if(ticket.description && ticket.description != "", do: "**Description:**\n#{ticket.description}"),
      if(ticket.acceptance_criteria, do: "**Acceptance Criteria:**\n#{ticket.acceptance_criteria}"),
      nudge_section,
      comments_section,
      attachments_section(ticket, attachment_blocks),
      "## Available Projects\n\n#{project_list}"
    ]

    parts
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp attachments_section(ticket, attachment_blocks) do
    attachments = Map.get(ticket, :attachments, [])
    if attachments == [] do
      nil
    else
      images = Golem.Jira.image_attachments(attachments)
      texts = Golem.Jira.text_attachments(attachments) -- images
      others = attachments -- images -- texts
      embedded_count = length(attachment_blocks)

      lines =
        Enum.map(images, fn a ->
          "- `#{a.filename}` (#{a.mime_type}) — image, embedded below"
        end) ++
          Enum.map(texts, fn a ->
            "- `#{a.filename}` (#{a.mime_type}) — text, embedded below"
          end) ++
          Enum.map(others, fn a ->
            "- `#{a.filename}` (#{a.mime_type}) — binary/unsupported, contents not available"
          end)

      header =
        if embedded_count > 0,
          do: "**Attachments** (#{embedded_count} embedded after this text):",
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
