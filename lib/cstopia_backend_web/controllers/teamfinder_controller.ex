defmodule CstopiaBackendWeb.TeamfinderController do
  use CstopiaBackendWeb, :controller

  def index(conn, _params) do
    # TODO: In future implementation, replace with LiveView for real-time updates
    # This would include:
    # - Active teams/lobbies with current participants
    # - Real-time status updates
    # - Joining/leaving animations

    # For now, just render static template with sample data
    render(conn, :index)
  end

  def search(conn, params) do
    # This will be implemented later to search for teams/teammates
    # For now just render the search page
    render(conn, :search)
  end

  def create_listing(conn, _params) do
    # This will be implemented later to handle team/teammate listing creation
    render(conn, :create)
  end

  def view_listing(conn, %{"id" => id}) do
    # TODO: In future implementation, fetch the team with the given ID
    # and render it with a LiveView component for real-time updates
    # such as chat messages, player joins/disconnects, etc.

    # For now just render static view with the ID parameter
    render(conn, :view, id: id)
  end

  # Future methods to support the team finder functionality:
  #
  # def join_team(conn, %{"id" => team_id})
  # def leave_team(conn, %{"id" => team_id})
  # def send_message(conn, %{"id" => team_id, "message" => message})
  # def update_team_status(conn, %{"id" => team_id, "status" => status})
end
