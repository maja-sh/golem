defmodule Golem.Bitbucket do
  @moduledoc """
  Bitbucket REST API 2.0 client. Creates draft PRs and builds clone URLs.
  """

  require Logger

  @api_base "https://api.bitbucket.org/2.0"

  @doc """
  Create a draft pull request.
  Returns {:ok, pr_url} or {:error, reason}.
  """
  def create_draft_pr(workspace, repo_slug, params) do
    url = "#{@api_base}/repositories/#{workspace}/#{repo_slug}/pullrequests"

    body = %{
      title: params.title,
      source: %{branch: %{name: params.source_branch}},
      destination: %{branch: %{name: params.destination_branch}},
      description: params[:description] || "",
      draft: true
    }

    case Req.post(url, json: body, headers: auth_headers()) do
      {:ok, %{status: 201, body: resp}} ->
        pr_url = resp["links"]["html"]["href"]
        {:ok, pr_url}

      {:ok, %{status: status, body: resp}} ->
        {:error, "Bitbucket PR creation failed (#{status}): #{inspect(resp)}"}

      {:error, reason} ->
        {:error, "Bitbucket request failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Build an HTTPS clone URL with API token credentials.
  Uses the x-bitbucket-api-token-auth format required by Bitbucket API tokens.
  """
  def clone_url(workspace, repo_slug) do
    token = System.get_env("BITBUCKET_API_TOKEN") || raise "BITBUCKET_API_TOKEN not set"
    "https://x-bitbucket-api-token-auth:#{token}@bitbucket.org/#{workspace}/#{repo_slug}.git"
  end

  @doc """
  Fetch a single pull request's metadata. Returns a normalized map:

      %{
        id:                 integer(),
        title:              String.t(),
        description:        String.t(),
        state:              String.t(),  # "OPEN" / "MERGED" / "DECLINED" / "SUPERSEDED"
        source_branch:      String.t(),
        destination_branch: String.t(),
        url:                String.t(),
        workspace:          String.t(),
        repo:               String.t()
      }
  """
  def fetch_pull_request(workspace, repo_slug, pr_id) do
    url = "#{@api_base}/repositories/#{workspace}/#{repo_slug}/pullrequests/#{pr_id}"

    case Req.get(url, headers: auth_headers()) do
      {:ok, %{status: 200, body: resp}} ->
        {:ok,
         %{
           id: resp["id"],
           title: resp["title"] || "",
           description: resp["description"] || "",
           state: resp["state"] || "",
           source_branch: get_in(resp, ["source", "branch", "name"]) || "",
           destination_branch: get_in(resp, ["destination", "branch", "name"]) || "",
           url: get_in(resp, ["links", "html", "href"]) || "",
           workspace: workspace,
           repo: repo_slug
         }}

      {:ok, %{status: 404}} ->
        {:error, "PR #{workspace}/#{repo_slug}/#{pr_id} not found"}

      {:ok, %{status: status, body: resp}} ->
        {:error, "Bitbucket PR fetch failed (#{status}): #{inspect(resp)}"}

      {:error, reason} ->
        {:error, "Bitbucket request failed: #{inspect(reason)}"}
    end
  end

  @doc """
  List pull requests for a repo. Defaults to OPEN. Optional filters:

    * `:state` — "OPEN" | "MERGED" | "DECLINED" | "SUPERSEDED" (default "OPEN")
    * `:branch_prefix` — match `source.branch.name` starts with this string
    * `:limit` — soft cap on total returned (we paginate up to this)

  Returns the same normalized PR shape as `fetch_pull_request/3`.
  """
  def list_pull_requests(workspace, repo_slug, opts \\ []) do
    state = Keyword.get(opts, :state, "OPEN")
    branch_prefix = Keyword.get(opts, :branch_prefix)
    limit = Keyword.get(opts, :limit, 50)

    query =
      [{"state", state}, {"pagelen", "50"}] ++
        if branch_prefix,
          do: [{"q", ~s(source.branch.name ~ "#{branch_prefix}")}],
          else: []

    fetch_paginated(
      "#{@api_base}/repositories/#{workspace}/#{repo_slug}/pullrequests",
      query,
      limit,
      fn raw ->
        %{
          id: raw["id"],
          title: raw["title"] || "",
          description: raw["description"] || "",
          state: raw["state"] || "",
          source_branch: get_in(raw, ["source", "branch", "name"]) || "",
          destination_branch: get_in(raw, ["destination", "branch", "name"]) || "",
          url: get_in(raw, ["links", "html", "href"]) || "",
          workspace: workspace,
          repo: repo_slug
        }
      end
    )
  end

  @doc """
  List comments on a pull request. Returns a normalized list:

      %{
        id:        integer(),
        author:    String.t(),
        body:      String.t(),
        path:      String.t() | nil,   # for inline comments
        line:      integer() | nil,
        resolved:  boolean(),
        deleted:   boolean(),
        parent_id: integer() | nil,    # set if this comment is a reply
        created:   String.t()
      }
  """
  def list_pr_comments(workspace, repo_slug, pr_id) do
    url = "#{@api_base}/repositories/#{workspace}/#{repo_slug}/pullrequests/#{pr_id}/comments"

    fetch_paginated(url, [{"pagelen", "50"}], 200, fn c ->
      %{
        id: c["id"],
        author: get_in(c, ["user", "display_name"]) || "Unknown",
        body: get_in(c, ["content", "raw"]) || "",
        path: get_in(c, ["inline", "path"]),
        line: get_in(c, ["inline", "to"]) || get_in(c, ["inline", "from"]),
        resolved: c["resolved"] || false,
        deleted: c["deleted"] || false,
        parent_id: get_in(c, ["parent", "id"]),
        created: c["created_on"] || ""
      }
    end)
  end

  @doc """
  List tasks on a pull request. Bitbucket tasks are concrete action
  items separate from comments — typically attached to a comment via
  `comment.id`. Returns a normalized list:

      %{
        id:         integer(),
        body:       String.t(),
        state:      String.t(),       # "UNRESOLVED" | "RESOLVED"
        creator:    String.t(),
        comment_id: integer() | nil,  # parent comment if attached
        created:    String.t()
      }
  """
  def list_pr_tasks(workspace, repo_slug, pr_id) do
    url = "#{@api_base}/repositories/#{workspace}/#{repo_slug}/pullrequests/#{pr_id}/tasks"

    fetch_paginated(url, [{"pagelen", "50"}], 200, fn t ->
      %{
        id: t["id"],
        body: get_in(t, ["content", "raw"]) || "",
        state: t["state"] || "",
        creator: get_in(t, ["creator", "display_name"]) || "Unknown",
        comment_id: get_in(t, ["comment", "id"]),
        created: t["created_on"] || ""
      }
    end)
  end

  @doc """
  Add a comment to a PR. When `parent_id` is given, the comment is
  posted as a reply on that thread.
  """
  def add_pr_comment(workspace, repo_slug, pr_id, body_text, opts \\ []) do
    url = "#{@api_base}/repositories/#{workspace}/#{repo_slug}/pullrequests/#{pr_id}/comments"

    payload =
      %{content: %{raw: body_text}}
      |> maybe_add_parent(opts[:parent_id])

    case Req.post(url, json: payload, headers: auth_headers()) do
      {:ok, %{status: status}} when status in [200, 201] ->
        :ok

      {:ok, %{status: status, body: resp}} ->
        {:error, "Bitbucket comment failed (#{status}): #{inspect(resp)}"}

      {:error, reason} ->
        {:error, "Bitbucket request failed: #{inspect(reason)}"}
    end
  end

  defp maybe_add_parent(payload, nil), do: payload
  defp maybe_add_parent(payload, parent_id), do: Map.put(payload, :parent, %{id: parent_id})

  # Walk Bitbucket's `next` URL pagination, capped at `limit` items, mapping
  # each raw value through `fun` into the caller's normalized shape.
  defp fetch_paginated(url, query, limit, fun) do
    do_paginate(url, query, limit, fun, [])
  end

  defp do_paginate(_url, _query, limit, _fun, acc) when length(acc) >= limit do
    {:ok, Enum.take(Enum.reverse(acc), limit)}
  end

  defp do_paginate(url, query, limit, fun, acc) do
    case Req.get(url, params: query, headers: auth_headers()) do
      {:ok, %{status: 200, body: %{"values" => values} = resp}} ->
        new_acc = Enum.reduce(values, acc, fn raw, a -> [fun.(raw) | a] end)

        case resp["next"] do
          next when is_binary(next) and next != "" and length(new_acc) < limit ->
            # `next` is a fully qualified URL with its own query string
            do_paginate(next, [], limit, fun, new_acc)

          _ ->
            {:ok, Enum.reverse(new_acc)}
        end

      {:ok, %{status: status, body: resp}} ->
        {:error, "Bitbucket list failed (#{status}): #{inspect(resp)}"}

      {:error, reason} ->
        {:error, "Bitbucket request failed: #{inspect(reason)}"}
    end
  end

  defp auth_headers do
    email = System.get_env("JIRA_EMAIL") || raise "JIRA_EMAIL not set (shared with Bitbucket auth)"
    token = System.get_env("BITBUCKET_API_TOKEN") || raise "BITBUCKET_API_TOKEN not set"
    encoded = Base.encode64("#{email}:#{token}")

    [
      {"authorization", "Basic #{encoded}"},
      {"content-type", "application/json"}
    ]
  end
end
