defmodule CstopiaBackend.Lobbies.LobbyChatTest do
  use ExUnit.Case, async: true
  alias CstopiaBackend.Lobbies.LobbyChat

  # Define a test PubSub module that just logs calls for verification
  defmodule TestPubSub do
    def start_link do
      Agent.start_link(fn -> [] end, name: __MODULE__)
    end

    def broadcast!(topic, event, payload) do
      Agent.update(__MODULE__, fn broadcasts ->
        [{topic, event, payload} | broadcasts]
      end)
      :ok
    end

    def get_broadcasts do
      Agent.get(__MODULE__, fn broadcasts -> broadcasts end)
    end

    def reset do
      Agent.update(__MODULE__, fn _ -> [] end)
    end
  end

  setup do
    # Start the test PubSub
    {:ok, _} = TestPubSub.start_link()

    # Create a mock lobby state
    leader_id = "leader123"
    player_id = "player456"

    lobby_state = %{
      id: "lobby1",
      leader_id: leader_id,
      chat_host_only: false,
      chat_messages: [],
      players: [
        %{
          "id" => leader_id,
          "username" => "LeaderUser",
          "avatar" => "leader_avatar",
          "discord_id" => "leader_discord"
        },
        %{
          "id" => player_id,
          "username" => "PlayerUser",
          "avatar" => "player_avatar",
          "discord_id" => "player_discord"
        }
      ]
    }

    # Reset any previous test broadcasts
    TestPubSub.reset()

    {:ok, %{lobby: lobby_state, leader_id: leader_id, player_id: player_id, pubsub: TestPubSub}}
  end

  describe "send_message/3" do
    test "successfully sends a message from a player", %{lobby: lobby, player_id: player_id, pubsub: pubsub} do
      message_text = "Hello, world!"

      # Mock the broadcast functions for testing
      send_message_fn = fn(lobby_id, message, state) ->
        pubsub.broadcast!("lobby:#{lobby_id}", {:chat_message_sent, %{
          lobby: state,
          message: message,
          chat_messages: state.chat_messages
        }})
      end

      # Call the function with our own broadcast function
      result = apply_with_mock(
        &LobbyChat.send_message/3,
        [lobby, player_id, message_text],
        send_message_fn
      )

      # Verify the result
      assert {:ok, message, updated_state} = result
      assert message.content == message_text
      assert message.user_id == player_id
      assert length(updated_state.chat_messages) == 1
      assert hd(updated_state.chat_messages).id == message.id

      # Verify broadcast was called
      broadcasts = pubsub.get_broadcasts()
      assert length(broadcasts) == 1
      {topic, _event, _payload} = hd(broadcasts)
      assert topic == "lobby:#{lobby.id}"
    end

    test "prevents messages in host-only mode from non-hosts", %{lobby: lobby, player_id: player_id, pubsub: pubsub} do
      # Set host-only mode
      lobby = %{lobby | chat_host_only: true}

      # Call the function with empty mock (shouldn't be called)
      result = apply_with_mock(
        &LobbyChat.send_message/3,
        [lobby, player_id, "This shouldn't work"],
        fn(_, _, _) -> :ok end
      )

      # Verify it was rejected
      assert {:error, :host_only_mode, _} = result

      # No broadcasts should have happened
      assert pubsub.get_broadcasts() == []
    end

    test "allows leader to send messages in host-only mode", %{lobby: lobby, leader_id: leader_id, pubsub: pubsub} do
      # Set host-only mode
      lobby = %{lobby | chat_host_only: true}

      # Mock the broadcast function
      send_message_fn = fn(lobby_id, message, state) ->
        pubsub.broadcast!("lobby:#{lobby_id}", {:chat_message_sent, %{
          lobby: state,
          message: message,
          chat_messages: state.chat_messages
        }})
      end

      # Send a message as the leader
      result = apply_with_mock(
        &LobbyChat.send_message/3,
        [lobby, leader_id, "Leader message"],
        send_message_fn
      )

      # Verify it worked
      assert {:ok, message, updated_state} = result
      assert message.content == "Leader message"
      assert message.user_id == leader_id
      assert length(updated_state.chat_messages) == 1

      # Verify broadcast was called
      broadcasts = pubsub.get_broadcasts()
      assert length(broadcasts) == 1
    end
  end

  describe "delete_message/3" do
    test "leader can delete messages", %{lobby: lobby, leader_id: leader_id, pubsub: pubsub} do
      # Add a test message to delete
      message = %{id: "msg1", content: "Test message", user_id: "someuser"}
      lobby = %{lobby | chat_messages: [message]}

      # Mock the broadcast function
      delete_message_fn = fn(lobby_id, message_id, state) ->
        pubsub.broadcast!("lobby:#{lobby_id}", {:chat_message_deleted, %{
          lobby: state,
          message_id: message_id,
          chat_messages: state.chat_messages
        }})
      end

      # Delete the message as leader
      result = apply_with_mock(
        &LobbyChat.delete_message/3,
        [lobby, "msg1", leader_id],
        delete_message_fn
      )

      # Verify the message was deleted
      assert {:ok, updated_state} = result
      assert Enum.empty?(updated_state.chat_messages)

      # Verify broadcast was called
      broadcasts = pubsub.get_broadcasts()
      assert length(broadcasts) == 1
    end

    test "non-leaders cannot delete messages", %{lobby: lobby, player_id: player_id, pubsub: pubsub} do
      # Add a test message
      message = %{id: "msg1", content: "Test message", user_id: "someuser"}
      lobby = %{lobby | chat_messages: [message]}

      # Try to delete as a regular player (with mock that shouldn't be called)
      result = apply_with_mock(
        &LobbyChat.delete_message/3,
        [lobby, "msg1", player_id],
        fn(_, _, _) -> :ok end
      )

      # Verify it was rejected
      assert {:error, :not_authorized, _} = result

      # No broadcasts should have happened
      assert pubsub.get_broadcasts() == []
    end
  end

  describe "toggle_host_only_mode/2" do
    test "leader can toggle host-only mode", %{lobby: lobby, leader_id: leader_id, pubsub: pubsub} do
      # Initial state: host-only mode is off
      assert lobby.chat_host_only == false

      # Mock the broadcast function
      toggle_mode_fn = fn(lobby_id, state) ->
        pubsub.broadcast!("lobby:#{lobby_id}", {:chat_mode_changed, %{
          lobby: state,
          host_only: state.chat_host_only,
          chat_messages: state.chat_messages
        }})
      end

      # Toggle as leader
      result1 = apply_with_mock(
        &LobbyChat.toggle_host_only_mode/2,
        [lobby, leader_id],
        toggle_mode_fn
      )

      # Verify it was toggled on
      assert {:ok, host_only, updated_state} = result1
      assert host_only == true
      assert updated_state.chat_host_only == true

      # Toggle again
      result2 = apply_with_mock(
        &LobbyChat.toggle_host_only_mode/2,
        [updated_state, leader_id],
        toggle_mode_fn
      )

      # Verify it was toggled off
      assert {:ok, host_only2, updated_state2} = result2
      assert host_only2 == false
      assert updated_state2.chat_host_only == false

      # Verify broadcasts were called twice
      broadcasts = pubsub.get_broadcasts()
      assert length(broadcasts) == 2
    end

    test "non-leaders cannot toggle host-only mode", %{lobby: lobby, player_id: player_id, pubsub: pubsub} do
      # Try to toggle as a regular player (with mock that shouldn't be called)
      result = apply_with_mock(
        &LobbyChat.toggle_host_only_mode/2,
        [lobby, player_id],
        fn(_, _) -> :ok end
      )

      # Verify it was rejected
      assert {:error, :not_authorized, _} = result

      # State should be unchanged
      assert lobby.chat_host_only == false

      # No broadcasts should have happened
      assert pubsub.get_broadcasts() == []
    end
  end

  # Helper function to apply a function with mocked broadcast functions
  defp apply_with_mock(func, args, mock_broadcast) do
    # Store original function
    original_broadcast_message = &LobbyChat.broadcast_message/3
    original_broadcast_deletion = &LobbyChat.broadcast_deletion/3
    original_broadcast_mode_change = &LobbyChat.broadcast_chat_mode_change/2

    # Mock the function by redefining it
    :meck.new(LobbyChat, [:passthrough])
    :meck.expect(LobbyChat, :broadcast_message, mock_broadcast)
    :meck.expect(LobbyChat, :broadcast_deletion, mock_broadcast)
    :meck.expect(LobbyChat, :broadcast_chat_mode_change, mock_broadcast)

    # Apply the function with args
    result = apply(func, args)

    # Clean up the mock
    :meck.unload(LobbyChat)

    result
  end
end
