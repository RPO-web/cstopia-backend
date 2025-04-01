defmodule CstopiaBackend.Lobbies.LobbyCleanup do
  @moduledoc """
  Handles cleanup of empty or inactive lobbies
  """
  use GenServer
  require Logger
  alias CstopiaBackend.Lobbies.LobbyManager
  alias CstopiaBackend.Lobbies.LobbyRegistry

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

    # Schedule next cleanup
    Process.send_after(self(), :run_cleanup, 60 * 60 * 1000)

    {:noreply, %{state | last_run: DateTime.utc_now()}}
  end

  # Implementation

  @doc """
  Removes all empty lobbies from the registry.
  This ensures no orphaned lobby processes remain.
  """
  def clean_empty_lobbies do
    lobbies = LobbyRegistry.get_lobbies()

    empty_lobbies = Enum.filter(lobbies, fn lobby ->
      Map.has_key?(lobby, :players) &&
      (lobby.players == [] || Enum.empty?(lobby.players))
    end)

    count = Enum.count(empty_lobbies)

    Enum.each(empty_lobbies, fn lobby ->
      Logger.info("Cleaning up empty lobby: #{lobby.id}")
      LobbyManager.delete_lobby(lobby.id)
    end)

    {:ok, count}
  end

  @doc """
  Checks and cleans inactive lobbies.
  A lobby is considered inactive if:
  1. It has been created more than `hours_threshold` hours ago
  2. No user activity has been recorded in the last `hours_threshold` hours
  """
  def clean_inactive_lobbies(hours_threshold \\ 24) do
    now = DateTime.utc_now()
    threshold_seconds = hours_threshold * 60 * 60

    lobbies = LobbyRegistry.get_lobbies()

    inactive_lobbies = Enum.filter(lobbies, fn lobby ->
      created_seconds_ago = DateTime.diff(now, lobby.created_at)

      # Check if lobby is old enough
      if created_seconds_ago > threshold_seconds do
        # Check for any recent player activity
        recent_activity = Enum.any?(lobby.players, fn player ->
          last_activity = player["last_activity"]
          # Some players might not have last_activity field
          if last_activity do
            seconds_since_activity = DateTime.diff(now, last_activity)
            seconds_since_activity < threshold_seconds
          else
            false
          end
        end)

        !recent_activity
      else
        false
      end
    end)

    count = Enum.count(inactive_lobbies)

    Enum.each(inactive_lobbies, fn lobby ->
      Logger.info("Cleaning up inactive lobby: #{lobby.id}, created #{DateTime.diff(now, lobby.created_at)} seconds ago")
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
