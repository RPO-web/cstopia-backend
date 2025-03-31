defmodule CstopiaBackend.Lobbies.LobbyServer do
  use GenServer
  alias Phoenix.PubSub
  require Logger

  # Client API

  def start_link(lobby_id) do
    GenServer.start_link(__MODULE__, %{}, name: via_tuple(lobby_id))
  end

  def create_lobby(params) do
    lobby_id = System.unique_integer([:positive]) |> to_string()

    # Add joined_at timestamp and connection status to the creator
    creator = Map.merge(params["creator"], %{
      "joined_at" => DateTime.utc_now(),
      "connected" => true,
      "last_activity" => DateTime.utc_now()
    })

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
      blocked_users: MapSet.new(),
      inactive_timers: %{}
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

  # Mark user as disconnected
  def user_disconnected(lobby_id, user_id) do
    GenServer.cast(via_tuple(lobby_id), {:user_disconnected, user_id})
  end

  # Mark user as reconnected
  def user_reconnected(lobby_id, user_id) do
    GenServer.cast(via_tuple(lobby_id), {:user_reconnected, user_id})
  end

  # Update user's activity timestamp
  def update_user_activity(lobby_id, user_id) do
    GenServer.cast(via_tuple(lobby_id), {:update_user_activity, user_id})
  end

  # New function for kicking a player
  def kick_player(lobby_id, player_id, should_block \\ false) do
    GenServer.call(via_tuple(lobby_id), {:kick_player, player_id, should_block})
  end

  # Check if a user is in a specific lobby
  def user_in_lobby?(lobby_id, user_id) do
    try do
      lobby = get_lobby(lobby_id)
      Enum.any?(lobby.players, fn p -> p["id"] == user_id end)
    catch
      :exit, _ -> false
    end
  end

  # Get all current lobbies
  def list_lobbies do
    # Get all active lobby processes
    try do
      DynamicSupervisor.which_children(CstopiaBackend.Lobbies.LobbySupervisor)
      |> Enum.map(fn {_, pid, _, _} ->
        try do
          lobby_id = Registry.keys(CstopiaBackend.Lobbies.LobbyRegistry, pid) |> List.first()
          if lobby_id do
            GenServer.call(via_tuple(lobby_id), :get_lobby)
          else
            nil
          end
        catch
          :exit, _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
    catch
      _, _ -> []
    end
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
    # Filter out any internal server state before returning
    public_state = Map.drop(state, [:inactive_timers])
    {:reply, public_state, state}
  end

  @impl true
  def handle_call({:join_lobby, player}, _from, state) do
    # Check if player is already in lobby or if lobby is full
    if Enum.any?(state.players, fn p -> p["id"] == player["id"] end) do
      # Player is rejoining, mark them as connected again
      updated_players = Enum.map(state.players, fn p ->
        if p["id"] == player["id"] do
          # Update player status and cancel any pending timeout
          Map.merge(p, %{
            "connected" => true,
            "last_activity" => DateTime.utc_now()
          })
        else
          p
        end
      end)

      # Cancel any pending inactivity timer
      timer_ref = get_in(state, [:inactive_timers, player["id"]])
      if timer_ref, do: Process.cancel_timer(timer_ref)

      updated_timers = Map.delete(state.inactive_timers, player["id"])
      updated_state = %{state | players: updated_players, inactive_timers: updated_timers}

      # Broadcast player rejoined
      PubSub.broadcast(
        CstopiaBackend.PubSub,
        "lobby:#{state.id}",
        {:player_rejoined, player, updated_state}
      )

      {:reply, {:ok, updated_state}, updated_state}
    else
      # Check if the player is blocked
      if MapSet.member?(state.blocked_users, player["id"]) do
        {:reply, {:error, "You have been blocked from this lobby"}, state}
      else
        if length(state.players) >= String.to_integer(state.team_size) do
          {:reply, {:error, "Lobby is full"}, state}
        else
          # Add connection status and timestamps to the player
          player_with_status = Map.merge(player, %{
            "joined_at" => DateTime.utc_now(),
            "connected" => true,
            "last_activity" => DateTime.utc_now()
          })

          updated_players = [player_with_status | state.players]
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
    # Cancel any pending inactive timer for this player
    timer_ref = get_in(state, [:inactive_timers, player_id])
    if timer_ref, do: Process.cancel_timer(timer_ref)

    updated_timers = Map.delete(state.inactive_timers, player_id)
    updated_players = Enum.reject(state.players, fn p -> p["id"] == player_id end)

    # If lobby becomes empty, terminate it
    if updated_players == [] do
      # Broadcast lobby closed
      PubSub.broadcast(
        CstopiaBackend.PubSub,
        "lobbies",
        {:lobby_closed, state}
      )

      # Stop the server process with a short delay to allow broadcasts to complete
      Process.send_after(self(), :shutdown, 100)

      {:reply, {:ok, :lobby_closed}, %{state | players: [], inactive_timers: %{}}}
    else
      # If the leader left, find a new leader based on seniority
      updated_state = if player_id == state.leader_id do
        # Find the player who joined earliest (excluding the leader who just left)
        # Prioritize connected players
        next_leader = find_next_host(updated_players)

        if next_leader do
        new_leader_id = next_leader["id"]

          updated_state = %{state |
            players: updated_players,
            leader_id: new_leader_id,
            inactive_timers: updated_timers
          }

        # Broadcast host migration
        PubSub.broadcast(
          CstopiaBackend.PubSub,
          "lobby:#{state.id}",
          {:host_migrated, new_leader_id, updated_state}
        )

        updated_state
      else
          # No eligible leader, close the lobby
          PubSub.broadcast(
            CstopiaBackend.PubSub,
            "lobbies",
            {:lobby_closed, state}
          )

          Process.send_after(self(), :shutdown, 100)
          %{state | players: [], inactive_timers: %{}}
        end
      else
        %{state | players: updated_players, inactive_timers: updated_timers}
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
  def handle_call({:kick_player, player_id, should_block}, _from, state) do
    # Only the leader can kick players
    if state.leader_id == player_id do
      {:reply, {:error, "Cannot kick the lobby leader"}, state}
    else
      # Cancel any pending inactive timer for this player
      timer_ref = get_in(state, [:inactive_timers, player_id])
      if timer_ref, do: Process.cancel_timer(timer_ref)

      # Update the block list if requested
      blocked_users = if should_block do
        MapSet.put(state.blocked_users, player_id)
      else
        state.blocked_users
      end

      # Remove the player
      updated_players = Enum.reject(state.players, fn p -> p["id"] == player_id end)
      updated_timers = Map.delete(state.inactive_timers, player_id)
      updated_state = %{state |
        players: updated_players,
        blocked_users: blocked_users,
        inactive_timers: updated_timers
      }

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
    # Cancel all pending timers
    Enum.each(state.inactive_timers, fn {_player_id, timer_ref} ->
      Process.cancel_timer(timer_ref)
    end)

    # Broadcast lobby deleted
    PubSub.broadcast(
      CstopiaBackend.PubSub,
      "lobbies",
      {:lobby_closed, state}
    )

    # Stop the server process with a short delay
    Process.send_after(self(), :shutdown, 100)

    {:reply, :ok, %{state | inactive_timers: %{}}}
  end

  @impl true
  def handle_cast({:user_disconnected, user_id}, state) do
    # Mark the user as disconnected
    updated_players = Enum.map(state.players, fn player ->
      if player["id"] == user_id do
        Map.put(player, "connected", false)
      else
        player
      end
    end)

    # Start a timer to remove the user after 30 seconds of inactivity
    timer_ref = Process.send_after(
      self(),
      {:remove_inactive_user, user_id},
      30_000  # 30 seconds
    )

    updated_timers = Map.put(state.inactive_timers, user_id, timer_ref)
    updated_state = %{state | players: updated_players, inactive_timers: updated_timers}

    # Broadcast user disconnection
    PubSub.broadcast(
      CstopiaBackend.PubSub,
      "lobby:#{state.id}",
      {:player_disconnected, user_id, updated_state}
    )

    {:noreply, updated_state}
  end

  @impl true
  def handle_cast({:user_reconnected, user_id}, state) do
    # Cancel any pending inactivity timer
    timer_ref = get_in(state, [:inactive_timers, user_id])
    if timer_ref, do: Process.cancel_timer(timer_ref)

    # Mark the user as connected again
    updated_players = Enum.map(state.players, fn player ->
      if player["id"] == user_id do
        player
        |> Map.put("connected", true)
        |> Map.put("last_activity", DateTime.utc_now())
      else
        player
      end
    end)

    updated_timers = Map.delete(state.inactive_timers, user_id)
    updated_state = %{state | players: updated_players, inactive_timers: updated_timers}

    # Broadcast user reconnection
    PubSub.broadcast(
      CstopiaBackend.PubSub,
      "lobby:#{state.id}",
      {:player_reconnected, user_id, updated_state}
    )

    {:noreply, updated_state}
  end

  @impl true
  def handle_cast({:update_user_activity, user_id}, state) do
    # Update the user's last activity timestamp
    updated_players = Enum.map(state.players, fn player ->
      if player["id"] == user_id do
        Map.put(player, "last_activity", DateTime.utc_now())
      else
        player
      end
    end)

    {:noreply, %{state | players: updated_players}}
  end

  @impl true
  def handle_info({:remove_inactive_user, user_id}, state) do
    Logger.info("Removing inactive user #{user_id} from lobby #{state.id}")

    # Check if this user is actually in the lobby still
    player = Enum.find(state.players, fn p -> p["id"] == user_id end)

    if player && player["connected"] == false do
      # User is still inactive, remove them
      case handle_call({:leave_lobby, user_id}, self(), state) do
        {:reply, {:ok, _}, new_state} ->
          {:noreply, new_state}
        _ ->
          {:noreply, state}
      end
    else
      # User has reconnected or already left, do nothing
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:shutdown, state) do
    Logger.info("Shutting down lobby #{state.id}")
    {:stop, :normal, state}
  end

  # Helper for process registration
  defp via_tuple(lobby_id) do
    {:via, Registry, {CstopiaBackend.Lobbies.LobbyRegistry, lobby_id}}
  end

  # Helper function to find the next host based on seniority
  defp find_next_host(players) do
    if players == [] do
      nil
    else
      # First try to find a connected player
      connected_player = Enum.find(players, fn p -> p["connected"] == true end)

      if connected_player do
        # Found a connected player, use them
        connected_player
      else
        # No connected players, sort by joined_at timestamp (oldest first)
    Enum.sort_by(players, fn player ->
      case player["joined_at"] do
        nil -> DateTime.utc_now()  # Fallback for players without timestamp
        joined_at -> joined_at
      end
    end, DateTime)
    |> List.first()  # Take the player who's been in the lobby longest
      end
    end
  end
end
