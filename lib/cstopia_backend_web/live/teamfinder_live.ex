defmodule CstopiaBackendWeb.TeamfinderLive do
  use CstopiaBackendWeb, :live_view
  alias CstopiaBackend.Lobbies.LobbyManager
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
      end
    end

    # The current_user should already be assigned by the auth hook
    Logger.debug("Current user in TeamfinderLive: #{inspect(socket.assigns[:current_user])}")

    {:ok,
     socket
     |> assign(:lobbies, LobbyManager.list_lobbies())
     |> assign(:filter_region, "All Regions")
     |> assign(:filter_rank, "All Ranks")
     |> assign(:filter_type, "All Types")
     |> assign(:selected_lobby_type, nil)
     |> assign(:loading, false)
    }
  end

  # Handle when a user connects to the LiveView
  def handle_user_connected(user) do
    # Find all lobbies the user is in
    user_lobbies = LobbyManager.find_user_lobbies(user.id)

    # For each lobby, mark the user as reconnected and subscribe to updates
    Enum.each(user_lobbies, fn lobby ->
      LobbyManager.user_reconnected(lobby.id, user.id)
      PubSub.subscribe(CstopiaBackend.PubSub, "lobby:#{lobby.id}")
    end)
  end

  @impl true
  def terminate(_reason, socket) do
    # Handle LiveView termination - mark user as disconnected in any lobbies
    if socket.assigns[:current_user] do
      user = socket.assigns.current_user

      # Find lobbies where the user is a player
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
        |> assign(:page_title, "Lobby Details")
        |> assign(:lobby, lobby)

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Lobby not found")
        |> push_navigate(to: ~p"/teamfinder")
    end
  end

  defp apply_action(socket, :create, _params) do
    socket
    |> assign(:page_title, "Create Lobby")
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

  def handle_event("create-lobby", params, socket) do
    user = socket.assigns.current_user

    if !user do
      {:noreply, socket |> put_flash(:error, "You must be logged in to create a lobby")}
    else
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
          "avatar" => user.avatar
        }
      }

      case LobbyManager.create_lobby(lobby_params) do
        {:ok, lobby} ->
          {:noreply,
           socket
           |> put_flash(:info, "Lobby created successfully")
           |> push_navigate(to: ~p"/teamfinder/#{lobby.id}")
          }

        {:error, reason} ->
          {:noreply,
           socket
           |> put_flash(:error, "Error creating lobby: #{reason}")
          }
      end
    end
  end

  def handle_event("join-lobby", %{"id" => lobby_id}, socket) do
    user = socket.assigns.current_user

    if !user do
      {:noreply, socket |> put_flash(:error, "You must be logged in to join a lobby")}
    else
      player = %{
        "id" => user.id,
        "username" => user.username,
        "avatar" => user.avatar
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
           |> put_flash(:info, "Joined lobby successfully")
          }

        {:error, reason} ->
          {:noreply,
           socket
           |> put_flash(:error, "Error joining lobby: #{reason}")
          }
      end
    end
  end

  def handle_event("leave-lobby", %{"id" => lobby_id}, socket) do
    user = socket.assigns.current_user

    if !user do
      {:noreply, socket}
    else
      case LobbyManager.leave_lobby(lobby_id, user.id) do
        {:ok, :lobby_closed} ->
          # Unsubscribe from the lobby channel when leaving and it's closed
          if connected?(socket) do
            PubSub.unsubscribe(CstopiaBackend.PubSub, "lobby:#{lobby_id}")
          end

          {:noreply,
           socket
           |> put_flash(:info, "Lobby closed")
           |> push_navigate(to: ~p"/teamfinder")
          }

        {:ok, updated_lobby} ->
          {:noreply,
           socket
           |> assign(:lobby, updated_lobby)
           |> put_flash(:info, "Left lobby successfully")
          }

        {:error, reason} ->
          {:noreply,
           socket
           |> put_flash(:error, "Error leaving lobby: #{reason}")
          }
      end
    end
  end

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

  def handle_event("delete-lobby", %{"id" => lobby_id}, socket) do
    user = socket.assigns.current_user

    if !user do
      {:noreply, socket}
    else
      case LobbyManager.delete_lobby(lobby_id) do
        :ok ->
          {:noreply,
           socket
           |> put_flash(:info, "Lobby closed")
           |> push_navigate(to: ~p"/teamfinder")
          }

        {:error, reason} ->
          {:noreply,
           socket
           |> put_flash(:error, "Error closing lobby: #{reason}")
          }
      end
    end
  end

  # Handling lobby registry updates
  @impl true
  def handle_info({:lobbies_updated, lobbies}, socket) do
    # Apply current filters to the updated lobby list
    filtered_lobbies = apply_filters(
      lobbies,
      socket.assigns.filter_region,
      socket.assigns.filter_rank,
      socket.assigns.filter_type,
      socket.assigns.selected_lobby_type
    )

    {:noreply, assign(socket, :lobbies, filtered_lobbies)}
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

  # Keep individual lobby update handlers for specific updates

  def handle_info({:lobby_created, _lobby}, socket) do
    # We'll get an updated list from the registry, so no need to handle individually
    {:noreply, socket}
  end

  def handle_info({:lobby_closed, closed_lobby}, socket) do
    # If viewing the closed lobby, redirect to index
    if socket.assigns[:lobby] && socket.assigns.lobby.id == closed_lobby.id do
      {:noreply,
       socket
       |> put_flash(:info, "This lobby has been closed")
       |> push_navigate(to: ~p"/teamfinder")
      }
    else
      {:noreply, socket}
    end
  end

  def handle_info({:player_joined, _player, updated_lobby}, socket) do
    # Update the lobby if currently viewing it
    if socket.assigns[:lobby] && socket.assigns.lobby.id == updated_lobby.id do
      {:noreply, assign(socket, :lobby, updated_lobby)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:player_rejoined, _player, updated_lobby}, socket) do
    # Update the lobby if currently viewing it
    if socket.assigns[:lobby] && socket.assigns.lobby.id == updated_lobby.id do
      {:noreply, assign(socket, :lobby, updated_lobby)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:player_left, _player_id, updated_lobby}, socket) do
    # Update the lobby if currently viewing it
    if socket.assigns[:lobby] && socket.assigns.lobby.id == updated_lobby.id do
      {:noreply, assign(socket, :lobby, updated_lobby)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:player_kicked, _player_id, updated_lobby}, socket) do
    # Update the lobby if currently viewing it
    if socket.assigns[:lobby] && socket.assigns.lobby.id == updated_lobby.id do
      {:noreply, assign(socket, :lobby, updated_lobby)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:player_disconnected, player_id, updated_lobby}, socket) do
    # Update the lobby if currently viewing it
    if socket.assigns[:lobby] && socket.assigns.lobby.id == updated_lobby.id do
      # If the current user is viewing this lobby and another player disconnected
      socket = if socket.assigns[:current_user] && socket.assigns.current_user.id != player_id do
        assign(socket, :lobby, updated_lobby)
      else
        socket
      end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:player_reconnected, _player_id, updated_lobby}, socket) do
    # Update the lobby if currently viewing it
    if socket.assigns[:lobby] && socket.assigns.lobby.id == updated_lobby.id do
      {:noreply, assign(socket, :lobby, updated_lobby)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:host_migrated, new_leader_id, updated_lobby}, socket) do
    # Update the lobby if currently viewing it
    if socket.assigns[:lobby] && socket.assigns.lobby.id == updated_lobby.id do
      # Check if the current user is the new host
      current_user = socket.assigns.current_user

      socket = if current_user && current_user.id == new_leader_id do
        socket
        |> put_flash(:info, "You are now the lobby leader")
      else
        socket
      end

      {:noreply, assign(socket, :lobby, updated_lobby)}
    else
      {:noreply, socket}
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

  # Check if a player is in a lobby
  def player_in_lobby?(nil, _lobby), do: false
  def player_in_lobby?(_user, nil), do: false
  def player_in_lobby?(user, lobby) do
    if Map.has_key?(lobby, :players) && is_list(lobby.players) do
      Enum.any?(lobby.players, fn player ->
        is_map(player) && Map.has_key?(player, "id") && player["id"] == user.id
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

  # Get player information by ID
  def get_player_by_id(nil, _player_id), do: nil
  def get_player_by_id(_lobby, nil), do: nil
  def get_player_by_id(lobby, player_id) do
    if Map.has_key?(lobby, :players) && is_list(lobby.players) do
      Enum.find(lobby.players, fn player ->
        is_map(player) && Map.has_key?(player, "id") && player["id"] == player_id
      end)
    else
      nil
    end
  end

  # Get player join time (for displaying seniority)
  def get_player_join_time(nil), do: "unknown"
  def get_player_join_time(player) do
    joined_at = Map.get(player, "joined_at")
    if joined_at, do: relative_time(joined_at), else: "unknown"
  end

  # Check if a player is connected
  def player_is_connected?(nil), do: false
  def player_is_connected?(player) do
    Map.get(player, "connected", false) == true
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
end
