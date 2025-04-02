defmodule CstopiaBackend.Lobbies.LobbyRegistry do
  use GenServer
  require Logger
  alias Phoenix.PubSub

  @ets_table :lobby_registry_cache
  @user_lobby_table :user_lobby_mapping

  # Client API
  def start_link(_) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def get_lobbies() do
    GenServer.call(__MODULE__, :get_lobbies)
  end

  def filter_lobbies(criteria) do
    GenServer.call(__MODULE__, {:filter_lobbies, criteria})
  end

  def get_lobby(lobby_id) do
    # Try ETS lookup first for performance
    try do
      case :ets.lookup(@ets_table, lobby_id) do
        [{^lobby_id, lobby}] -> {:ok, lobby}
        [] -> GenServer.call(__MODULE__, {:get_lobby, lobby_id})
      end
    rescue
      # If ETS table doesn't exist, fall back to GenServer
      _ -> GenServer.call(__MODULE__, {:get_lobby, lobby_id})
    end
  end

  # Fast lookup for finding lobbies a user is in
  def get_user_lobbies(user_id) do
    try do
      case :ets.lookup(@user_lobby_table, user_id) do
        [{^user_id, lobby_ids}] ->
          # Get all the lobbies from the lobby table
          lobby_ids
          |> Enum.flat_map(fn id ->
            case :ets.lookup(@ets_table, id) do
              [{^id, lobby}] -> [lobby]
              [] -> []
            end
          end)
        [] -> []
      end
    rescue
      # If ETS tables don't exist yet, return empty list
      _ -> []
    end
  end

  # Server callbacks
  @impl true
  def init(:ok) do
    # Create ETS table for fast lookups
    :ets.new(@ets_table, [:set, :public, :named_table])
    # Create ETS table for user-to-lobby mapping
    :ets.new(@user_lobby_table, [:set, :public, :named_table])

    # Monitor existing lobbies
    lobbies =
      CstopiaBackend.Lobbies.LobbyServer.list_lobbies()
      |> Enum.map(fn lobby -> {lobby.id, lobby} end)
      |> Map.new()

    # Initialize ETS tables with existing lobbies
    Enum.each(lobbies, fn {id, lobby} ->
      :ets.insert(@ets_table, {id, lobby})
      update_user_lobby_mapping(lobby)
    end)

    # Subscribe to lobby events
    PubSub.subscribe(CstopiaBackend.PubSub, "lobbies")

    {:ok, %{lobbies: lobbies}}
  end

  @impl true
  def handle_call(:get_lobbies, _from, state) do
    # For very fast reads, we could use :ets.tab2list(@ets_table),
    # but for now we'll stick with the state for consistency
    {:reply, Map.values(state.lobbies), state}
  end

  @impl true
  def handle_call({:filter_lobbies, criteria}, _from, state) do
    filtered =
      state.lobbies
      |> Map.values()
      |> Enum.filter(fn lobby ->
        Enum.all?(criteria, fn {key, value} ->
          Map.get(lobby, key) == value
        end)
      end)

    {:reply, filtered, state}
  end

  @impl true
  def handle_call({:get_lobby, lobby_id}, _from, state) do
    case Map.get(state.lobbies, lobby_id) do
      nil -> {:reply, {:error, :not_found}, state}
      lobby -> {:reply, {:ok, lobby}, state}
    end
  end

  # Handle lobby lifecycle events
  @impl true
  def handle_info({:lobby_created, lobby}, state) do
    # Update both state and ETS caches
    safe_ets_insert(@ets_table, {lobby.id, lobby})
    update_user_lobby_mapping(lobby)

    updated_lobbies = Map.put(state.lobbies, lobby.id, lobby)
    broadcast_lobbies_updated(updated_lobbies)
    {:noreply, %{state | lobbies: updated_lobbies}}
  end

  @impl true
  def handle_info({:lobby_closed, lobby}, state) do
    # Remove from both state and ETS caches
    safe_ets_delete(@ets_table, lobby.id)
    remove_user_lobby_mapping(lobby)

    updated_lobbies = Map.delete(state.lobbies, lobby.id)
    broadcast_lobbies_updated(updated_lobbies)
    {:noreply, %{state | lobbies: updated_lobbies}}
  end

  @impl true
  def handle_info({:lobby_updated, lobby}, state) do
    # Update both state and ETS caches
    safe_ets_insert(@ets_table, {lobby.id, lobby})
    update_user_lobby_mapping(lobby)

    updated_lobbies = Map.put(state.lobbies, lobby.id, lobby)
    broadcast_lobbies_updated(updated_lobbies)
    {:noreply, %{state | lobbies: updated_lobbies}}
  end

  @impl true
  def handle_info({:player_joined, _player, lobby}, state) do
    safe_ets_insert(@ets_table, {lobby.id, lobby})
    update_user_lobby_mapping(lobby)

    updated_lobbies = Map.put(state.lobbies, lobby.id, lobby)
    broadcast_lobbies_updated(updated_lobbies)
    {:noreply, %{state | lobbies: updated_lobbies}}
  end

  @impl true
  def handle_info({:player_left, _player_id, lobby}, state) do
    safe_ets_insert(@ets_table, {lobby.id, lobby})
    update_user_lobby_mapping(lobby)

    updated_lobbies = Map.put(state.lobbies, lobby.id, lobby)
    broadcast_lobbies_updated(updated_lobbies)
    {:noreply, %{state | lobbies: updated_lobbies}}
  end

  @impl true
  def handle_info({:player_kicked, _player_id, lobby}, state) do
    safe_ets_insert(@ets_table, {lobby.id, lobby})
    update_user_lobby_mapping(lobby)

    updated_lobbies = Map.put(state.lobbies, lobby.id, lobby)
    broadcast_lobbies_updated(updated_lobbies)
    {:noreply, %{state | lobbies: updated_lobbies}}
  end

  @impl true
  def handle_info({:host_migrated, _new_leader_id, lobby}, state) do
    safe_ets_insert(@ets_table, {lobby.id, lobby})
    updated_lobbies = Map.put(state.lobbies, lobby.id, lobby)
    broadcast_lobbies_updated(updated_lobbies)
    {:noreply, %{state | lobbies: updated_lobbies}}
  end

  # Helper for safe ETS operations
  defp safe_ets_insert(table, object) do
    :ets.insert(table, object)
  rescue
    e ->
      Logger.error("Failed to update ETS table #{table}: #{inspect(e)}")
      :error
  end

  # Helper for safe ETS operations
  defp safe_ets_delete(table, key) do
    :ets.delete(table, key)
  rescue
    e ->
      Logger.error("Failed to delete from ETS table #{table}: #{inspect(e)}")
      :error
  end

  # Helper to broadcast the current list of lobbies
  defp broadcast_lobbies_updated(lobbies) do
    PubSub.broadcast(
      CstopiaBackend.PubSub,
      "lobby_registry",
      {:lobbies_updated, Map.values(lobbies)}
    )
  end

  # Helper to update the user-to-lobby mapping
  defp update_user_lobby_mapping(lobby) do
    # First, remove all existing mappings for this lobby
    remove_user_lobby_mapping(lobby)

    # Then add new mappings for all players in the lobby
    if Map.has_key?(lobby, :players) && is_list(lobby.players) do
      Enum.each(lobby.players, fn player ->
        user_id = player["id"] || player[:id]
        if user_id do
          try do
            case :ets.lookup(@user_lobby_table, user_id) do
              [{^user_id, lobby_ids}] ->
                # Update existing mapping
                :ets.insert(@user_lobby_table, {user_id, [lobby.id | lobby_ids] |> Enum.uniq})
              [] ->
                # Create new mapping
                :ets.insert(@user_lobby_table, {user_id, [lobby.id]})
            end
          rescue
            _ -> :ok # Silently ignore ETS errors
          end
        end
      end)
    end
  end

  # Helper to remove user-to-lobby mappings for a lobby
  defp remove_user_lobby_mapping(lobby) do
    if Map.has_key?(lobby, :players) && is_list(lobby.players) do
      Enum.each(lobby.players, fn player ->
        user_id = player["id"] || player[:id]
        if user_id do
          try do
            case :ets.lookup(@user_lobby_table, user_id) do
              [{^user_id, lobby_ids}] ->
                # Remove this lobby from the list
                updated_ids = Enum.reject(lobby_ids, fn id -> id == lobby.id end)
                if Enum.empty?(updated_ids) do
                  # If no lobbies left, remove the entry
                  :ets.delete(@user_lobby_table, user_id)
                else
                  # Update with remaining lobbies
                  :ets.insert(@user_lobby_table, {user_id, updated_ids})
                end
              [] ->
                # No mapping exists, do nothing
                :ok
            end
          rescue
            _ -> :ok # Silently ignore ETS errors
          end
        end
      end)
    end
  end
end
