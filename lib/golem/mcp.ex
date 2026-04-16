defmodule Golem.MCP do
  @moduledoc """
  MCP (Model Context Protocol) client for stdio servers.

  Manages MCP server subprocesses, discovers their tools at startup,
  and routes tool calls through JSON-RPC over stdin/stdout.

  Config in `.golem/mcp.yml`:

      servers:
        - name: elastic
          command: npx
          args: ["-y", "@elastic/mcp-server"]
          env:
            ELASTICSEARCH_URL: "https://..."

  Tools are namespaced as `mcp_{server}_{tool}` to avoid collisions.
  """

  use GenServer
  require Logger

  @config_path ".golem/mcp.yml"
  @call_timeout 30_000

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns all MCP tools in Claude API format."
  def tools do
    GenServer.call(__MODULE__, :tools, 10_000)
  catch
    :exit, _ -> []
  end

  @doc "Call an MCP tool. Returns {:ok, result_text} or {:error, reason}."
  def call_tool(namespaced_name, arguments) do
    GenServer.call(__MODULE__, {:call_tool, namespaced_name, arguments}, @call_timeout)
  catch
    :exit, _ -> {:error, :mcp_timeout}
  end

  # --- GenServer ---

  @impl true
  def init(_opts) do
    servers = load_config()

    if servers == [] do
      {:ok, %{servers: %{}, tools: []}}
    else
      {connected, tools} = connect_servers(servers)
      {:ok, %{servers: connected, tools: tools}}
    end
  end

  @impl true
  def handle_call(:tools, _from, state) do
    {:reply, state.tools, state}
  end

  def handle_call({:call_tool, namespaced_name, arguments}, _from, state) do
    case parse_tool_name(namespaced_name) do
      {:ok, server_name, tool_name} ->
        case Map.get(state.servers, server_name) do
          nil ->
            {:reply, {:error, "MCP server '#{server_name}' not connected"}, state}

          server ->
            result = rpc_call(server.port, "tools/call", %{name: tool_name, arguments: arguments}, server)
            text = format_result(result)
            {:reply, {:ok, text}, state}
        end

      :error ->
        {:reply, {:error, "Invalid MCP tool name: #{namespaced_name}"}, state}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, state) do
    # Handle async data from MCP server ports
    state = buffer_data(state, port, data)
    {:noreply, state}
  end

  def handle_info({_port, {:exit_status, code}}, state) do
    Logger.warning("[mcp] Server process exited with code #{code}")
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Close all server ports
    for {_name, server} <- state.servers do
      if Port.info(server.port), do: Port.close(server.port)
    end
  end

  # --- Config ---

  defp load_config do
    case YamlElixir.read_from_file(@config_path) do
      {:ok, %{"servers" => servers}} when is_list(servers) ->
        Enum.map(servers, fn s ->
          %{
            name: s["name"],
            command: s["command"],
            args: s["args"] || [],
            env: s["env"] || %{}
          }
        end)

      _ ->
        []
    end
  end

  # --- Server Connection ---

  defp connect_servers(servers) do
    results =
      Enum.map(servers, fn config ->
        Logger.info("[mcp] Connecting to #{config.name} (#{config.command})...")

        case start_server(config) do
          {:ok, server} ->
            case discover_tools(server, config.name) do
              {:ok, tools} ->
                Logger.info("[mcp] #{config.name}: #{length(tools)} tools discovered")
                {:ok, config.name, server, tools}

              {:error, reason} ->
                Logger.error("[mcp] #{config.name}: tool discovery failed: #{inspect(reason)}")
                if Port.info(server.port), do: Port.close(server.port)
                :error
            end

          {:error, reason} ->
            Logger.error("[mcp] #{config.name}: failed to start: #{inspect(reason)}")
            :error
        end
      end)

    connected =
      results
      |> Enum.filter(&match?({:ok, _, _, _}, &1))
      |> Map.new(fn {:ok, name, server, _tools} -> {name, server} end)

    tools =
      results
      |> Enum.filter(&match?({:ok, _, _, _}, &1))
      |> Enum.flat_map(fn {:ok, _name, _server, tools} -> tools end)

    {connected, tools}
  end

  defp start_server(config) do
    executable = System.find_executable(config.command)

    if executable do
      env =
        config.env
        |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(to_string(v))} end)

      port =
        Port.open({:spawn_executable, executable}, [
          {:args, config.args},
          {:env, env},
          :binary,
          :use_stdio,
          :exit_status,
          {:line, 1_048_576}
        ])

      server = %{port: port, id_counter: 0, pending: %{}, buffer: ""}

      # Send initialize
      case rpc_call(port, "initialize", %{
        protocolVersion: "2024-11-05",
        capabilities: %{},
        clientInfo: %{name: "golem", version: "0.1.0"}
      }, server) do
        {:ok, _result} ->
          # Send initialized notification (no response expected)
          send_notification(port, "notifications/initialized", %{})
          {:ok, %{server | id_counter: 2}}

        {:error, reason} ->
          Port.close(port)
          {:error, reason}
      end
    else
      {:error, "Command not found: #{config.command}"}
    end
  end

  defp discover_tools(server, server_name) do
    case rpc_call(server.port, "tools/list", %{}, server) do
      {:ok, %{"tools" => tools}} ->
        claude_tools =
          Enum.map(tools, fn tool ->
            %{
              name: "mcp_#{server_name}_#{tool["name"]}",
              description: "[#{server_name}] #{tool["description"] || tool["name"]}",
              input_schema: convert_schema(tool["inputSchema"] || %{type: "object", properties: %{}})
            }
          end)

        {:ok, claude_tools}

      {:ok, other} ->
        Logger.warning("[mcp] Unexpected tools/list response: #{inspect(other)}")
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- JSON-RPC ---

  defp rpc_call(port, method, params, _server) do
    id = :erlang.unique_integer([:positive])

    request = %{
      jsonrpc: "2.0",
      id: id,
      method: method,
      params: params
    }

    json = Jason.encode!(request)
    Port.command(port, json <> "\n")

    # Synchronous wait for response with matching id
    receive_response(port, id, @call_timeout)
  end

  defp send_notification(port, method, params) do
    notification = %{
      jsonrpc: "2.0",
      method: method,
      params: params
    }

    Port.command(port, Jason.encode!(notification) <> "\n")
  end

  defp receive_response(port, expected_id, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    receive_loop(port, expected_id, deadline, "")
  end

  defp receive_loop(port, expected_id, deadline, buffer) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining <= 0 do
      {:error, :timeout}
    else
      receive do
        {^port, {:data, {:eol, line}}} ->
          data = buffer <> line

          case Jason.decode(data) do
            {:ok, %{"id" => ^expected_id, "result" => result}} ->
              {:ok, result}

            {:ok, %{"id" => ^expected_id, "error" => error}} ->
              {:error, error}

            {:ok, %{"method" => _}} ->
              # Server notification — ignore, keep waiting
              receive_loop(port, expected_id, deadline, "")

            {:ok, _other} ->
              # Response for different id — ignore, keep waiting
              receive_loop(port, expected_id, deadline, "")

            {:error, _} ->
              # Partial JSON, accumulate buffer
              receive_loop(port, expected_id, deadline, data)
          end

        {^port, {:data, {:noeol, chunk}}} ->
          receive_loop(port, expected_id, deadline, buffer <> chunk)

        {^port, {:exit_status, code}} ->
          {:error, "MCP server exited with code #{code}"}
      after
        remaining -> {:error, :timeout}
      end
    end
  end

  # --- Helpers ---

  defp parse_tool_name("mcp_" <> rest) do
    case String.split(rest, "_", parts: 2) do
      [server, tool] -> {:ok, server, tool}
      _ -> :error
    end
  end

  defp parse_tool_name(_), do: :error

  defp convert_schema(schema) when is_map(schema) do
    # MCP uses "inputSchema", Claude uses "input_schema" — but the schema
    # content itself is standard JSON Schema, so just pass it through.
    schema
  end

  defp format_result({:ok, %{"content" => content}}) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => text} -> text
      %{"type" => "image"} -> "[image]"
      %{"type" => "resource", "resource" => %{"text" => text}} -> text
      other -> inspect(other)
    end)
    |> Enum.join("\n")
  end

  defp format_result({:ok, result}) when is_map(result) do
    Jason.encode!(result, pretty: true)
  end

  defp format_result({:ok, result}), do: to_string(result)

  defp format_result({:error, %{"message" => msg}}), do: "[MCP error] #{msg}"
  defp format_result({:error, reason}), do: "[MCP error] #{inspect(reason)}"

  defp buffer_data(state, _port, _data), do: state
end
