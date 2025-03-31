defmodule CstopiaBackend.Lobbies.LobbyServer do
  use GenServer
  alias Phoenix.PubSub

  # Client API

  def start_link(lobby_id) do
    GenServer.start_link(__MODULE__, %{}, name: via_tuple(lobby_id))
  end

  def create_lobby(params) do
    lobby_id = System.unique_integer([:positive]) |> to_string()

    # Add joined_at timestamp to the creator
    creator = Map.put(params["creator"], "joined_at", DateTime.utc_now())

    lobby = %{
      id: lobby_id,
      title: params["title"],
      region: params["region"],
      rank_required: params["rank_required"],
      lobby_type: params["lobby_type"],
      team_size: params["team_size"],
      description: params["description"],
      players: [creator],
      leader_id: params["creator"]["id"],
      created_at: DateTime.utc_now(),
      blocked_users: MapSet.new()
    }

    {:ok, _pid} = DynamicSupervisor.start_child(
      CstopiaBackend.Lobbies.LobbySupervisor,
      {__MODULE__, lobby_id}
    )

    GenServer.call(via_tuple(lobby_id), {:set_lobby, lobby})

    # Broadcast creation of the new lobby
    PubSub.broadcast(CstopiaBackend.PubSub, "lobbies", {:lobby_created, lobby})

    {:ok, lobby}
  end

  def get_lobby(lobby_id) do
    GenServer.call(via_tuple(lobby_id), :get_lobby)
  end

  def join_lobby(lobby_id, player) do
    GenServer.call(via_tuple(lobby_id), {:join_lobby, player})
  end

  def leave_lobby(lobby_id, player_id) do
    GenServer.call(via_tuple(lobby_id), {:leave_lobby, player_id})
  end

  def delete_lobby(lobby_id) do
    GenServer.call(via_tuple(lobby_id), :delete_lobby)
  end

  # New function for kicking a player
  def kick_player(lobby_id, player_id, should_block \\ false) do
    GenServer.call(via_tuple(lobby_id), {:kick_player, player_id, should_block})
  end

  # Get all current lobbies
  def list_lobbies do
    # Get all active lobby processes
    DynamicSupervisor.which_children(CstopiaBackend.Lobbies.LobbySupervisor)
    |> Enum.map(fn {_, pid, _, _} ->
      try do
        lobby_id = Registry.keys(CstopiaBackend.Lobbies.LobbyRegistry, pid) |> List.first()
        GenServer.call(via_tuple(lobby_id), :get_lobby)
      catch
        :exit, _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # Server Callbacks

  @impl true
  def init(_) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:set_lobby, lobby}, _from, _state) do
    {:reply, {:ok, lobby}, lobby}
  end

  @impl true
  def handle_call(:get_lobby, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:join_lobby, player}, _from, state) do
    # Check if player is already in lobby or if lobby is full
    if Enum.any?(state.players, fn p -> p["id"] == player["id"] end) do
      {:reply, {:error, "Player already in lobby"}, state}
    else
      # Check if the player is blocked
      if MapSet.member?(state.blocked_users, player["id"]) do
        {:reply, {:error, "You have been blocked from this lobby"}, state}
      else
        if length(state.players) >= String.to_integer(state.team_size) do
          {:reply, {:error, "Lobby is full"}, state}
        else
          # Add joined_at timestamp to the player
          player_with_timestamp = Map.put(player, "joined_at", DateTime.utc_now())
          updated_players = [player_with_timestamp | state.players]
          updated_state = %{state | players: updated_players}

          # Broadcast player joined
          PubSub.broadcast(
            CstopiaBackend.PubSub,
            "lobby:#{state.id}",
            {:player_joined, player, updated_state}
          )

          {:reply, {:ok, updated_state}, updated_state}
        end
      end
    end
  end

  @impl true
  def handle_call({:leave_lobby, player_id}, _from, state) do
    updated_players = Enum.reject(state.players, fn p -> p["id"] == player_id end)

    # If lobby becomes empty, terminate it
    if updated_players == [] do
      # Broadcast lobby closed
      PubSub.broadcast(
        CstopiaBackend.PubSub,
        "lobbies",
        {:lobby_closed, state}
      )

      # Stop the server process
      Process.send_after(self(), :shutdown, 0)

      {:reply, {:ok, :lobby_closed}, state}
    else
      # If the leader left, find a new leader based on seniority
      updated_state = if player_id == state.leader_id do
        # Find the player who joined earliest (excluding the leader who just left)
        next_leader = find_next_host(updated_players)
        new_leader_id = next_leader["id"]

        updated_state = %{state | players: updated_players, leader_id: new_leader_id}

        # Broadcast host migration
        PubSub.broadcast(
          CstopiaBackend.PubSub,
          "lobby:#{state.id}",
          {:host_migrated, new_leader_id, updated_state}
        )

        updated_state
      else
        %{state | players: updated_players}
      end

      # Broadcast player left
      PubSub.broadcast(
        CstopiaBackend.PubSub,
        "lobby:#{state.id}",
        {:player_left, player_id, updated_state}
      )

      {:reply, {:ok, updated_state}, updated_state}
    end
  end

  @impl true
  def handle_call({:kick_player, player_id, should_block}, {from_pid, _}, state) do
    # Get the caller's identity from the PID
    # In a real implementation, you'd need a more robust way to verify the caller's identity
    # This is a simplified version for demonstration

    # Only the leader can kick players
    if state.leader_id == player_id do
      {:reply, {:error, "Cannot kick the lobby leader"}, state}
    else
      # Update the block list if requested
      blocked_users = if should_block do
        MapSet.put(state.blocked_users, player_id)
      else
        state.blocked_users
      end

      # Remove the player
      updated_players = Enum.reject(state.players, fn p -> p["id"] == player_id end)
      updated_state = %{state | players: updated_players, blocked_users: blocked_users}

      # Broadcast player kicked
      PubSub.broadcast(
        CstopiaBackend.PubSub,
        "lobby:#{state.id}",
        {:player_kicked, player_id, updated_state}
      )

      {:reply, {:ok, updated_state}, updated_state}
    end
  end

  @impl true
  def handle_call(:delete_lobby, _from, state) do
    # Broadcast lobby deleted
    PubSub.broadcast(
      CstopiaBackend.PubSub,
      "lobbies",
      {:lobby_closed, state}
    )

    # Stop the server process
    Process.send_after(self(), :shutdown, 0)

    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:shutdown, state) do
    {:stop, :normal, state}
  end

  # Helper for process registration
  defp via_tuple(lobby_id) do
    {:via, Registry, {CstopiaBackend.Lobbies.LobbyRegistry, lobby_id}}
  end

  # Helper function to find the next host based on seniority
  defp find_next_host(players) do
    # Sort players by joined_at timestamp (oldest first)
    Enum.sort_by(players, fn player ->
      case player["joined_at"] do
        nil -> DateTime.utc_now()  # Fallback for players without timestamp
        joined_at -> joined_at
      end
    end, DateTime)
    |> List.first()  # Take the player who's been in the lobby longest
  end
end
