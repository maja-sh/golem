defmodule Golem.Jira do
  @moduledoc """
  Jira REST API client. Fetches tickets and posts comments.
  """

  require Logger

  @doc """
  Fetch a Jira ticket by key (e.g. "SA-1111").
  Returns {:ok, ticket} or {:error, reason}.
  """
  def fetch_ticket(key, base_url) do
    url = "#{api_base(base_url)}/rest/api/3/issue/#{key}"

    case Req.get(url, headers: auth_headers()) do
      {:ok, %{status: 200, body: body}} ->
        fields = body["fields"]

        {:ok, %{
          key: body["key"],
          summary: fields["summary"],
          description: adf_to_text(fields["description"]),
          acceptance_criteria: extract_acceptance_criteria(fields),
          issue_type: get_in(fields, ["issuetype", "name"]),
          priority: get_in(fields, ["priority", "name"])
        }}

      {:ok, %{status: 404}} ->
        {:error, "Ticket #{key} not found"}

      {:ok, %{status: status, body: body}} ->
        {:error, "Jira API returned #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Jira API request failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Add a comment to a Jira ticket.
  """
  def add_comment(key, body_text, base_url) do
    url = "#{api_base(base_url)}/rest/api/3/issue/#{key}/comment"

    adf_body = %{
      body: %{
        version: 1,
        type: "doc",
        content: [
          %{type: "paragraph", content: [%{type: "text", text: body_text}]}
        ]
      }
    }

    case Req.post(url, json: adf_body, headers: auth_headers()) do
      {:ok, %{status: status}} when status in [200, 201] ->
        :ok

      {:ok, %{status: status, body: resp}} ->
        {:error, "Jira comment failed (#{status}): #{inspect(resp)}"}

      {:error, reason} ->
        {:error, "Jira comment request failed: #{inspect(reason)}"}
    end
  end

  # --- ADF (Atlassian Document Format) to plain text ---

  @doc false
  def adf_to_text(nil), do: ""
  def adf_to_text(text) when is_binary(text), do: text

  def adf_to_text(%{"type" => "doc", "content" => content}) do
    content
    |> Enum.map(&adf_node_to_text/1)
    |> Enum.join("\n\n")
    |> String.trim()
  end

  def adf_to_text(_), do: ""

  defp adf_node_to_text(%{"type" => "paragraph", "content" => content}) do
    Enum.map_join(content, &adf_inline_to_text/1)
  end

  defp adf_node_to_text(%{"type" => "heading", "content" => content} = node) do
    level = node["attrs"]["level"] || 1
    prefix = String.duplicate("#", level)
    "#{prefix} #{Enum.map_join(content, &adf_inline_to_text/1)}"
  end

  defp adf_node_to_text(%{"type" => "bulletList", "content" => items}) do
    Enum.map_join(items, "\n", fn %{"content" => content} ->
      "- #{Enum.map_join(content, "\n  ", &adf_node_to_text/1)}"
    end)
  end

  defp adf_node_to_text(%{"type" => "orderedList", "content" => items}) do
    items
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {%{"content" => content}, i} ->
      "#{i}. #{Enum.map_join(content, "\n   ", &adf_node_to_text/1)}"
    end)
  end

  defp adf_node_to_text(%{"type" => "codeBlock", "content" => content} = node) do
    lang = get_in(node, ["attrs", "language"]) || ""
    code = Enum.map_join(content, &adf_inline_to_text/1)
    "```#{lang}\n#{code}\n```"
  end

  defp adf_node_to_text(%{"type" => "blockquote", "content" => content}) do
    content
    |> Enum.map(&adf_node_to_text/1)
    |> Enum.join("\n")
    |> String.split("\n")
    |> Enum.map_join("\n", &"> #{&1}")
  end

  defp adf_node_to_text(%{"type" => "listItem", "content" => content}) do
    Enum.map_join(content, "\n", &adf_node_to_text/1)
  end

  defp adf_node_to_text(%{"content" => content}) do
    Enum.map_join(content, &adf_inline_to_text/1)
  end

  defp adf_node_to_text(_), do: ""

  defp adf_inline_to_text(%{"type" => "text", "text" => text}), do: text
  defp adf_inline_to_text(%{"type" => "hardBreak"}), do: "\n"
  defp adf_inline_to_text(%{"type" => "mention", "attrs" => %{"text" => text}}), do: text
  defp adf_inline_to_text(%{"type" => "inlineCard", "attrs" => %{"url" => url}}), do: url
  defp adf_inline_to_text(_), do: ""

  # --- URL Resolution ---

  # Scoped API tokens require the cloud API URL format:
  # https://api.atlassian.com/ex/jira/{cloudId}/...
  # The cloud ID is fetched once and cached for the lifetime of the VM.
  defp api_base(site_url) do
    cloud_id = get_cloud_id(site_url)
    "https://api.atlassian.com/ex/jira/#{cloud_id}"
  end

  defp get_cloud_id(site_url) do
    case :persistent_term.get(:jira_cloud_id, nil) do
      nil ->
        cloud_id = fetch_cloud_id!(site_url)
        :persistent_term.put(:jira_cloud_id, cloud_id)
        cloud_id

      cached ->
        cached
    end
  end

  defp fetch_cloud_id!(site_url) do
    url = "#{String.trim_trailing(site_url, "/")}/_edge/tenant_info"

    case Req.get(url) do
      {:ok, %{status: 200, body: %{"cloudId" => id}}} ->
        Logger.info("Resolved Jira cloud ID: #{id}")
        id

      {:ok, %{status: status, body: body}} ->
        raise "Failed to resolve Jira cloud ID (#{status}): #{inspect(body)}"

      {:error, reason} ->
        raise "Failed to fetch Jira tenant info: #{inspect(reason)}"
    end
  end

  # --- Helpers ---

  defp extract_acceptance_criteria(fields) do
    # Common custom field names for acceptance criteria
    cond do
      ac = fields["customfield_10035"] -> adf_to_text(ac)
      ac = fields["customfield_10036"] -> adf_to_text(ac)
      true -> nil
    end
  end

  defp auth_headers do
    email = System.get_env("JIRA_EMAIL") || raise "JIRA_EMAIL not set"
    token = System.get_env("JIRA_API_TOKEN") || raise "JIRA_API_TOKEN not set"
    encoded = Base.encode64("#{email}:#{token}")

    [
      {"authorization", "Basic #{encoded}"},
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]
  end
end
