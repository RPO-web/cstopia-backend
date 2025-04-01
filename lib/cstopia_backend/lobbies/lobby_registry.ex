defmodule CstopiaBackend.Lobbies.LobbyRegistry do
  use GenServer
  require Logger
  alias Phoenix.PubSub

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
    GenServer.call(__MODULE__, {:get_lobby, lobby_id})
  end

  # Server callbacks
  @impl true
  def init(:ok) do
    # Monitor existing lobbies
    lobbies =
      CstopiaBackend.Lobbies.LobbyServer.list_lobbies()
      |> Enum.map(fn lobby -> {lobby.id, lobby} end)
      |> Map.new()

    # Subscribe to lobby events
    PubSub.subscribe(CstopiaBackend.PubSub, "lobbies")

    {:ok, %{lobbies: lobbies}}
  end

  @impl true
  def handle_call(:get_lobbies, _from, state) do
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
    updated_lobbies = Map.put(state.lobbies, lobby.id, lobby)
    broadcast_lobbies_updated(updated_lobbies)
    {:noreply, %{state | lobbies: updated_lobbies}}
  end

  @impl true
  def handle_info({:lobby_closed, lobby}, state) do
    updated_lobbies = Map.delete(state.lobbies, lobby.id)
    broadcast_lobbies_updated(updated_lobbies)
    {:noreply, %{state | lobbies: updated_lobbies}}
  end

  @impl true
  def handle_info({:lobby_updated, lobby}, state) do
    updated_lobbies = Map.put(state.lobbies, lobby.id, lobby)
    broadcast_lobbies_updated(updated_lobbies)
    {:noreply, %{state | lobbies: updated_lobbies}}
  end

  @impl true
  def handle_info({:player_joined, _player, lobby}, state) do
    updated_lobbies = Map.put(state.lobbies, lobby.id, lobby)
    broadcast_lobbies_updated(updated_lobbies)
    {:noreply, %{state | lobbies: updated_lobbies}}
  end

  @impl true
  def handle_info({:player_left, _player_id, lobby}, state) do
    updated_lobbies = Map.put(state.lobbies, lobby.id, lobby)
    broadcast_lobbies_updated(updated_lobbies)
    {:noreply, %{state | lobbies: updated_lobbies}}
  end

  @impl true
  def handle_info({:player_kicked, _player_id, lobby}, state) do
    updated_lobbies = Map.put(state.lobbies, lobby.id, lobby)
    broadcast_lobbies_updated(updated_lobbies)
    {:noreply, %{state | lobbies: updated_lobbies}}
  end

  @impl true
  def handle_info({:host_migrated, _new_leader_id, lobby}, state) do
    updated_lobbies = Map.put(state.lobbies, lobby.id, lobby)
    broadcast_lobbies_updated(updated_lobbies)
    {:noreply, %{state | lobbies: updated_lobbies}}
  end

  # Helper to broadcast the current list of lobbies
  defp broadcast_lobbies_updated(lobbies) do
    PubSub.broadcast(
      CstopiaBackend.PubSub,
      "lobby_registry",
      {:lobbies_updated, Map.values(lobbies)}
    )
  end
end
