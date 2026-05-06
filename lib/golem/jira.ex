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
          priority: get_in(fields, ["priority", "name"]),
          labels: fields["labels"] || [],
          comments: extract_comments(fields),
          attachments: extract_attachments(fields)
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
  Transition a ticket to a target status by name.
  Discovers the transition ID dynamically from available transitions.
  """
  def transition_ticket(key, target_name, base_url) do
    url = "#{api_base(base_url)}/rest/api/3/issue/#{key}/transitions"

    case Req.get(url, headers: auth_headers()) do
      {:ok, %{status: 200, body: %{"transitions" => transitions}}} ->
        target = String.downcase(target_name)

        case Enum.find(transitions, fn t -> String.downcase(t["name"]) == target end) do
          %{"id" => id} ->
            case Req.post(url, json: %{transition: %{id: id}}, headers: auth_headers()) do
              {:ok, %{status: status}} when status in [200, 204] -> :ok
              {:ok, %{status: status, body: resp}} ->
                {:error, "Transition failed (#{status}): #{inspect(resp)}"}
              {:error, reason} ->
                {:error, "Transition request failed: #{inspect(reason)}"}
            end

          nil ->
            available = Enum.map_join(transitions, ", ", & &1["name"])
            {:error, "No transition '#{target_name}' available. Available: #{available}"}
        end

      {:ok, %{status: status, body: resp}} ->
        {:error, "Failed to fetch transitions (#{status}): #{inspect(resp)}"}

      {:error, reason} ->
        {:error, "Failed to fetch transitions: #{inspect(reason)}"}
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

  defp extract_comments(fields) do
    fields
    |> get_in(["comment", "comments"])
    |> List.wrap()
    |> Enum.map(fn comment ->
      author = get_in(comment, ["author", "displayName"]) || "Unknown"
      body = adf_to_text(comment["body"])
      created = comment["created"] || ""
      %{author: author, body: body, created: created}
    end)
    |> Enum.reject(fn c ->
      # Filter out Golem's own comments
      String.starts_with?(c.body, "Golem ")
    end)
  end

  defp extract_attachments(fields) do
    fields
    |> Map.get("attachment", [])
    |> List.wrap()
    |> Enum.map(fn a ->
      %{
        id: a["id"],
        filename: a["filename"],
        mime_type: a["mimeType"],
        size: a["size"] || 0,
        content_url: a["content"]
      }
    end)
  end

  @claude_image_types ~w(image/png image/jpeg image/gif image/webp)
  @max_image_bytes 5 * 1024 * 1024
  # Text attachments are decoded as UTF-8 and inlined verbatim — at
  # ~4 chars/token, 1MB ≈ 250K tokens, which already brushes against
  # most context windows. Anything bigger is "stupid large".
  @max_text_bytes 1024 * 1024
  @max_image_attachments 5
  @max_text_attachments 10

  @doc "Max image attachments embedded per ticket."
  def max_image_attachments, do: @max_image_attachments

  @doc "Max text attachments embedded per ticket."
  def max_text_attachments, do: @max_text_attachments

  @doc """
  Download an attachment's raw bytes from Jira (basic auth). The caller
  is responsible for size/type checks.
  """
  def fetch_attachment(%{content_url: url}) do
    case Req.get(url, headers: auth_headers(), redirect: true) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns only image attachments (by mime type), suitable for embedding
  as base64 blocks in a Claude message.
  """
  def image_attachments(attachments) do
    Enum.filter(attachments, &(&1.mime_type in @claude_image_types))
  end

  @doc """
  Returns attachments likely to be readable as text (by mime type or
  filename extension). Used for describing what will be embedded;
  the actual UTF-8 decode happens in `attachment_blocks/1`.
  """
  def text_attachments(attachments) do
    Enum.filter(attachments, &text_like?/1)
  end

  @doc """
  Download a ticket's attachments and return them as Claude content
  blocks, ready to splice into a `user` message. Images become base64
  image blocks; text-like files are decoded as UTF-8 and inlined as
  text blocks with a filename header. Binary or oversized attachments
  are logged and skipped.

  Capped at #{@max_image_attachments} images and #{@max_text_attachments}
  text files per ticket.
  """
  def attachment_blocks(%{attachments: attachments, key: key}) do
    images =
      attachments
      |> image_attachments()
      |> Enum.take(@max_image_attachments)

    texts =
      attachments
      |> text_attachments()
      |> Enum.take(@max_text_attachments)

    selected = images ++ texts

    if selected == [] do
      []
    else
      Logger.info(
        "Downloading #{length(images)} image + #{length(texts)} text attachment(s) for #{key}"
      )

      Enum.flat_map(selected, &fetch_block/1)
    end
  end

  def attachment_blocks(_), do: []

  defp fetch_block(att) do
    cond do
      att.mime_type in @claude_image_types -> fetch_image_block(att)
      text_like?(att) -> fetch_text_block(att)
      true -> []
    end
  end

  defp fetch_image_block(%{size: size} = att) when size > @max_image_bytes do
    Logger.warning("Skipping image #{att.filename}: too large (#{size} bytes)")
    []
  end

  defp fetch_image_block(att) do
    case fetch_attachment(att) do
      {:ok, bytes} ->
        [
          %{
            type: "image",
            source: %{
              type: "base64",
              media_type: att.mime_type,
              data: Base.encode64(bytes)
            }
          }
        ]

      {:error, reason} ->
        Logger.warning("Skipping image #{att.filename}: #{inspect(reason)}")
        []
    end
  end

  defp fetch_text_block(%{size: size} = att) when size > @max_text_bytes do
    Logger.warning("Skipping text attachment #{att.filename}: too large (#{size} bytes)")
    []
  end

  defp fetch_text_block(att) do
    with {:ok, bytes} <- fetch_attachment(att),
         true <- String.valid?(bytes) || {:error, :not_utf8} do
      [
        %{
          type: "text",
          text: """
          Attachment: `#{att.filename}` (#{att.mime_type})
          ```
          #{bytes}
          ```
          """
        }
      ]
    else
      {:error, reason} ->
        Logger.warning("Skipping text attachment #{att.filename}: #{inspect(reason)}")
        []
    end
  end

  # Treat an attachment as text-like if its mime type starts with
  # "text/", is in a known list of text-bearing application types, or
  # the filename has a recognised text-file extension. Jira often hands
  # back `application/octet-stream` for `.log` and `.txt` files, so the
  # extension fallback matters.
  @text_application_types ~w(
    application/json application/xml application/yaml application/x-yaml
    application/javascript application/typescript application/x-sh
    application/x-shellscript application/sql
  )
  @text_extensions ~w(
    .txt .log .csv .tsv .md .markdown .json .yaml .yml .xml .html .htm
    .css .js .ts .jsx .tsx .ex .exs .heex .py .rb .go .rs .java .kt .swift
    .c .h .cpp .hpp .cs .php .sh .bash .zsh .fish .sql .toml .ini .conf
    .env .gitignore .dockerignore .editorconfig
  )

  defp text_like?(%{mime_type: mime, filename: filename}) do
    cond do
      is_binary(mime) and String.starts_with?(mime, "text/") -> true
      mime in @text_application_types -> true
      true -> filename_text?(filename)
    end
  end

  defp text_like?(_), do: false

  defp filename_text?(nil), do: false

  defp filename_text?(filename) do
    ext = filename |> Path.extname() |> String.downcase()
    ext in @text_extensions
  end

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
