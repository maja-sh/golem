defmodule Penbot.Web do
  @moduledoc """
  Web search (via Perplexity) and URL fetching.
  """

  require Logger

  @perplexity_url "https://api.perplexity.ai"

  @doc """
  Search the web using Perplexity's Sonar model.
  Returns {:ok, formatted_text} or {:error, reason}.
  """
  def search(query) do
    api_key =
      System.get_env("PERPLEXITY_API_KEY") ||
        raise "PERPLEXITY_API_KEY environment variable not set"

    body = %{
      model: "sonar",
      messages: [%{role: "user", content: query}]
    }

    case Req.post("#{@perplexity_url}/chat/completions",
           json: body,
           headers: [
             {"authorization", "Bearer #{api_key}"},
             {"content-type", "application/json"}
           ],
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: resp}} ->
        answer =
          resp
          |> get_in(["choices", Access.at(0), "message", "content"])
          |> Kernel.||("No answer returned")

        citations = get_in(resp, ["citations"]) || []

        citations_text =
          citations
          |> Enum.with_index(1)
          |> Enum.map_join("\n", fn {url, i} -> "  [#{i}] #{url}" end)

        result = """
        #{answer}

        Sources:
        #{citations_text}
        """

        {:ok, result}

      {:ok, %{status: status, body: resp}} ->
        Logger.error("Perplexity error #{status}: #{inspect(resp)}")
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetch a URL and return its text content.
  Strips HTML tags for a cleaner result.
  """
  def fetch(url) do
    case Req.get(url,
           receive_timeout: 30_000,
           redirect: true,
           max_redirects: 5,
           headers: [{"user-agent", "Penbot/0.1 (autonomous agent)"}]
         ) do
      {:ok, %{status: 200, body: body, headers: headers}} ->
        content_type =
          headers
          |> Enum.find_value(fn
            {"content-type", v} -> v
            _ -> nil
          end) || ""

        text =
          if String.contains?(content_type, "text/html") do
            strip_html(body)
          else
            to_string(body)
          end

        {:ok, text}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Basic HTML stripping — removes tags, decodes common entities, collapses whitespace
  defp strip_html(html) when is_binary(html) do
    html
    # Remove script and style blocks entirely
    |> String.replace(~r/<script[^>]*>.*?<\/script>/is, "")
    |> String.replace(~r/<style[^>]*>.*?<\/style>/is, "")
    # Replace block elements with newlines
    |> String.replace(~r/<\/(p|div|li|h[1-6]|tr|br\s*\/?)>/i, "\n")
    |> String.replace(~r/<br\s*\/?\s*>/i, "\n")
    # Strip remaining tags
    |> String.replace(~r/<[^>]+>/, "")
    # Decode common entities
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&nbsp;", " ")
    # Collapse whitespace
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp strip_html(other), do: to_string(other)
end
