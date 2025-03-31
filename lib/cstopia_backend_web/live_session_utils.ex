defmodule CstopiaBackendWeb.LiveSessionUtils do
  @moduledoc """
  Utilities for handling LiveView sessions
  """

  @doc """
  Puts relevant authentication data from the Plug.Conn session into the LiveView session
  """
  def put_user_in_session(conn) do
    # Pass the user_id directly, don't try to serialize the entire user struct
    # LiveView can't properly serialize complex structs like Ecto models
    if conn.assigns[:current_user] do
      user = conn.assigns[:current_user]
      %{
        "user_id" => Plug.Conn.get_session(conn, "user_id"),
        "current_user_id" => user.id,
        "current_user_username" => user.username,
        "current_user_avatar" => user.avatar,
        "current_user_discord_id" => user.discord_id
      }
    else
      %{"user_id" => Plug.Conn.get_session(conn, "user_id")}
    end
  end
end
