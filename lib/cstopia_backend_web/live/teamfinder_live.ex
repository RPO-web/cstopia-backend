defmodule CstopiaBackendWeb.TeamfinderLive do
  use CstopiaBackendWeb, :live_view
  alias CstopiaBackend.Lobbies.LobbyManager
  alias CstopiaBackend.Lobbies.Presence
  alias Phoenix.PubSub
  require Logger

  # Embed template files
  embed_templates "teamfinder_live/*"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to the lobby registry for all lobby updates
      PubSub.subscribe(CstopiaBackend.PubSub, "lobby_registry")

      # If user is logged in, check if they're in any lobbies and subscribe to each
      if socket.assigns[:current_user] do
        handle_user_connected(socket.assigns.current_user)

        # Track user presence on teamfinder pages
        Presence.subscribe_to_lobbies_presence()
        Presence.track_user_in_lobbies(socket.assigns.current_user.id, %{
          username: socket.assigns.current_user.username,
          avatar: socket.assigns.current_user.avatar,
          discord_id: socket.assigns.current_user.discord_id
        })
      end

      # Start a timer to refresh the disconnect countdown every second
      :timer.send_interval(1000, self(), :update_disconnect_timers)
    end

    # The current_user should already be assigned by the auth hook
    Logger.debug("Current user in TeamfinderLive: #{inspect(socket.assigns[:current_user])}")

    # Get the list of online users via Presence
    online_users = Presence.list_users_in_lobbies()
    online_count = Presence.count_users_in_lobbies()

    {:ok,
     socket
     |> assign(:lobbies, LobbyManager.list_lobbies())
     |> assign(:filter_region, "All Regions")
     |> assign(:filter_rank, "All Ranks")
     |> assign(:filter_type, "All Types")
     |> assign(:selected_lobby_type, nil)
     |> assign(:loading, false)
     |> assign(:show_team_conflict_modal, false)
     |> assign(:joining_lobby_id, nil)
     |> assign(:current_lobby, nil)
     |> assign(:is_creating_lobby, false)
     |> assign(:create_lobby_params, nil)
     |> assign(:online_users, online_users)
     |> assign(:online_count, online_count)
    }
  end

  # Handle when a user connects to the LiveView
  def handle_user_connected(user) do
    # Find all lobbies the user is in - using optimized lookup
    user_lobbies = LobbyManager.find_user_lobbies(user.id)

    # For each lobby, mark the user as reconnected and subscribe to updates
    Enum.each(user_lobbies, fn lobby ->
      LobbyManager.user_reconnected(lobby.id, user.id)
      PubSub.subscribe(CstopiaBackend.PubSub, "lobby:#{lobby.id}")
    end)
  end

  # Handle presence updates
  @impl true
  def handle_info(%{event: "presence_diff"}, socket) do
    online_users = Presence.list_users_in_lobbies()
    online_count = Presence.count_users_in_lobbies()

    {:noreply,
     socket
     |> assign(:online_users, online_users)
     |> assign(:online_count, online_count)
    }
  end

  @impl true
  def terminate(_reason, socket) do
    # Handle LiveView termination - mark user as disconnected in any lobbies
    if socket.assigns[:current_user] do
      user = socket.assigns.current_user

      # Find lobbies where the user is a player - using optimized lookup
      user_lobbies = LobbyManager.find_user_lobbies(user.id)

      # Mark user as disconnected in each lobby
      Enum.each(user_lobbies, fn lobby ->
        Logger.info("User #{user.id} disconnected from lobby #{lobby.id}, starting inactivity timer")
        LobbyManager.user_disconnected(lobby.id, user.id)
      end)
    end

    :ok
  end

  @impl true
  def render(assigns) do
    case assigns.live_action do
      :index -> index(assigns)
      :view -> view(assigns)
      :create -> create(assigns)
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Team Finder")
  end

  defp apply_action(socket, :view, %{"id" => id}) do
    case LobbyManager.get_lobby(id) do
      {:ok, lobby} ->
        if connected?(socket) do
          # Subscribe to this specific lobby for real-time updates
          PubSub.subscribe(CstopiaBackend.PubSub, "lobby:#{id}")

          # Update user activity in the lobby
          if socket.assigns[:current_user] do
            LobbyManager.update_user_activity(id, socket.assigns.current_user.id)
          end
        end

        socket
        |> assign(:page_title, "Team Details")
        |> assign(:lobby, lobby)

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Sorry, this team does not exist or has been closed.")
        |> push_navigate(to: ~p"/teamfinder")
    end
  end

  defp apply_action(socket, :create, _params) do
    # Check if user is already in a lobby
    user = socket.assigns[:current_user]

    if !user do
      # No user logged in, show an error and redirect to login
      socket
      |> put_flash(:error, "You must be logged in to create a team.")
      |> push_navigate(to: ~p"/teamfinder")
    else
      # Use optimized lookup to find user's lobbies
      user_lobbies = LobbyManager.find_user_lobbies(user.id)

      if !Enum.empty?(user_lobbies) do
        current_lobby = List.first(user_lobbies)

        # User is in a lobby, redirect to that lobby
        socket
        |> put_flash(:error, "You are already in a team. Please leave your current team before creating a new one.")
        |> push_navigate(to: ~p"/teamfinder/#{current_lobby.id}")
      else
        # User is not in a lobby, show the create form
        socket
        |> assign(:page_title, "Create Team")
      end
    end
  end

  @impl true
  def handle_event("filter-lobbies", %{"region" => region, "rank" => rank, "type" => type}, socket) do
    socket = assign(socket, :loading, true)

    # Create a more detailed filter function to run on the client rather than fetching all lobbies
    filter_fn = fn lobby ->
      (region == "All Regions" || lobby.region == region) &&
      (rank == "All Ranks" || lobby.rank_required == rank) &&
      (type == "All Types" || lobby.lobby_type == type)
    end

    # Filter the already loaded lobbies in memory
    filtered_lobbies = socket.assigns.lobbies
                      |> Enum.filter(filter_fn)

    {:noreply,
     socket
     |> assign(:filter_region, region)
     |> assign(:filter_rank, rank)
     |> assign(:filter_type, type)
     |> assign(:lobbies, filtered_lobbies)
     |> assign(:loading, false)
    }
  end

  @impl true
  def handle_event("select-lobby-type", %{"type" => type}, socket) do
    selected = if socket.assigns.selected_lobby_type == type, do: nil, else: type

    # Get the base list of lobbies, already filtered by region and rank
    all_lobbies = LobbyManager.list_lobbies()

    # Apply existing filters
    region = socket.assigns.filter_region
    rank = socket.assigns.filter_rank

    filtered_lobbies = all_lobbies
                      |> Enum.filter(fn lobby ->
                        region_match = region == "All Regions" || lobby.region == region
                        rank_match = rank == "All Ranks" || lobby.rank_required == rank
                        type_match = selected == nil || lobby.lobby_type == selected

                        region_match && rank_match && type_match
                      end)

    {:noreply,
     socket
     |> assign(:selected_lobby_type, selected)
     |> assign(:lobbies, filtered_lobbies)
    }
  end

  @impl true
  def handle_event("create-lobby", params, socket) do
    Logger.debug("Create lobby event received with params: #{inspect(params)}")
    user = socket.assigns.current_user
    Logger.debug("Current user: #{inspect(user)}")

    if !user do
      Logger.debug("No user found in socket assigns")
      {:noreply, socket |> put_flash(:error, "You must be logged in to create a team")}
    else
      # Check if user is already in a lobby - using optimized lookup
      user_lobbies = LobbyManager.find_user_lobbies(user.id)
      Logger.debug("User lobbies: #{inspect(user_lobbies)}")

      if !Enum.empty?(user_lobbies) do
        current_lobby = List.first(user_lobbies)
        Logger.debug("User is already in lobby: #{inspect(current_lobby.id)}")

        # Store the create params for use after confirmation
        {:noreply,
         socket
         |> assign(:create_lobby_params, params)
         |> assign(:current_lobby, current_lobby)
         |> assign(:show_team_conflict_modal, true)
         |> assign(:is_creating_lobby, true)
        }
      else
        Logger.debug("Proceeding to create lobby")
        # User is not in any lobby, proceed with creating
        create_lobby(params, user, socket)
      end
    end
  end

  @impl true
  def handle_event("confirm-create-leave", _params, socket) do
    user = socket.assigns.current_user
    current_lobby = socket.assigns.current_lobby
    params = socket.assigns.create_lobby_params

    # First leave the current lobby
    case LobbyManager.leave_lobby(current_lobby.id, user.id) do
      {:ok, _} ->
        # Now create the new lobby
        create_lobby(params, user, socket)

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:show_team_conflict_modal, false)
         |> assign(:is_creating_lobby, false)
         |> assign(:create_lobby_params, nil)
         |> put_flash(:error, "Error leaving current team: #{reason}")
        }
    end
  end

  @impl true
  def handle_event("join-lobby", %{"id" => lobby_id}, socket) do
    user = socket.assigns.current_user

    if !user do
      {:noreply, socket |> put_flash(:error, "You must be logged in to join a team")}
    else
      # Find if the user is already in any lobbies - using optimized lookup
      user_lobbies = LobbyManager.find_user_lobbies(user.id)

      # If user is already in a different lobby, show the confirmation modal
      if Enum.any?(user_lobbies, fn l -> l.id != lobby_id end) do
        current_lobby = List.first(user_lobbies)

        {:noreply,
         socket
         |> assign(:joining_lobby_id, lobby_id)
         |> assign(:current_lobby, current_lobby)
         |> assign(:show_team_conflict_modal, true)
        }
      else
        # User is not in any other lobby, proceed with joining
        join_lobby(lobby_id, user, socket)
      end
    end
  end

  @impl true
  def handle_event("confirm-leave-join", %{"lobby_id" => new_lobby_id}, socket) do
    user = socket.assigns.current_user
    current_lobby = socket.assigns.current_lobby

    # First leave the current lobby
    case LobbyManager.leave_lobby(current_lobby.id, user.id) do
      {:ok, _} ->
        # Now join the new lobby
        join_lobby(new_lobby_id, user, socket)

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:show_team_conflict_modal, false)
         |> put_flash(:error, "Error leaving current team: #{reason}")
        }
    end
  end

  @impl true
  def handle_event("leave-lobby", %{"id" => lobby_id}, socket) do
    user = socket.assigns.current_user

    if !user do
      {:noreply, socket |> put_flash(:error, "You must be logged in to leave a team")}
    else
      case LobbyManager.leave_lobby(lobby_id, user.id) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Left team successfully")
           |> push_navigate(to: ~p"/teamfinder")}

        {:error, reason} ->
          {:noreply,
           socket
           |> put_flash(:error, "Error leaving team: #{reason}")}
      end
    end
  end

  @impl true
  def handle_event("transfer-leadership", %{"id" => lobby_id, "player_id" => new_leader_id}, socket) do
    user = socket.assigns.current_user

    if !user do
      {:noreply, socket |> put_flash(:error, "You must be logged in to perform this action")}
    else
      case LobbyManager.transfer_leadership(lobby_id, user.id, new_leader_id) do
        {:ok, updated_lobby} ->
          {:noreply,
           socket
           |> assign(:lobby, updated_lobby)
           |> put_flash(:info, "Leadership transferred successfully")}

        {:error, :not_authorized} ->
          {:noreply,
           socket
           |> put_flash(:error, "Only the team leader can transfer leadership")}

        {:error, reason} ->
          {:noreply,
           socket
           |> put_flash(:error, "Error transferring leadership: #{reason}")}
      end
    end
  end

  @impl true
  def handle_event("update-player-positions", %{"positions" => positions}, socket) do
    user = socket.assigns.current_user
    lobby = socket.assigns.lobby

    if !user || !lobby do
      {:noreply, socket}
    else
      # Only the leader can reorder players
      if user.id == lobby.leader_id do
        # Convert the positions from strings to integers and create a map of player_id -> position
        player_order = positions
                       |> Enum.map(fn {player_id, position} -> {player_id, String.to_integer(position)} end)
                       |> Enum.into(%{})

        case LobbyManager.update_player_positions(lobby.id, user.id, player_order) do
          {:ok, updated_lobby} ->
            {:noreply, assign(socket, :lobby, updated_lobby)}
          {:error, _reason} ->
            {:noreply, socket}
        end
      else
        {:noreply, socket}
      end
    end
  end

  @impl true
  def handle_event("kick-player", %{"id" => lobby_id, "player_id" => player_id, "should_block" => should_block}, socket) do
    user = socket.assigns.current_user

    if !user do
      {:noreply, socket |> put_flash(:error, "You must be logged in to perform this action")}
    else
      # Convert string "true"/"false" to boolean
      should_block_bool = should_block == "true"

      case LobbyManager.kick_player(lobby_id, player_id, user.id, should_block_bool) do
        {:ok, updated_lobby} ->
          action = if should_block_bool, do: "banned", else: "kicked"

          {:noreply,
           socket
           |> assign(:lobby, updated_lobby)
           |> put_flash(:info, "Player #{action} successfully")
          }

        {:error, :not_authorized} ->
          {:noreply,
           socket
           |> put_flash(:error, "Only the lobby leader can kick players")
          }

        {:error, reason} ->
          {:noreply,
           socket
           |> put_flash(:error, "Error kicking player: #{reason}")
          }
      end
    end
  end

  @impl true
  def handle_event("delete-team", %{"id" => lobby_id}, socket) do
    user = socket.assigns.current_user

    if !user do
      {:noreply, socket}
    else
      case LobbyManager.delete_lobby(lobby_id) do
        :ok ->
          {:noreply,
           socket
           |> put_flash(:info, "Team closed")
           |> push_navigate(to: ~p"/teamfinder")
          }

        {:error, reason} ->
          {:noreply,
           socket
           |> put_flash(:error, "Error closing team: #{reason}")
          }
      end
    end
  end

  # For backward compatibility
  def handle_event("delete-lobby", params, socket) do
    handle_event("delete-team", params, socket)
  end

  @impl true
  def handle_info({:lobby_created, lobby}, socket) do
    # Add to the list of lobbies and ensure it has the right structure
    updated_lobbies = [ensure_map_keys(lobby) | socket.assigns.lobbies]
    {:noreply, assign(socket, :lobbies, updated_lobbies)}
  end

  @impl true
  def handle_info({:lobby_closed, %{lobby: lobby}}, socket) do
    # Handle the new message format with nested lobby field
    updated_lobbies = Enum.reject(socket.assigns.lobbies, fn l -> l.id == lobby.id end)

    # If the user was in this lobby, navigate back to the index
    current_lobby = socket.assigns[:lobby]
    socket = if current_lobby && current_lobby.id == lobby.id do
      push_navigate(socket, to: ~p"/teamfinder")
    else
      socket
    end

    {:noreply, assign(socket, :lobbies, updated_lobbies)}
  end

  @impl true
  def handle_info({:lobby_closed, lobby}, socket) when is_map(lobby) and is_map_key(lobby, :id) do
    # Handle format where lobby is sent directly
    updated_lobbies = Enum.reject(socket.assigns.lobbies, fn l -> l.id == lobby.id end)

    # If the user was in this lobby, navigate back to the index
    current_lobby = socket.assigns[:lobby]
    socket = if current_lobby && current_lobby.id == lobby.id do
      push_navigate(socket, to: ~p"/teamfinder")
    else
      socket
    end

    {:noreply, assign(socket, :lobbies, updated_lobbies)}
  end

  @impl true
  def handle_info({:lobby_closed, lobby_id}, socket) when is_binary(lobby_id) do
    # Handle format where only lobby_id is sent
    updated_lobbies = Enum.reject(socket.assigns.lobbies, fn l -> l.id == lobby_id end)

    # If the user was in this lobby, navigate back to the index
    current_lobby = socket.assigns[:lobby]
    socket = if current_lobby && current_lobby.id == lobby_id do
      socket
      |> put_flash(:info, "This team has been closed.")
      |> push_navigate(to: ~p"/teamfinder")
    else
      socket
    end

    {:noreply, assign(socket, :lobbies, updated_lobbies)}
  end

  @impl true
  def handle_info({:lobbies_updated, lobbies}, socket) do
    # Ensure all lobbies have proper map structure
    lobbies_with_keys = Enum.map(lobbies, &ensure_map_keys/1)
    {:noreply, assign(socket, :lobbies, lobbies_with_keys)}
  end

  # Add handler for lobby_updated event with the new message format
  @impl true
  def handle_info({:lobby_updated, %{lobby: lobby}}, socket) do
    socket = update_current_lobby(socket, lobby)
    {:noreply, socket}
  end

  # Or for the old format
  @impl true
  def handle_info({:lobby_updated, updated_lobby}, socket) do
    socket = update_current_lobby(socket, updated_lobby)
    {:noreply, socket}
  end

  # Handle individual lobby events with new message format
  @impl true
  def handle_info({:player_joined, %{player: player, lobby: lobby}}, socket) do
    socket = update_current_lobby(socket, lobby)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:player_left, %{player_id: player_id, lobby: lobby}}, socket) do
    # Update the current lobby if this is the one we're viewing
    socket = update_current_lobby(socket, lobby)

    # If the current user left, navigate back to the lobby list
    if socket.assigns[:current_user] && socket.assigns.current_user.id == player_id do
      {:noreply, push_navigate(socket, to: ~p"/teamfinder")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:player_kicked, %{player_id: player_id, lobby: lobby}}, socket) do
    # Handle similar to player_left but with a different message
    socket = update_current_lobby(socket, lobby)

    if socket.assigns[:current_user] && socket.assigns.current_user.id == player_id do
      socket = socket
               |> put_flash(:error, "You have been kicked from the team.")
               |> push_navigate(to: ~p"/teamfinder")
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:host_migrated, %{new_leader_id: new_leader_id, lobby: lobby}}, socket) do
    socket = update_current_lobby(socket, lobby)

    # If current user is the new leader, show a notification
    if socket.assigns[:current_user] && socket.assigns.current_user.id == new_leader_id do
      socket = put_flash(socket, :info, "You are now the team leader.")
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:leadership_transferred, %{new_leader_id: new_leader_id, lobby: lobby}}, socket) do
    socket = update_current_lobby(socket, lobby)

    # If current user is the new leader, show a notification
    if socket.assigns[:current_user] && socket.assigns.current_user.id == new_leader_id do
      socket = put_flash(socket, :info, "Leadership has been transferred to you.")
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:player_disconnected, %{player_id: player_id, lobby: lobby}}, socket) do
    socket = update_current_lobby(socket, lobby)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:player_reconnected, %{player_id: player_id, lobby: lobby}}, socket) do
    socket = update_current_lobby(socket, lobby)
    {:noreply, socket}
  end

  # Handle presence updates
  @impl true
  def handle_info(%{event: "presence_diff"}, socket) do
    online_users = Presence.list_users_in_lobbies()
    online_count = Presence.count_users_in_lobbies()

    {:noreply,
     socket
     |> assign(:online_users, online_users)
     |> assign(:online_count, online_count)
    }
  end

  # Helper to update the current lobby if it matches the updated lobby
  defp update_current_lobby(socket, lobby) do
    if socket.assigns[:lobby] && socket.assigns.lobby.id == lobby.id do
      # Make sure we're using the most complete version of the lobby data
      updated_lobby = cond do
        # If the incoming lobby has chat_messages and the current doesn't, use incoming
        !Map.has_key?(socket.assigns.lobby, :chat_messages) && Map.has_key?(lobby, :chat_messages) ->
          lobby

        # If both have chat_messages, but incoming is empty and current is not, preserve current
        Map.has_key?(socket.assigns.lobby, :chat_messages) &&
        Map.has_key?(lobby, :chat_messages) &&
        Enum.empty?(lobby.chat_messages) &&
        !Enum.empty?(socket.assigns.lobby.chat_messages) ->
          socket.assigns.lobby

        # If incoming has chat_host_only set but current doesn't, use incoming
        !Map.has_key?(socket.assigns.lobby, :chat_host_only) && Map.has_key?(lobby, :chat_host_only) ->
          lobby

        # Default: use incoming lobby data
        true ->
          lobby
      end

      assign(socket, :lobby, updated_lobby)
    else
      socket
    end
  end

  @impl true
  def handle_info(:update_disconnect_timers, socket) do
    # Force the view to re-render and update all disconnect timers
    {:noreply, socket}
  end

  # Handle all other messages (including lobby updates from PubSub)
  @impl true
  def handle_info(msg, socket) do
    case socket.assigns.live_action do
      :index ->
        # Handle lobby updates
        case msg do
          # Keep existing message handlers
          {:lobby_created, lobby} ->
            {:noreply, assign(socket, :lobbies, [lobby | socket.assigns.lobbies])}

          {:lobby_updated, updated_lobby} ->
            updated_lobbies = Enum.map(socket.assigns.lobbies, fn lobby ->
              if lobby.id == updated_lobby.id, do: updated_lobby, else: lobby
            end)
            {:noreply, assign(socket, :lobbies, updated_lobbies)}

          # The more specific handlers will catch most cases, this is just a fallback
          {:lobby_closed, data} ->
            # Extract lobby_id depending on the format of data
            lobby_id = cond do
              is_map(data) && Map.has_key?(data, :id) -> data.id
              is_map(data) && Map.has_key?(data, :lobby) && is_map(data.lobby) -> data.lobby.id
              is_binary(data) -> data
              true -> nil
            end

            if lobby_id do
              filtered_lobbies = Enum.reject(socket.assigns.lobbies, fn lobby -> lobby.id == lobby_id end)
              {:noreply, assign(socket, :lobbies, filtered_lobbies)}
            else
              # If we can't determine the lobby_id, just pass it through
              {:noreply, socket}
            end

          _ ->
            {:noreply, socket}
        end

      :view ->
        # Handle specific lobby updates in the view page
        case msg do
          {:lobby_updated, updated_lobby} ->
            if socket.assigns.lobby.id == updated_lobby.id do
              {:noreply, assign(socket, :lobby, updated_lobby)}
            else
              {:noreply, socket}
            end

          # Handle different formats of lobby_closed messages
          {:lobby_closed, data} ->
            # Extract lobby_id depending on the format of data
            lobby_id = cond do
              is_map(data) && Map.has_key?(data, :id) -> data.id
              is_map(data) && Map.has_key?(data, :lobby) && is_map(data.lobby) -> data.lobby.id
              is_binary(data) -> data
              true -> nil
            end

            if lobby_id && socket.assigns.lobby.id == lobby_id do
              {:noreply,
               socket
               |> put_flash(:error, "This team has been closed by the leader.")
               |> push_navigate(to: ~p"/teamfinder")
              }
            else
              {:noreply, socket}
            end

          _ ->
            {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # Helper function to create a lobby
  defp create_lobby(params, user, socket) do
    Logger.debug("Creating lobby with params: #{inspect(params)}")

    lobby_params = %{
      "title" => params["title"],
      "region" => params["region"],
      "rank_required" => params["rank_required"],
      "lobby_type" => params["lobby_type"],
      "team_size" => params["team_size"],
      "description" => params["description"],
      "creator" => %{
        "id" => user.id,
        "username" => user.username,
        "avatar" => user.avatar,
        "discord_id" => user.discord_id
      }
    }
    Logger.debug("Processed lobby params: #{inspect(lobby_params)}")

    case LobbyManager.create_lobby(lobby_params) do
      {:ok, lobby} ->
        Logger.debug("Lobby created successfully with ID: #{lobby.id}")
        {:noreply,
         socket
         |> assign(:show_team_conflict_modal, false)
         |> assign(:is_creating_lobby, false)
         |> assign(:create_lobby_params, nil)
         |> put_flash(:info, "Team created successfully")
         |> push_navigate(to: ~p"/teamfinder/#{lobby.id}")
        }

      {:error, reason} ->
        Logger.error("Error creating lobby: #{inspect(reason)}")
        {:noreply,
         socket
         |> assign(:show_team_conflict_modal, false)
         |> assign(:is_creating_lobby, false)
         |> assign(:create_lobby_params, nil)
         |> put_flash(:error, "Error creating team: #{reason}")
        }
    end
  end

  # Format relative time for display
  def relative_time(nil), do: "unknown time"
  def relative_time(datetime) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 60 ->
        "just now"
      diff < 3600 ->
        "#{div(diff, 60)} minute(s) ago"
      diff < 86400 ->
        "#{div(diff, 3600)} hour(s) ago"
      true ->
        "#{div(diff, 86400)} day(s) ago"
    end
  end

  # Format time until a future event
  def time_until_removal(nil), do: nil
  def time_until_removal(timestamp) do
    now = DateTime.utc_now()
    # Disconnected users get 5 minutes (300 seconds) before removal
    removal_time = DateTime.add(timestamp, 300, :second)
    remaining_seconds = max(0, DateTime.diff(removal_time, now, :second))

    cond do
      remaining_seconds <= 0 ->
        "removal imminent"
      remaining_seconds < 60 ->
        "#{remaining_seconds}s left"
      remaining_seconds < 300 ->
        minutes = div(remaining_seconds, 60)
        seconds = rem(remaining_seconds, 60)
        "#{minutes}m #{seconds}s left"
      true ->
        "#{div(remaining_seconds, 60)}m left"
    end
  end

  # Get the remaining time for a disconnected user
  def get_disconnect_remaining_time(nil), do: nil
  def get_disconnect_remaining_time(player) do
    if !player_is_connected?(player) && Map.has_key?(player, "disconnected_at") do
      time_until_removal(player["disconnected_at"])
    else
      nil
    end
  end

  # Get player information by ID
  def get_player_by_id(nil, _player_id), do: nil
  def get_player_by_id(_lobby, nil), do: nil
  def get_player_by_id(lobby, player_id) do
    if Map.has_key?(lobby, :players) && is_list(lobby.players) do
      Enum.find(lobby.players, fn player ->
        is_map(player) &&
        ((Map.has_key?(player, "id") && player["id"] == player_id) ||
         (Map.has_key?(player, :id) && player.id == player_id))
      end)
    else
      nil
    end
  end

  # Get player join time (for displaying seniority)
  def get_player_join_time(nil), do: "unknown"
  def get_player_join_time(player) do
    joined_at = Map.get(player, "joined_at") || Map.get(player, :joined_at)
    if joined_at, do: relative_time(joined_at), else: "unknown"
  end

  # Check if a player is connected
  def player_is_connected?(nil), do: false
  def player_is_connected?(player) do
    (Map.get(player, "connected") || Map.get(player, :connected)) == true
  end

  # Format the connection status for display
  def format_connection_status(nil), do: "Unknown"
  def format_connection_status(player) do
    if player_is_connected?(player) do
      "Online"
    else
      "Offline"
    end
  end

  # Check if a player is in a lobby
  def player_in_lobby?(nil, _lobby), do: false
  def player_in_lobby?(_user, nil), do: false
  def player_in_lobby?(user, lobby) do
    if Map.has_key?(lobby, :players) && is_list(lobby.players) do
      Enum.any?(lobby.players, fn player ->
        is_map(player) &&
        ((Map.has_key?(player, "id") && player["id"] == user.id) ||
         (Map.has_key?(player, :id) && player.id == user.id))
      end)
    else
      false
    end
  end

  # Check if a player is the lobby leader
  def player_is_leader?(nil, _lobby), do: false
  def player_is_leader?(_user, nil), do: false
  def player_is_leader?(user, lobby) do
    Map.has_key?(lobby, :leader_id) && user.id == lobby.leader_id
  end

  # Helper to apply filters consistently
  defp apply_filters(lobbies, region, rank, type, selected_type) do
    lobbies
    |> filter_by_region(region)
    |> filter_by_rank(rank)
    |> filter_by_type(type)
    |> filter_by_selected_type(selected_type)
  end

  defp filter_by_region(lobbies, "All Regions"), do: lobbies
  defp filter_by_region(lobbies, region), do:
    Enum.filter(lobbies, &(&1.region == region))

  defp filter_by_rank(lobbies, "All Ranks"), do: lobbies
  defp filter_by_rank(lobbies, rank), do:
    Enum.filter(lobbies, &(&1.rank_required == rank))

  defp filter_by_type(lobbies, "All Types"), do: lobbies
  defp filter_by_type(lobbies, type), do:
    Enum.filter(lobbies, &(&1.lobby_type == type))

  defp filter_by_selected_type(lobbies, nil), do: lobbies
  defp filter_by_selected_type(lobbies, selected_type), do:
    Enum.filter(lobbies, &(&1.lobby_type == selected_type))

  # Helper function to join a lobby
  defp join_lobby(lobby_id, user, socket) do
    player = %{
      "id" => user.id,
      "username" => user.username,
      "avatar" => user.avatar,
      "discord_id" => user.discord_id
    }

    case LobbyManager.join_lobby(lobby_id, player) do
      {:ok, updated_lobby} ->
        # Subscribe to the lobby channel when joining
        if connected?(socket) do
          PubSub.subscribe(CstopiaBackend.PubSub, "lobby:#{lobby_id}")
        end

        {:noreply,
         socket
         |> assign(:lobby, updated_lobby)
         |> assign(:show_team_conflict_modal, false)
         |> put_flash(:info, "Joined team successfully")
        }

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:show_team_conflict_modal, false)
         |> put_flash(:error, "Error joining team: #{reason}")
        }
    end
  end

  # Ensure lobby maps have atom keys for proper access in templates
  defp ensure_map_keys(lobby) when is_map(lobby) do
    if Map.has_key?(lobby, :id) do
      # Already has atom keys
      lobby
    else
      # Convert string keys to atom keys for top-level keys
      Enum.reduce(lobby, %{}, fn {k, v}, acc ->
        try do
          atom_key = String.to_existing_atom(k)
          Map.put(acc, atom_key, v)
        rescue
          # If the atom doesn't exist, keep it as a string key
          _ -> Map.put(acc, k, v)
        end
      end)
    end
  end
  defp ensure_map_keys(other), do: other

  # Handle chat message events
  @impl true
  def handle_event("send_chat_message", %{"message" => message}, socket) do
    if socket.assigns[:current_user] && socket.assigns[:lobby] do
      user_id = socket.assigns.current_user.id
      lobby_id = socket.assigns.lobby.id

      case LobbyManager.send_chat_message(lobby_id, user_id, message) do
        {:ok, _message} ->
          {:noreply, socket}

        {:error, :host_only_mode} ->
          {:noreply, socket |> put_flash(:error, "Only the host can send messages in host-only mode")}

        {:error, :invalid_message} ->
          {:noreply, socket |> put_flash(:error, "Invalid message content")}

        {:error, _} ->
          {:noreply, socket |> put_flash(:error, "Failed to send message")}
      end
    else
      {:noreply, socket |> put_flash(:error, "You must be logged in and in a lobby to send messages")}
    end
  end

  @impl true
  def handle_event("delete_chat_message", %{"message_id" => message_id}, socket) do
    if socket.assigns[:current_user] && socket.assigns[:lobby] do
      user_id = socket.assigns.current_user.id
      lobby_id = socket.assigns.lobby.id

      # First provide immediate visual feedback by removing the message locally
      # This gives a responsive feel while the server processes the deletion
      current_messages = socket.assigns.lobby.chat_messages || []
      updated_messages = Enum.reject(current_messages, fn msg -> msg.id == message_id end)
      updated_lobby = Map.put(socket.assigns.lobby, :chat_messages, updated_messages)

      # Push event to client to handle the deletion in JS (more responsive)
      socket =
        socket
        |> assign(:lobby, updated_lobby)
        |> push_event("chat_message_deleted", %{message_id: message_id})

      # Then send the actual delete request to the server
      spawn(fn ->
        LobbyManager.delete_chat_message(lobby_id, message_id, user_id)
      end)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_host_only_chat", _params, socket) do
    if socket.assigns[:current_user] && socket.assigns[:lobby] do
      user_id = socket.assigns.current_user.id
      lobby_id = socket.assigns.lobby.id

      case LobbyManager.toggle_host_only_chat(lobby_id, user_id) do
        {:ok, host_only} ->
          # Don't need to update the socket here since the broadcast will update all clients
          # The host who triggered this will see the change immediately
          status = if host_only, do: "enabled", else: "disabled"
          {:noreply, put_flash(socket, :info, "Host-only mode #{status}")}

        {:error, :not_authorized} ->
          {:noreply, socket |> put_flash(:error, "Only the host can change chat mode")}

        {:error, _} ->
          {:noreply, socket |> put_flash(:error, "Failed to toggle host-only mode")}
      end
    else
      {:noreply, socket}
    end
  end

  # Handle chat-related PubSub messages
  @impl true
  def handle_info({:chat_message_sent, %{lobby: updated_lobby, message: message}}, socket) do
    # Make sure we update the lobby with the new message
    socket =
      if socket.assigns[:lobby] && socket.assigns.lobby.id == updated_lobby.id do
        # Add the new message to the existing messages if needed
        updated_messages = case {socket.assigns.lobby.chat_messages, updated_lobby.chat_messages} do
          {existing, []} when is_list(existing) and length(existing) > 0 ->
            # If incoming lobby has empty messages but we have messages, keep ours and add the new one
            [message | existing]
          _ ->
            # Otherwise use the incoming messages
            updated_lobby.chat_messages
        end

        # Create a merged lobby with complete chat messages
        merged_lobby = Map.put(updated_lobby, :chat_messages, updated_messages)
        assign(socket, :lobby, merged_lobby)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:chat_message_deleted, %{message_id: message_id} = payload}, socket) do
    # Get the current chat messages and lobby state
    current_lobby = socket.assigns[:lobby]

    if current_lobby && current_lobby.id == get_in(payload, [:lobby, :id]) do
      # Get the updated messages from the payload or update the current messages
      updated_lobby =
        if updated_lobby_data = get_in(payload, [:lobby]) do
          # Use the lobby directly from the payload if available
          updated_lobby_data
        else
          # Get updated messages or mark the message as deleted
          updated_messages =
            if chat_messages = get_in(payload, [:chat_messages]) do
              # Use the messages directly from the payload if available
              chat_messages
            else
              # Find and mark the message as deleted
              Enum.map(current_lobby.chat_messages || [], fn msg ->
                if msg.id == message_id do
                  Map.merge(msg, %{deleted: true, content: "Message deleted"})
                else
                  msg
                end
              end)
            end

          # Create a new lobby state with the updated messages
          Map.put(current_lobby, :chat_messages, updated_messages)
        end

      # Send a JavaScript event to notify the client about the deletion
      socket =
        socket
        |> assign(:lobby, updated_lobby)
        |> push_event("chat_message_deleted", %{message_id: message_id})

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:chat_mode_changed, %{lobby: updated_lobby, host_only: host_only, chat_messages: chat_messages}}, socket) do
    # Make sure we update the lobby with both the mode change and messages
    socket =
      if socket.assigns[:lobby] && socket.assigns.lobby.id == updated_lobby.id do
        # Preserve chat messages if needed
        updated_lobby = if updated_lobby.chat_messages == [] && socket.assigns.lobby.chat_messages != [] do
          Map.put(updated_lobby, :chat_messages, chat_messages || socket.assigns.lobby.chat_messages)
        else
          updated_lobby
        end

        # Add a flash message to indicate the mode change to all users
        socket =
          if host_only do
            socket
            |> assign(:lobby, updated_lobby)
            |> put_flash(:info, "Chat is now in host-only mode")
          else
            socket
            |> assign(:lobby, updated_lobby)
            |> put_flash(:info, "Chat is now open to all team members")
          end

        socket
      else
        socket
      end

    {:noreply, socket}
  end
end
