defmodule CstopiaBackend.Lobbies.LobbyCleanup do
  @moduledoc """
  Handles cleanup of empty or inactive lobbies
  """
  use GenServer
  require Logger
  alias CstopiaBackend.Lobbies.LobbyManager
  alias CstopiaBackend.Lobbies.LobbyRegistry

  # Default thresholds for cleanup (in hours)
  @connected_player_threshold 72    # 3 days of inactivity for connected players
  @disconnected_player_threshold 12 # 12 hours for disconnected players
  @empty_lobby_threshold 1          # 1 hour for completely empty lobbies

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  # Server callbacks

  @impl true
  def init(_state) do
    # Schedule initial cleanup after 10 minutes
    Process.send_after(self(), :run_cleanup, 10 * 60 * 1000)
    {:ok, %{last_run: nil}}
  end

  @impl true
  def handle_info(:run_cleanup, state) do
    run_cleanup()

    # Schedule next cleanup - run hourly
    Process.send_after(self(), :run_cleanup, 60 * 60 * 1000)

    {:noreply, %{state | last_run: DateTime.utc_now()}}
  end

  # Implementation

  @doc """
  Removes all empty lobbies from the registry.
  This ensures no orphaned lobby processes remain.
  """
  def clean_empty_lobbies do
    now = DateTime.utc_now()
    lobbies = LobbyRegistry.get_lobbies()

    empty_lobbies = Enum.filter(lobbies, fn lobby ->
      # Check if the lobby is empty
      is_empty = Map.has_key?(lobby, :players) &&
      (lobby.players == [] || Enum.empty?(lobby.players))

      if is_empty do
        # For empty lobbies, check if they've been empty for more than threshold
        created_seconds_ago = DateTime.diff(now, lobby.created_at)
        # If created recently, keep it around briefly
        created_seconds_ago > @empty_lobby_threshold * 60 * 60
      else
        false
      end
    end)

    count = Enum.count(empty_lobbies)

    Enum.each(empty_lobbies, fn lobby ->
      Logger.info("Cleaning up empty lobby: #{lobby.id}")
      LobbyManager.delete_lobby(lobby.id)
    end)

    {:ok, count}
  end

  @doc """
  Checks and cleans inactive lobbies with different thresholds based on connection status.
  A lobby is considered inactive if:
  1. For lobbies with connected players: No activity for @connected_player_threshold hours
  2. For lobbies with only disconnected players: No activity for @disconnected_player_threshold hours
  """
  def clean_inactive_lobbies do
    now = DateTime.utc_now()
    lobbies = LobbyRegistry.get_lobbies()

    inactive_lobbies = Enum.filter(lobbies, fn lobby ->
      # Skip empty lobbies (handled by clean_empty_lobbies)
      if Map.has_key?(lobby, :players) && !Enum.empty?(lobby.players) do
        # Check if any players are connected
        any_connected = Enum.any?(lobby.players, fn player ->
          Map.get(player, "connected", false) == true
        end)

        # Choose threshold based on whether any players are connected
        threshold_hours = if any_connected do
          @connected_player_threshold
        else
          @disconnected_player_threshold
        end

        threshold_seconds = threshold_hours * 60 * 60

        # Find the most recent activity among all players
        newest_activity = Enum.reduce(lobby.players, ~U[1970-01-01 00:00:00Z], fn player, newest ->
          player_activity = Map.get(player, "last_activity")
          if player_activity && DateTime.compare(player_activity, newest) == :gt do
            player_activity
          else
            newest
          end
        end)

        # If the newest activity is older than the threshold, consider inactive
        seconds_since_newest = DateTime.diff(now, newest_activity)
        seconds_since_newest > threshold_seconds
      else
        false
      end
    end)

    count = Enum.count(inactive_lobbies)

    Enum.each(inactive_lobbies, fn lobby ->
      has_connected = Enum.any?(lobby.players, fn p -> Map.get(p, "connected", false) == true end)
      status = if has_connected, do: "connected", else: "disconnected"

      Logger.info("Cleaning up inactive lobby: #{lobby.id} with #{status} players")
      LobbyManager.delete_lobby(lobby.id)
    end)

    {:ok, count}
  end

  @doc """
  Run cleanup manually
  """
  def manual_cleanup do
    GenServer.cast(__MODULE__, :manual_cleanup)
  end

  @impl true
  def handle_cast(:manual_cleanup, state) do
    run_cleanup()
    {:noreply, %{state | last_run: DateTime.utc_now()}}
  end

  defp run_cleanup do
    {_, empty_count} = clean_empty_lobbies()
    {_, inactive_count} = clean_inactive_lobbies()

    Logger.info("Lobby cleanup completed: removed #{empty_count} empty lobbies and #{inactive_count} inactive lobbies")
  end
end
