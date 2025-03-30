defmodule CstopiaBackendWeb.UserAuth do
  @moduledoc """
  Functions for managing user authentication and sessions.
  """
  import Plug.Conn
  import Phoenix.Controller

  alias CstopiaBackend.Accounts.User

  @max_age 60 * 60 * 24 * 60 # 60 days in seconds
  @session_key "user_id"
  @remember_me_cookie "_cstopia_backend_web_user_remember_me"

  @doc """
  A plug that fetches the current user from the session.
  """
  def fetch_current_user(conn, _opts) do
    {token, conn} = ensure_user_token(conn)
    user = token && fetch_user_by_token(token)
    assign(conn, :current_user, user)
  end

  @doc """
  Used for routes that require the user to be authenticated.
  """
  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> maybe_store_return_to()
      |> redirect(to: "/")
      |> halt()
    end
  end

  # Plug callback implementation for fetch_current_user
  def call(conn, :fetch_current_user) do
    fetch_current_user(conn, [])
  end

  # Plug callback implementation for require_authenticated_user
  def call(conn, :require_authenticated_user) do
    require_authenticated_user(conn, [])
  end

  @doc """
  Plug initialization callback
  """
  def init(action) when action in [:fetch_current_user, :require_authenticated_user], do: action

  @doc """
  Logs in a user by setting a session.
  """
  def log_in_user(conn, user) do
    token = Phoenix.Token.sign(CstopiaBackendWeb.Endpoint, "user auth", user.id)
    user_return_to = get_session(conn, :user_return_to)

    conn
    |> renew_session()
    |> put_token_in_session(token)
    |> maybe_write_remember_me_cookie(token)
    |> redirect(to: user_return_to || "/")
  end

  defp put_token_in_session(conn, token) do
    conn
    |> put_session(@session_key, token)
    |> put_session(:live_socket_id, "users_sessions:#{Base.url_encode64(token)}")
  end

  defp maybe_write_remember_me_cookie(conn, token) do
    put_resp_cookie(conn, @remember_me_cookie, token, max_age: @max_age)
  end

  defp renew_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  @doc """
  Logs out the user.
  """
  def log_out_user(conn) do
    conn
    |> renew_session()
    |> delete_resp_cookie(@remember_me_cookie)
  end

  defp ensure_user_token(conn) do
    if token = get_session(conn, @session_key) do
      {token, conn}
    else
      {get_req_cookie(conn, @remember_me_cookie), conn}
    end
  end

  defp fetch_user_by_token(nil), do: nil
  defp fetch_user_by_token(token) do
    case Phoenix.Token.verify(CstopiaBackendWeb.Endpoint, "user auth", token, max_age: @max_age) do
      {:ok, id} -> CstopiaBackend.Repo.get(User, id)
      {:error, _} -> nil
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn

  defp get_req_cookie(conn, name) do
    conn.cookies[name]
  end
end
