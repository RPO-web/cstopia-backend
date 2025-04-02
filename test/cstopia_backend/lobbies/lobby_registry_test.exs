defmodule CstopiaBackend.Lobbies.LobbyRegistryTest do
  use CstopiaBackend.DataCase
  alias CstopiaBackend.Lobbies.LobbyRegistry
  alias CstopiaBackend.Lobbies.LobbyManager
  alias Phoenix.PubSub

  setup do
    # Start the Registry process in test mode
    start_supervised!(LobbyRegistry)

    # Setup a test lobby
    user_id = "test-user-123"
    second_user_id = "test-user-456"

    lobby_params = %{
      "title" => "Test Lobby",
      "region" => "EU",
      "rank_required" => "Silver",
      "lobby_type" => "Competitive",
      "team_size" => "5",
      "description" => "Test lobby for user mapping",
      "creator" => %{
        "id" => user_id,
        "username" => "TestUser",
        "avatar" => "avatar.jpg",
        "discord_id" => "test_discord"
      }
    }

    {:ok, lobby} = LobbyManager.create_lobby(lobby_params)

    # Give a brief moment for the registry to process the updates
    Process.sleep(50)

    %{
      user_id: user_id,
      second_user_id: second_user_id,
      lobby: lobby,
      lobby_id: lobby.id
    }
  end

  describe "user-to-lobby mapping" do
    test "finds lobbies for a user who created a lobby", %{user_id: user_id, lobby_id: lobby_id} do
      # Get lobbies for the creator
      lobbies = LobbyRegistry.get_user_lobbies(user_id)

      assert length(lobbies) == 1
      assert hd(lobbies).id == lobby_id
    end

    test "handles users with no lobbies", %{second_user_id: second_user_id} do
      # Get lobbies for a user who isn't in any
      lobbies = LobbyRegistry.get_user_lobbies(second_user_id)

      assert lobbies == []
    end

    test "updates mappings when a user joins a lobby", %{second_user_id: second_user_id, lobby_id: lobby_id} do
      # Initially, user should have no lobbies
      assert LobbyRegistry.get_user_lobbies(second_user_id) == []

      # Join the lobby
      player = %{
        "id" => second_user_id,
        "username" => "SecondUser",
        "avatar" => "avatar2.jpg",
        "discord_id" => "test_discord2"
      }

      {:ok, _updated_lobby} = LobbyManager.join_lobby(lobby_id, player)

      # Give a brief moment for the registry to process the updates
      Process.sleep(50)

      # Now the user should be in the lobby
      lobbies = LobbyRegistry.get_user_lobbies(second_user_id)
      assert length(lobbies) == 1
      assert hd(lobbies).id == lobby_id
    end

    test "updates mappings when a user leaves a lobby", %{second_user_id: second_user_id, lobby_id: lobby_id} do
      # Join the lobby first
      player = %{
        "id" => second_user_id,
        "username" => "SecondUser",
        "avatar" => "avatar2.jpg",
        "discord_id" => "test_discord2"
      }

      {:ok, _updated_lobby} = LobbyManager.join_lobby(lobby_id, player)

      # Give a brief moment for the registry to process the updates
      Process.sleep(50)

      # Verify user is in the lobby
      assert length(LobbyRegistry.get_user_lobbies(second_user_id)) == 1

      # Now leave the lobby
      {:ok, _} = LobbyManager.leave_lobby(lobby_id, second_user_id)

      # Give a brief moment for the registry to process the updates
      Process.sleep(50)

      # User should no longer be in any lobbies
      assert LobbyRegistry.get_user_lobbies(second_user_id) == []
    end

    test "handles a user in multiple lobbies", %{user_id: user_id, second_user_id: second_user_id} do
      # Create a second lobby
      lobby_params = %{
        "title" => "Second Test Lobby",
        "region" => "NA",
        "rank_required" => "Gold",
        "lobby_type" => "Casual",
        "team_size" => "5",
        "description" => "Another test lobby",
        "creator" => %{
          "id" => second_user_id,
          "username" => "SecondUser",
          "avatar" => "avatar2.jpg",
          "discord_id" => "test_discord2"
        }
      }

      {:ok, second_lobby} = LobbyManager.create_lobby(lobby_params)

      # Join the second user to the first lobby
      player = %{
        "id" => user_id,
        "username" => "TestUser",
        "avatar" => "avatar.jpg",
        "discord_id" => "test_discord"
      }

      {:ok, _} = LobbyManager.join_lobby(second_lobby.id, player)

      # Give a brief moment for the registry to process the updates
      Process.sleep(50)

      # The first user should now be in both lobbies
      lobbies = LobbyRegistry.get_user_lobbies(user_id)
      assert length(lobbies) == 2

      # The second user should be in only one lobby
      lobbies = LobbyRegistry.get_user_lobbies(second_user_id)
      assert length(lobbies) == 1
      assert hd(lobbies).id == second_lobby.id
    end

    test "cleans up mappings when a lobby is deleted", %{user_id: user_id, lobby_id: lobby_id} do
      # Initially, user should be in the lobby
      assert length(LobbyRegistry.get_user_lobbies(user_id)) == 1

      # Delete the lobby
      :ok = LobbyManager.delete_lobby(lobby_id)

      # Give a brief moment for the registry to process the updates
      Process.sleep(50)

      # User should no longer be in any lobbies
      assert LobbyRegistry.get_user_lobbies(user_id) == []
    end
  end
end
