defmodule CstopiaBackend.Lobbies.LobbyManager do
  alias CstopiaBackend.Lobbies.LobbyServer
  alias CstopiaBackend.Lobbies.LobbyRegistry
  require Logger

  @process_registry CstopiaBackend.Lobbies.LobbyProcessRegistry
  @ets_table :lobby_registry_cache

  # Create a new lobby with the given parameters
  def create_lobby(params) do
    LobbyServer.create_lobby(params)
  end

  # List all active lobbies with improved filtering
  def list_lobbies do
    LobbyRegistry.get_lobbies()
  end

  # Fast lookup for lobby existence check (no full state needed)
  def lobby_exists?(lobby_id) do
    case Registry.lookup(@process_registry, lobby_id) do
      [{_pid, _}] -> true
      [] -> false
    end
  end

  # Get a specific lobby - use ETS when available
  def get_lobby(lobby_id) do
    LobbyRegistry.get_lobby(lobby_id)
  end

  # Fast lookup for active lobby count
  def active_lobby_count do
    :ets.info(@ets_table, :size)
  end

  # Efficient batch update of user activity in all their lobbies
  def update_user_activity_all_lobbies(user_id) do
    # Find all lobbies the user is in
    find_user_lobbies(user_id)
    |> Enum.each(fn lobby ->
      update_user_activity(lobby.id, user_id)
    end)
  end

  # Join a lobby
  def join_lobby(lobby_id, player) do
    LobbyServer.join_lobby(lobby_id, player)
  end

  # Leave a lobby
  def leave_lobby(lobby_id, player_id) do
    LobbyServer.leave_lobby(lobby_id, player_id)
  end

  # Mark a user as disconnected in a lobby
  def user_disconnected(lobby_id, user_id) do
    case LobbyServer.user_disconnected(lobby_id, user_id) do
      {:error, _} -> {:error, :not_found}
      _ -> :ok
    end
  end

  # Mark a user as reconnected to a lobby
  def user_reconnected(lobby_id, user_id) do
    case LobbyServer.user_reconnected(lobby_id, user_id) do
      {:error, _} -> {:error, :not_found}
      _ -> :ok
    end
  end

  # Update user activity timestamp in a lobby
  def update_user_activity(lobby_id, user_id) do
    case LobbyServer.update_user_activity(lobby_id, user_id) do
      {:error, _} -> {:error, :not_found}
      _ -> :ok
    end
  end

  # Check if a user is in a specific lobby - optimized to use ETS for faster lookup
  def user_in_lobby?(lobby_id, user_id) do
    # First attempt to use ETS for fastest lookup
    case :ets.lookup(@ets_table, lobby_id) do
      [{^lobby_id, lobby}] ->
        Enum.any?(lobby.players, fn player ->
          is_map(player) && Map.has_key?(player, "id") && player["id"] == user_id
        end)
      [] ->
        # Fall back to direct lookup if not in ETS
        case get_lobby(lobby_id) do
          {:ok, lobby} ->
            Enum.any?(lobby.players, fn player ->
              is_map(player) && Map.has_key?(player, "id") && player["id"] == user_id
            end)
          _ -> false
        end
    end
  rescue
    # Handle case where ETS table doesn't exist yet
    _ -> LobbyServer.user_in_lobby?(lobby_id, user_id)
  end

  # Find all lobbies a user is in - now uses dedicated ETS table for user-to-lobby mapping
  def find_user_lobbies(user_id) do
    # Use the optimized lookup from LobbyRegistry
    LobbyRegistry.get_user_lobbies(user_id)
  end

  # Kick a player from a lobby (only leaders can do this)
  def kick_player(lobby_id, player_id, requesting_user_id, should_block \\ false) do
    with {:ok, lobby} <- get_lobby(lobby_id),
         true <- lobby.leader_id == requesting_user_id do
      LobbyServer.kick_player(lobby_id, player_id, should_block)
    else
      {:error, _} -> {:error, :not_found}
      false -> {:error, :not_authorized}
    end
  end

  # Delete a lobby
  def delete_lobby(lobby_id) do
    LobbyServer.delete_lobby(lobby_id)
  end

  # Transfer leadership to another player (only current leader can do this)
  def transfer_leadership(lobby_id, current_leader_id, new_leader_id) do
    with {:ok, lobby} <- get_lobby(lobby_id),
         true <- lobby.leader_id == current_leader_id do
      LobbyServer.transfer_leadership(lobby_id, current_leader_id, new_leader_id)
    else
      {:error, _} -> {:error, :not_found}
      false -> {:error, :not_authorized}
    end
  end

  # Update player positions in a lobby (only the leader can do this)
  def update_player_positions(lobby_id, leader_id, player_order) do
    with {:ok, lobby} <- get_lobby(lobby_id),
         true <- lobby.leader_id == leader_id do
      LobbyServer.update_player_positions(lobby_id, leader_id, player_order)
    else
      {:error, _} -> {:error, :not_found}
      false -> {:error, :not_authorized}
    end
  end

  # Filter lobbies by criteria with improved efficiency
  def filter_lobbies(criteria) do
    LobbyRegistry.filter_lobbies(criteria)
  end
end
