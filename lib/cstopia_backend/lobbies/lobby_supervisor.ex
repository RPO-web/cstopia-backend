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
        newest_activity = get_newest_activity(lobby.players)

        # If the newest activity is older than 10 minutes, close the lobby
        diff = DateTime.diff(DateTime.utc_now(), newest_activity, :second)
        if diff > 600 do # 10 minutes
          Logger.info("Closing inactive lobby #{lobby.id} - all players disconnected for #{div(diff, 60)} minutes")
          # Use a try block just for the deletion operation
          delete_lobby(lobby.id)
        end
      end
    end)

    # Schedule the next cleanup
    schedule_cleanup()
  end

  # Helper function to get the newest activity timestamp from a list of players
  defp get_newest_activity(players) do
    Enum.reduce(players, ~U[1970-01-01 00:00:00Z], fn player, newest ->
      player_activity = Map.get(player, "last_activity")
      cond do
        is_nil(player_activity) -> newest
        DateTime.compare(player_activity, newest) == :gt -> player_activity
        true -> newest
      end
    end)
  end

  # Helper function to safely delete a lobby
  defp delete_lobby(lobby_id) do
    CstopiaBackend.Lobbies.LobbyServer.delete_lobby(lobby_id)
  rescue
    e ->
      Logger.error("Failed to delete lobby #{lobby_id}: #{inspect(e)}")
      {:error, :delete_failed}
  catch
    :exit, reason ->
      Logger.error("Timeout deleting lobby #{lobby_id}: #{inspect(reason)}")
      {:error, :timeout}
  end

  defp schedule_cleanup do
    # Run cleanup every 5 minutes
    Process.send_after(self(), :cleanup_lobbies, 5 * 60 * 1000)
  end

  # Handle the cleanup message
  def handle_info(:cleanup_lobbies, state) do
    # Run the cleanup
    cleanup_inactive_lobbies()
    {:noreply, state}
  end
end
