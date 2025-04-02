defmodule CstopiaBackend.Lobbies.LobbyServer do
  use GenServer
  alias Phoenix.PubSub
  alias CstopiaBackend.Lobbies.LobbyChat
  require Logger

  @pubsub_module CstopiaBackend.PubSub
  @registry_name CstopiaBackend.Lobbies.LobbyProcessRegistry

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
      "last_activity" => DateTime.utc_now(),
      "position" => 0  # Leader is always position 0
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
      inactive_timers: %{},
      # Add chat message state with empty array and host-only mode disabled
      chat_messages: [],
      chat_host_only: false
    }

    {:ok, _pid} = DynamicSupervisor.start_child(
      CstopiaBackend.Lobbies.LobbySupervisor,
      {__MODULE__, lobby_id}
    )

    GenServer.call(via_tuple(lobby_id), {:set_lobby, lobby})

    # Broadcast creation of the new lobby with the event type
    broadcast_lobby_event(lobby, :lobby_created)

    {:ok, lobby}
  end

  def get_lobby(lobby_id) do
    case Registry.lookup(@registry_name, lobby_id) do
      [{pid, _}] -> GenServer.call(pid, :get_lobby)
      [] -> {:error, :lobby_not_found}
    end
  end

  def join_lobby(lobby_id, player) do
    case Registry.lookup(@registry_name, lobby_id) do
      [{pid, _}] -> GenServer.call(pid, {:join_lobby, player})
      [] -> {:error, :lobby_not_found}
    end
  end

  def leave_lobby(lobby_id, player_id) do
    case Registry.lookup(@registry_name, lobby_id) do
      [{pid, _}] -> GenServer.call(pid, {:leave_lobby, player_id})
      [] -> {:error, :lobby_not_found}
    end
  end

  def delete_lobby(lobby_id) do
    case Registry.lookup(@registry_name, lobby_id) do
      [{pid, _}] -> GenServer.call(pid, :delete_lobby)
      [] -> {:error, :lobby_not_found}
    end
  end

  # Mark user as disconnected
  def user_disconnected(lobby_id, user_id) do
    case Registry.lookup(@registry_name, lobby_id) do
      [{pid, _}] -> GenServer.cast(pid, {:user_disconnected, user_id})
      [] -> {:error, :lobby_not_found}
    end
  end

  # Mark user as reconnected
  def user_reconnected(lobby_id, user_id) do
    case Registry.lookup(@registry_name, lobby_id) do
      [{pid, _}] -> GenServer.cast(pid, {:user_reconnected, user_id})
      [] -> {:error, :lobby_not_found}
    end
  end

  # Update user's activity timestamp
  def update_user_activity(lobby_id, user_id) do
    case Registry.lookup(@registry_name, lobby_id) do
      [{pid, _}] -> GenServer.cast(pid, {:update_user_activity, user_id})
      [] -> {:error, :lobby_not_found}
    end
  end

  # Kick a player
  def kick_player(lobby_id, player_id, should_block \\ false) do
    case Registry.lookup(@registry_name, lobby_id) do
      [{pid, _}] -> GenServer.call(pid, {:kick_player, player_id, should_block})
      [] -> {:error, :lobby_not_found}
    end
  end

  # Transfer leadership to another player
  def transfer_leadership(lobby_id, current_leader_id, new_leader_id) do
    case Registry.lookup(@registry_name, lobby_id) do
      [{pid, _}] -> GenServer.call(pid, {:transfer_leadership, current_leader_id, new_leader_id})
      [] -> {:error, :lobby_not_found}
    end
  end

  # Check if a user is in a specific lobby
  def user_in_lobby?(lobby_id, user_id) do
    case Registry.lookup(@registry_name, lobby_id) do
      [{pid, _}] ->
        lobby = GenServer.call(pid, :get_lobby)
        Enum.any?(lobby.players, fn p -> p["id"] == user_id end)
      [] ->
        false
    end
  end

  # Get all current lobbies
  def list_lobbies do
    DynamicSupervisor.which_children(CstopiaBackend.Lobbies.LobbySupervisor)
    |> Enum.flat_map(fn {_, pid, _, _} ->
      case Registry.keys(@registry_name, pid) do
        [lobby_id] ->
          case GenServer.call(via_tuple(lobby_id), :get_lobby, 5000) do
            lobby when is_map(lobby) -> [lobby]
            _ -> []
          end
        _ -> []
      end
    end)
  rescue
    # Handle supervisor errors (like supervisor not started)
    _ -> []
  catch
    # Handle timeout errors
    :exit, _ -> []
  end

  # Update player positions in the lobby
  def update_player_positions(lobby_id, leader_id, player_order) do
    case Registry.lookup(@registry_name, lobby_id) do
      [{pid, _}] -> GenServer.call(pid, {:update_player_positions, leader_id, player_order})
      [] -> {:error, :lobby_not_found}
    end
  end

  def send_chat_message(lobby_id, user_id, message_text) when is_binary(message_text) do
    GenServer.call(via_tuple(lobby_id), {:send_chat_message, user_id, message_text})
  end

  def delete_chat_message(lobby_id, message_id, user_id) do
    GenServer.call(via_tuple(lobby_id), {:delete_chat_message, message_id, user_id})
  end

  def toggle_host_only_chat(lobby_id, user_id) do
    GenServer.call(via_tuple(lobby_id), {:toggle_host_only_chat, user_id})
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
  def handle_call({:transfer_leadership, current_leader_id, new_leader_id}, _from, state) do
    # Verify the request is from current leader
    if state.leader_id == current_leader_id do
      # Verify the new leader is in the lobby
      if Enum.any?(state.players, fn p -> p["id"] == new_leader_id end) do
        updated_state = %{state | leader_id: new_leader_id}
        # Broadcast the leadership transfer event
        broadcast_lobby_event(updated_state, :leadership_transferred, %{new_leader_id: new_leader_id})
        {:reply, {:ok, updated_state}, updated_state}
      else
        {:reply, {:error, "New leader must be in the lobby"}, state}
      end
    else
      {:reply, {:error, :not_authorized}, state}
    end
  end

  @impl true
  def handle_call({:update_player_positions, leader_id, player_order}, _from, state) do
    # Verify the request is from current leader
    if state.leader_id == leader_id do
      # Update the position for each player
      updated_players = Enum.reduce(player_order, state.players, fn {player_id, position}, players ->
        Enum.map(players, fn player ->
          if player["id"] == player_id do
            # Update the position, but leader is always position 0
            position_value = if player_id == leader_id, do: 0, else: position
            Map.put(player, "position", position_value)
          else
            player
          end
        end)
      end)

      # Sort the players by position
      sorted_players = Enum.sort_by(updated_players, fn p ->
        # Leader should always be at position 0
        if p["id"] == state.leader_id, do: -1, else: Map.get(p, "position", 999)
      end)

      updated_state = %{state | players: sorted_players}

      # Broadcast lobby updated
      broadcast_lobby_event(updated_state, :lobby_updated)

      {:reply, {:ok, updated_state}, updated_state}
    else
      {:reply, {:error, :not_authorized}, state}
    end
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
      broadcast_lobby_event(updated_state, :player_rejoined, %{player: player})
      # Broadcast to registry that lobby was updated
      broadcast_lobby_event(updated_state, :lobby_updated)

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
          # Calculate the position (one more than the current max position)
          max_position = state.players
                         |> Enum.map(fn p -> Map.get(p, "position", 0) end)
                         |> Enum.max(fn -> 0 end)

          player_with_status = Map.merge(player, %{
            "joined_at" => DateTime.utc_now(),
            "connected" => true,
            "last_activity" => DateTime.utc_now(),
            "position" => max_position + 1
          })

          # Ensure the players list is sorted by position
          updated_players = [player_with_status | state.players]
                           |> Enum.sort_by(fn p ->
                              # Leader should always be at position 0
                              if p["id"] == state.leader_id, do: -1, else: Map.get(p, "position", 999)
                            end)
          updated_state = %{state | players: updated_players}

          # Broadcast player joined
          broadcast_lobby_event(updated_state, :player_joined, %{player: player})
          # Broadcast to registry that lobby was updated
          broadcast_lobby_event(updated_state, :lobby_updated)

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
      # Broadcast lobby closed with the event type
      broadcast_lobby_event(state, :lobby_closed)

      # Stop the server directly instead of scheduling a delayed shutdown
      {:stop, :normal, {:ok, :lobby_closed}, %{state | players: [], inactive_timers: %{}}}
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

          # Consolidated broadcast - host migrated
          broadcast_lobby_event(updated_state, :host_migrated, %{new_leader_id: new_leader_id})

          updated_state
        else
          # No eligible leader, close the lobby
          broadcast_lobby_event(state, :lobby_closed)

          # Stop the server directly
          {:stop, :normal, {:ok, :lobby_closed}, %{state | players: [], inactive_timers: %{}}}
        end
      else
        %{state | players: updated_players, inactive_timers: updated_timers}
      end

      # Only if we didn't already return from the function
      if is_map(updated_state) do
        # Consolidated broadcast - player left
        broadcast_lobby_event(updated_state, :player_left, %{player_id: player_id})

        {:reply, {:ok, updated_state}, updated_state}
      end
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
      broadcast_lobby_event(updated_state, :player_kicked, %{player_id: player_id})
      # Broadcast to registry that lobby was updated
      broadcast_lobby_event(updated_state, :lobby_updated)

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
    broadcast_lobby_event(state, :lobby_closed)

    # Stop the server directly instead of scheduling a delayed shutdown
    {:stop, :normal, :ok, %{state | inactive_timers: %{}}}
  end

  @impl true
  def handle_cast({:user_disconnected, user_id}, state) do
    # Mark the user as disconnected
    updated_players = Enum.map(state.players, fn player ->
      if player["id"] == user_id do
        player
        |> Map.put("connected", false)
        |> Map.put("disconnected_at", DateTime.utc_now())
      else
        player
      end
    end)

    # Start a timer to remove the user after 5 minutes of inactivity
    timer_ref = Process.send_after(
      self(),
      {:remove_inactive_user, user_id},
      300_000  # 5 minutes (300 seconds)
    )

    updated_timers = Map.put(state.inactive_timers, user_id, timer_ref)
    updated_state = %{state | players: updated_players, inactive_timers: updated_timers}

    # Broadcast user disconnection
    broadcast_lobby_event(updated_state, :player_disconnected, %{player_id: user_id})
    # Broadcast to registry that lobby was updated
    broadcast_lobby_event(updated_state, :lobby_updated)

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
    broadcast_lobby_event(updated_state, :player_reconnected, %{player_id: user_id})
    # Broadcast to registry that lobby was updated
    broadcast_lobby_event(updated_state, :lobby_updated)

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
    Logger.info("Removing inactive user #{user_id} from lobby #{state.id} after 5 minutes of inactivity")

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
    {:via, Registry, {@registry_name, lobby_id}}
  end

  # Helper function to find the next host based on seniority
  defp find_next_host(players) do
    if players == [] do
      nil
    else
      # First try to find a connected player based on their order in the list
      connected_players = Enum.filter(players, fn p -> p["connected"] == true end)

      if !Enum.empty?(connected_players) do
        # If there are connected players, use the first one in the list
        List.first(connected_players)
      else
        # No connected players, just use the first player in the list
        List.first(players)
      end
    end
  end

  # Generate a compact version of the lobby state for registry storage
  # to reduce memory usage with long-lived lobbies
  defp compact_state_for_registry(state) do
    # Include all fields needed for display in the UI
    %{
      id: state.id,
      title: state.title,
      region: state.region,
      rank_required: state.rank_required,
      lobby_type: state.lobby_type,
      team_size: state.team_size,
      description: state.description,
      leader_id: state.leader_id,
      created_at: state.created_at,
      # Add chat state to compact representation
      chat_host_only: state.chat_host_only,
      chat_messages: state.chat_messages,
      # Preserve enough player information for UI display
      players: Enum.map(state.players, fn player ->
        %{
          "id" => player["id"],
          "username" => player["username"],
          "avatar" => player["avatar"],
          "discord_id" => player["discord_id"],
          "name" => player["name"],
          "connected" => player["connected"],
          "position" => player["position"],
          "joined_at" => player["joined_at"],
          "last_activity" => player["last_activity"],
          "disconnected_at" => Map.get(player, "disconnected_at")
        }
      end)
    }
  end

  # Consolidated PubSub broadcast helper for all lobby events
  defp broadcast_lobby_event(lobby, event_type, data \\ %{}) do
    # For the registry, send a compact version to save memory
    compact_lobby = compact_state_for_registry(lobby)

    # For chat-related events, make sure the chat_messages are included
    data_with_messages = if event_type in [:chat_message_sent, :chat_message_deleted, :chat_mode_changed] do
      Map.merge(data, %{chat_messages: lobby.chat_messages})
    else
      data
    end

    # First broadcast to the lobby-specific channel with full data
    PubSub.broadcast(
      @pubsub_module,
      "lobby:#{lobby.id}",
      {event_type, Map.merge(data_with_messages, %{lobby: lobby})}
    )

    # Then broadcast to the global lobbies channel with compact data
    # Optimize by only sending necessary events to the registry
    case event_type do
      :lobby_created ->
        PubSub.broadcast(@pubsub_module, "lobbies", {:lobby_created, compact_lobby})
      :lobby_closed ->
        PubSub.broadcast(@pubsub_module, "lobbies", {:lobby_closed, compact_lobby})
      :player_joined ->
        PubSub.broadcast(@pubsub_module, "lobbies", {:lobby_updated, compact_lobby})
      :player_left ->
        PubSub.broadcast(@pubsub_module, "lobbies", {:lobby_updated, compact_lobby})
      :host_migrated ->
        PubSub.broadcast(@pubsub_module, "lobbies", {:lobby_updated, compact_lobby})
      :chat_message_sent ->
        # For chat messages, we need to ensure both channels get updated
        PubSub.broadcast(@pubsub_module, "lobbies", {:lobby_updated, compact_lobby})
        PubSub.broadcast(@pubsub_module, "lobbies", {:chat_message_sent, Map.merge(data_with_messages, %{lobby: compact_lobby})})
      :chat_message_deleted ->
        # For message deletions, ensure both channels get updated
        PubSub.broadcast(@pubsub_module, "lobbies", {:lobby_updated, compact_lobby})
        PubSub.broadcast(@pubsub_module, "lobbies", {:chat_message_deleted, Map.merge(data_with_messages, %{lobby: compact_lobby})})
      :chat_mode_changed ->
        # For chat mode changes, ensure both channels get updated
        PubSub.broadcast(@pubsub_module, "lobbies", {:lobby_updated, compact_lobby})
        PubSub.broadcast(@pubsub_module, "lobbies", {:chat_mode_changed, Map.merge(data_with_messages, %{lobby: compact_lobby})})
      _ ->
        # For other events, send a general update
        PubSub.broadcast(@pubsub_module, "lobbies", {:lobby_updated, compact_lobby})
    end
  end

  # Add message handlers in handle_call

  @impl true
  def handle_call({:send_chat_message, user_id, message_text}, _from, state) do
    case LobbyChat.send_message(state, user_id, message_text) do
      {:ok, message, updated_state} ->
        # Broadcast a general update after the message-specific broadcast
        broadcast_lobby_event(updated_state, :lobby_updated)
        {:reply, {:ok, message}, updated_state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:delete_chat_message, message_id, user_id}, _from, state) do
    case LobbyChat.delete_message(state, message_id, user_id) do
      {:ok, updated_state} ->
        # Broadcast a general update after the message deletion
        broadcast_lobby_event(updated_state, :lobby_updated)
        {:reply, :ok, updated_state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:toggle_host_only_chat, user_id}, _from, state) do
    case LobbyChat.toggle_host_only_mode(state, user_id) do
      {:ok, host_only_status, updated_state} ->
        # Broadcast a general update after the mode change
        broadcast_lobby_event(updated_state, :lobby_updated)
        {:reply, {:ok, host_only_status}, updated_state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end
end
