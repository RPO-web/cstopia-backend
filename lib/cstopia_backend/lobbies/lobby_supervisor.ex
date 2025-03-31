defmodule CstopiaBackend.Lobbies.LobbySupervisor do
  use DynamicSupervisor
  require Logger

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_init_arg) do
    # Start a periodic task to check for inactive lobbies
    schedule_cleanup()

    DynamicSupervisor.init(strategy: :one_for_one)
  end

  # Cleanup inactive lobbies (all players disconnected for 10+ minutes)
  def cleanup_inactive_lobbies do
    Logger.info("Running lobby cleanup check")

    # Get all lobbies
    lobbies = CstopiaBackend.Lobbies.LobbyServer.list_lobbies()

    # Check each lobby for activity
    Enum.each(lobbies, fn lobby ->
      # Check if any player is connected
      any_connected = Enum.any?(lobby.players, fn player ->
        Map.get(player, "connected", false) == true
      end)

      if !any_connected && length(lobby.players) > 0 do
        # All players disconnected, check if the lobby should be removed
        newest_activity = Enum.reduce(lobby.players, ~U[1970-01-01 00:00:00Z], fn player, newest ->
          player_activity = Map.get(player, "last_activity")
          if player_activity && DateTime.compare(player_activity, newest) == :gt do
            player_activity
          else
            newest
          end
        end)

        # If the newest activity is older than 10 minutes, close the lobby
        diff = DateTime.diff(DateTime.utc_now(), newest_activity, :second)
        if diff > 600 do # 10 minutes
          Logger.info("Closing inactive lobby #{lobby.id} - all players disconnected for #{div(diff, 60)} minutes")
          CstopiaBackend.Lobbies.LobbyServer.delete_lobby(lobby.id)
        end
      end
    end)

    # Schedule the next cleanup
    schedule_cleanup()
  end

  defp schedule_cleanup do
    # Run cleanup every 5 minutes
    Process.send_after(self(), :cleanup_lobbies, 5 * 60 * 1000)
  end

  # No need for @impl since DynamicSupervisor doesn't have a handle_info callback
  def handle_info(:cleanup_lobbies, state) do
    # Run the cleanup
    cleanup_inactive_lobbies()
    {:noreply, state}
  end
end
