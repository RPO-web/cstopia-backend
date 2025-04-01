defmodule CstopiaBackend.Lobbies.LobbyManager do
  alias CstopiaBackend.Lobbies.LobbyServer
  alias CstopiaBackend.Lobbies.LobbyRegistry
  require Logger

  @process_registry CstopiaBackend.Lobbies.LobbyProcessRegistry

  # Create a new lobby with the given parameters
  def create_lobby(params) do
    LobbyServer.create_lobby(params)
  end

  # List all active lobbies with improved filtering
  def list_lobbies do
    LobbyRegistry.get_lobbies()
  end

  # Get a specific lobby
  def get_lobby(lobby_id) do
    LobbyRegistry.get_lobby(lobby_id)
  end

  # Join a lobby
  def join_lobby(lobby_id, player) do
    case Registry.lookup(@process_registry, lobby_id) do
      [{_pid, _}] ->
        LobbyServer.join_lobby(lobby_id, player)
      [] ->
        {:error, :not_found}
    end
  end

  # Leave a lobby
  def leave_lobby(lobby_id, player_id) do
    case Registry.lookup(@process_registry, lobby_id) do
      [{_pid, _}] ->
        LobbyServer.leave_lobby(lobby_id, player_id)
      [] ->
        {:error, :not_found}
    end
  end

  # Mark a user as disconnected in a lobby
  def user_disconnected(lobby_id, user_id) do
    with [{_pid, _}] <- Registry.lookup(@process_registry, lobby_id) do
      LobbyServer.user_disconnected(lobby_id, user_id)
      :ok
    else
      [] -> {:error, :not_found}
    end
  end

  # Mark a user as reconnected to a lobby
  def user_reconnected(lobby_id, user_id) do
    with [{_pid, _}] <- Registry.lookup(@process_registry, lobby_id) do
      LobbyServer.user_reconnected(lobby_id, user_id)
      :ok
    else
      [] -> {:error, :not_found}
    end
  end

  # Update user activity timestamp in a lobby
  def update_user_activity(lobby_id, user_id) do
    with [{_pid, _}] <- Registry.lookup(@process_registry, lobby_id) do
      LobbyServer.update_user_activity(lobby_id, user_id)
      :ok
    else
      [] -> {:error, :not_found}
    end
  end

  # Check if a user is in a specific lobby
  def user_in_lobby?(lobby_id, user_id) do
    case get_lobby(lobby_id) do
      {:ok, lobby} ->
        Enum.any?(lobby.players, fn player ->
          is_map(player) && Map.has_key?(player, "id") && player["id"] == user_id
        end)
      _ -> false
    end
  end

  # Find all lobbies a user is in
  def find_user_lobbies(user_id) do
    list_lobbies()
    |> Enum.filter(fn lobby ->
      Map.has_key?(lobby, :players) &&
      is_list(lobby.players) &&
      Enum.any?(lobby.players, fn player ->
        is_map(player) && Map.has_key?(player, "id") && player["id"] == user_id
      end)
    end)
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
    case Registry.lookup(@process_registry, lobby_id) do
      [{_pid, _}] ->
        LobbyServer.delete_lobby(lobby_id)
      [] ->
        {:error, :not_found}
    end
  end

  # Filter lobbies by criteria with improved efficiency
  def filter_lobbies(criteria) do
    LobbyRegistry.filter_lobbies(criteria)
  end
end
