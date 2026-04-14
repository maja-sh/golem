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
  Uses the x-token-auth format required by Bitbucket API tokens.
  """
  def clone_url(workspace, repo_slug) do
    token = System.get_env("BITBUCKET_API_TOKEN") || raise "BITBUCKET_API_TOKEN not set"
    "https://x-token-auth:#{token}@bitbucket.org/#{workspace}/#{repo_slug}.git"
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
