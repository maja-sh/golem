defmodule Golem.Discord do
  @moduledoc """
  Minimal Discord integration via Nostrum.
  Sends messages to a configured channel and waits for replies.
  Used by the ask_user tool to pause and get human input.
  """

  use Nostrum.Consumer
  require Logger

  @waiter_key :golem_discord_waiter

  def init_waiter do
    :persistent_term.put(@waiter_key, nil)
  end

  @doc """
  Send a message to the configured channel.
  """
  def send_message(content) do
    channel_id = channel_id!()
    send_message_to(channel_id, content)
  end

  @doc """
  Send a message to a specific channel, splitting if over 2000 chars.
  """
  def send_message_to(channel_id, content) do
    chunks = chunk_text(content, 1900)
    Enum.each(chunks, fn chunk ->
      Nostrum.Api.Message.create(channel_id, content: chunk)
    end)
  end

  @doc """
  Send a question and wait for a reply. Blocks the caller.
  Returns {:ok, reply_text} or {:error, :not_connected}.
  """
  def ask(question, run_id) do
    channel_id = channel_id!()

    # Wait for bot to be connected (up to 10 seconds)
    if not wait_for_ready(10) do
      Logger.error("Discord: bot not connected after 10s")
      {:error, :not_connected}
    else
      header = "🔧 **Forge** [run `#{run_id}`]"
      footer = "\n\n_Reply to continue the run._"
      max_question = 2000 - String.length(header) - String.length(footer) - 10

      # Split into multiple messages if needed
      messages =
        if String.length(question) > max_question do
          chunks = chunk_text(question, 1900)
          first = [header <> "\n\n" <> hd(chunks)]
          middle = tl(chunks) |> Enum.slice(0..-2//1)
          last_chunk = List.last(tl(chunks)) || ""
          first ++ middle ++ [last_chunk <> footer]
        else
          [header <> "\n\n" <> question <> footer]
        end

      # Send all message chunks
      results = Enum.map(messages, fn msg ->
        Nostrum.Api.Message.create(channel_id, content: msg)
      end)

      case List.last(results) do
        {:ok, _msg} ->
          Logger.info("Discord: asked question, waiting for reply...")
          :persistent_term.put(@waiter_key, {self(), run_id, channel_id})

          receive do
            {:discord_reply, text} ->
              :persistent_term.put(@waiter_key, nil)
              Logger.info("Discord: got reply: #{String.slice(text, 0, 200)}")
              {:ok, text}
          end

        {:error, reason} ->
          Logger.error("Discord: failed to send message: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp wait_for_ready(0), do: false
  defp wait_for_ready(seconds) do
    case Nostrum.Cache.Me.get() do
      nil ->
        Process.sleep(1_000)
        wait_for_ready(seconds - 1)
      _me ->
        true
    end
  end

  @doc """
  Send a status update (non-blocking, no reply expected).
  """
  def notify(message, run_id) do
    formatted = "🔧 **Forge** [run `#{run_id}`]\n#{message}"
    send_message(formatted)
  end

  # --- Nostrum Event Handlers ---

  def handle_event({:MESSAGE_CREATE, msg, _ws_state}) do
    me = Nostrum.Cache.Me.get()

    # Ignore our own messages
    if me && msg.author.id == me.id do
      :noop
    else
      channel_id = channel_id!()
      if msg.channel_id == channel_id do
        waiter = :persistent_term.get(@waiter_key, nil)

        case Golem.Discord.Commander.parse(msg.content) do
          # status and stop always work, even while waiting for ask_user
          {:command, cmd, args} when cmd in [:status, :stop] ->
            response = Golem.Discord.Commander.execute(cmd, args)
            send_message_to(channel_id, response)

          # Other commands only work when NOT waiting for a reply
          {:command, cmd, args} when is_nil(waiter) ->
            response = Golem.Discord.Commander.execute(cmd, args)
            send_message_to(channel_id, response)

          # Not a command, or command while waiting — treat as reply
          _ ->
            case waiter do
              {pid, _run_id, ^channel_id} ->
                send(pid, {:discord_reply, msg.content})
              _ ->
                :noop
            end
        end
      end
    end
  end

  def handle_event(_event), do: :noop

  defp channel_id! do
    (System.get_env("DISCORD_CHANNEL_ID") || raise("DISCORD_CHANNEL_ID not set"))
    |> String.to_integer()
  end

  defp chunk_text(text, max_len) do
    # Split on newlines, accumulate chunks up to max_len
    text
    |> String.split("\n")
    |> Enum.reduce([""], fn line, [current | rest] ->
      if String.length(current) + String.length(line) + 1 > max_len do
        [line, current | rest]
      else
        sep = if current == "", do: "", else: "\n"
        [current <> sep <> line | rest]
      end
    end)
    |> Enum.reverse()
  end
end
