defmodule CstopiaBackend.Lobbies.LobbyChat do
  @moduledoc """
  Module for managing lobby chat functionality.
  Uses functional programming patterns instead of imperative if statements.
  """

  alias Phoenix.PubSub

  @pubsub_module CstopiaBackend.PubSub
  @max_messages 64

  @doc """
  Handles sending a chat message based on the user and lobby state.
  Returns {:ok, message, updated_state} or {:error, reason, state}
  """
  def send_message(state, user_id, message_text) do
    user = find_user(state.players, user_id)
    sanitized_message = sanitize_message(message_text)

    send_message_result(state, user, sanitized_message)
  end

  @doc """
  Marks a chat message as deleted if the requesting user is the lobby leader.
  Returns {:ok, updated_state} or {:error, reason, state}
  """
  def delete_message(state, message_id, user_id) do
    case user_id == state.leader_id do
      true -> mark_message_as_deleted(state, message_id)
      false -> {:error, :not_authorized, state}
    end
  end

  @doc """
  Toggles host-only chat mode if the requesting user is the lobby leader.
  Returns {:ok, host_only_status, updated_state} or {:error, reason, state}
  """
  def toggle_host_only_mode(state, user_id) do
    case user_id == state.leader_id do
      true ->
        updated_state = %{state | chat_host_only: !state.chat_host_only}
        broadcast_chat_mode_change(state.id, updated_state)
        {:ok, updated_state.chat_host_only, updated_state}
      false ->
        {:error, :not_authorized, state}
    end
  end

  @doc """
  Broadcasts a chat message to all members of the lobby.
  Made public to allow mocking in tests.
  """
  def broadcast_message(lobby_id, message, updated_state) do
    PubSub.broadcast!(
      @pubsub_module,
      "lobby:#{lobby_id}",
      {:chat_message_sent, %{
        lobby: updated_state,
        message: message,
        chat_messages: updated_state.chat_messages
      }}
    )
  end

  @doc """
  Broadcasts a message deletion to all members of the lobby.
  Made public to allow mocking in tests.
  """
  def broadcast_deletion(lobby_id, message_id, updated_state) do
    PubSub.broadcast!(
      @pubsub_module,
      "lobby:#{lobby_id}",
      {:chat_message_deleted, %{
        lobby: updated_state,
        message_id: message_id,
        chat_messages: updated_state.chat_messages
      }}
    )
  end

  @doc """
  Broadcasts chat mode changes to all members of the lobby.
  Made public to allow mocking in tests.
  """
  def broadcast_chat_mode_change(lobby_id, updated_state) do
    PubSub.broadcast!(
      @pubsub_module,
      "lobby:#{lobby_id}",
      {:chat_mode_changed, %{
        lobby: updated_state,
        host_only: updated_state.chat_host_only,
        chat_messages: updated_state.chat_messages
      }}
    )
  end

  @doc """
  Prunes messages to maintain only the latest @max_messages
  """
  def prune_messages(messages) do
    Enum.take(messages, @max_messages)
  end

  # Private functions

  defp find_user(players, user_id) do
    Enum.find(players, fn p -> p["id"] == user_id end)
  end

  defp sanitize_message(message) when is_binary(message) do
    message
    |> String.replace(~r/<[^>]*>/, "")  # Remove HTML tags
    |> String.replace(~r/[^\p{L}\p{N}\p{P}\p{Z}\p{S}]/u, "")  # Allow letters, numbers, punctuation, spaces, and symbols
    |> String.trim()
  end
  defp sanitize_message(_), do: ""

  defp send_message_result(state, nil, _message) do
    {:error, :not_in_lobby, state}
  end

  defp send_message_result(state, _user, "") do
    {:error, :invalid_message, state}
  end

  defp send_message_result(%{chat_host_only: true} = state, user, message) do
    if user["id"] == state.leader_id do
      create_and_broadcast_message(state, user, message)
    else
      {:error, :host_only_mode, state}
    end
  end

  defp send_message_result(state, user, content) do
    create_and_broadcast_message(state, user, content)
  end

  defp create_and_broadcast_message(state, user, content) do
    message = %{
      id: generate_message_id(),
      user_id: user["id"],
      username: user["username"],
      avatar: user["avatar"],
      discord_id: user["discord_id"],
      content: content,
      timestamp: DateTime.utc_now(),
      deleted: false
    }

    updated_messages = [message | state.chat_messages] |> prune_messages()
    updated_state = %{state | chat_messages: updated_messages}

    broadcast_message(state.id, message, updated_state)

    {:ok, message, updated_state}
  end

  defp mark_message_as_deleted(state, message_id) do
    case find_message_index(state.chat_messages, message_id) do
      {:ok, index} ->
        # Instead of removing the message, mark it as deleted
        message = Enum.at(state.chat_messages, index)
        deleted_message = %{message | deleted: true, content: "Message deleted"}

        updated_messages =
          state.chat_messages
          |> List.replace_at(index, deleted_message)
          |> prune_messages()

        updated_state = %{state | chat_messages: updated_messages}

        broadcast_deletion(state.id, message_id, updated_state)

        {:ok, updated_state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp find_message_index(messages, message_id) do
    case Enum.find_index(messages, fn m -> m.id == message_id end) do
      nil -> {:error, :message_not_found}
      index -> {:ok, index}
    end
  end

  defp generate_message_id do
    System.unique_integer([:positive]) |> to_string()
  end
end
