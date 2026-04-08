defmodule Penbot.Discord do
  @moduledoc """
  Minimal Discord integration via Nostrum.
  Sends messages to a configured channel and waits for replies.
  Used by the ask_user tool to pause and get human input.
  """

  use Nostrum.Consumer
  require Logger

  @waiter_key :penbot_discord_waiter

  def init_waiter do
    :persistent_term.put(@waiter_key, nil)
  end

  @doc """
  Send a message to the configured channel.
  """
  def send_message(content) do
    channel_id = channel_id!()
    Nostrum.Api.Message.create(channel_id, content: content)
  end

  @doc """
  Send a question and wait for a reply. Blocks the caller.
  Returns {:ok, reply_text} or {:error, :not_connected}.
  """
  def ask(question, run_id) do
    channel_id = channel_id!()

    # Format the question with run context
    formatted = "🔧 **Forge** [run `#{run_id}`]\n\n#{question}\n\n_Reply in this channel to continue the run._"

    case Nostrum.Api.Message.create(channel_id, content: formatted) do
      {:ok, _msg} ->
        Logger.info("Discord: asked question, waiting for reply...")
        # Register this process as waiting for a reply
        :persistent_term.put(@waiter_key, {self(), run_id, channel_id})

        # Block until we receive a reply
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
      # Check if someone is waiting for a reply in this channel
      case :persistent_term.get(@waiter_key, nil) do
        {pid, _run_id, channel_id} when msg.channel_id == channel_id ->
          # Deliver the reply to the waiting process
          send(pid, {:discord_reply, msg.content})

        _ ->
          :noop
      end
    end
  end

  def handle_event(_event), do: :noop

  defp channel_id! do
    (System.get_env("DISCORD_CHANNEL_ID") || raise("DISCORD_CHANNEL_ID not set"))
    |> String.to_integer()
  end
end
