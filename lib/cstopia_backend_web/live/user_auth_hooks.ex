defmodule CstopiaBackendWeb.UserAuthHooks do
  import Phoenix.LiveView
  import Phoenix.Component
  alias CstopiaBackend.Accounts.User
  alias CstopiaBackend.Repo

  # The same values as in UserAuth
  @session_key "user_id"
  @remember_me_cookie "_cstopia_backend_web_user_remember_me"

  def on_mount(:default, _params, session, socket) do
    IO.inspect(session, label: "Session in default hook")

    socket = assign_new(socket, :current_user, fn ->
      # First try to reconstruct the user from session data
      if session["current_user_id"] do
        # We have user data directly in the session, reconstruct a User struct
        IO.puts("Found user data in session, reconstructing user")
        %User{
          id: session["current_user_id"],
          username: session["current_user_username"],
          avatar: session["current_user_avatar"],
          discord_id: session["current_user_discord_id"]
        }
      else
        # Try to get user from session token
        token = session[@session_key]
        IO.puts("Looking for user with token")

        if token do
          IO.puts("Found token: #{token}")
          case Phoenix.Token.verify(CstopiaBackendWeb.Endpoint, "user auth", token, max_age: 60 * 60 * 24 * 60) do
            {:ok, user_id} ->
              IO.puts("Verified token, fetching user with ID: #{user_id}")
              Repo.get(User, user_id)
            {:error, reason} ->
              IO.puts("Token verification failed: #{reason}")
              nil
          end
        else
          IO.puts("No token found")
          nil
        end
      end
    end)

    # Debug the result
    IO.inspect(socket.assigns[:current_user], label: "Current user after assignment")

    # Add a check and redirect if no user
    if socket.assigns[:current_user] do
      IO.puts("User authenticated successfully, continuing")
      {:cont, socket}
    else
      IO.puts("No current_user found, redirecting to home")
      {:halt, redirect(socket, to: "/")}
    end
  end

  def on_mount(:require_authenticated_user, _params, _session, socket) do
    case socket.assigns[:current_user] do
      nil ->
        # Debug: help understand why auth is failing
        IO.puts("No current_user in socket assigns during :require_authenticated_user")

        # Redirect unauthenticated users to the login page
        {:halt, redirect(socket, to: "/")}
      user ->
        # Debug
        IO.puts("Found current_user in socket assigns during :require_authenticated_user")
        IO.inspect(user, label: "User during auth check")

        {:cont, socket}
    end
  end
end
