defmodule CstopiaBackend.Accounts do
  @moduledoc """
  The Accounts context handles user management and authentication.
  """

  import Ecto.Query, warn: false
  alias CstopiaBackend.Repo
  alias CstopiaBackend.Accounts.User

  @doc """
  Gets a user by Discord ID.
  """
  def get_user_by_discord_id(discord_id) do
    Repo.get_by(User, discord_id: discord_id)
  end

  @doc """
  Creates a user.
  """
  def create_user(attrs \\ %{}) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a user.
  """
  def update_user(%User{} = user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Finds or creates a user from Discord OAuth data.
  """
  def find_or_create_user(discord_user) do
    case get_user_by_discord_id(discord_user.id) do
      nil ->
        create_user(%{
          discord_id: discord_user.id,
          username: discord_user.username,
          avatar: discord_user.avatar
        })

      user ->
        # Update user if Discord profile data has changed
        if user.username != discord_user.username || user.avatar != discord_user.avatar do
          update_user(user, %{
            username: discord_user.username,
            avatar: discord_user.avatar
          })
        else
          {:ok, user}
        end
    end
  end
end
