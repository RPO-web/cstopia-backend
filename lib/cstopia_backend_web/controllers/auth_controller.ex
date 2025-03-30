defmodule CstopiaBackendWeb.AuthController do
  use CstopiaBackendWeb, :controller
  plug Ueberauth

  alias CstopiaBackend.Accounts
  alias CstopiaBackendWeb.UserAuth

  def request(_conn, _params) do
    # This route is handled by Ueberauth
  end

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    # Extract user info from Discord OAuth
    # Extract just the avatar hash from the Discord image URL
    avatar_hash = case auth.info.image do
      nil -> nil
      url when is_binary(url) ->
        url
        |> String.split("/")
        |> List.last()
        |> String.split(".")
        |> List.first()
      _ -> nil
    end

    discord_user = %{
      id: auth.uid,
      username: auth.info.nickname || auth.info.name,
      avatar: avatar_hash
    }

    case Accounts.find_or_create_user(discord_user) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "Successfully authenticated via Discord!")
        |> UserAuth.log_in_user(user)

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Authentication failed")
        |> redirect(to: ~p"/")
    end
  end

  def delete(conn, _params) do
    conn
    |> UserAuth.log_out_user()
    |> redirect(to: ~p"/")
  end
end
