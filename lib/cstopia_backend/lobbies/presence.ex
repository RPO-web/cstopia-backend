defmodule CstopiaBackend.Lobbies.Presence do
  @moduledoc """
  Provides presence tracking for users viewing the lobbies page.

  Uses Phoenix.Presence under the hood to track:
  - Which users are currently viewing the lobbies page
  - When they started viewing the page
  """
  use Phoenix.Presence,
    otp_app: :cstopia_backend,
    pubsub_server: CstopiaBackend.PubSub

  alias CstopiaBackend.Lobbies.Presence
  alias Phoenix.PubSub

  @lobbies_topic "lobbies_presence"

  @doc """
  Tracks a user's presence on the lobbies page.
  """
  def track_user_in_lobbies(user_id, user_data) when is_map(user_data) do
    Presence.track(
      self(),
      @lobbies_topic,
      user_id,
      Map.merge(user_data, %{page: "lobbies", viewing_since: DateTime.utc_now()})
    )
  end

  @doc """
  Subscribe to presence changes on the lobbies page.
  """
  def subscribe_to_lobbies_presence do
    PubSub.subscribe(CstopiaBackend.PubSub, @lobbies_topic)
  end

  @doc """
  Get a list of users currently viewing the lobbies page.
  """
  def list_users_in_lobbies do
    Presence.list(@lobbies_topic)
  end

  @doc """
  Get the number of users currently viewing the lobbies page.
  """
  def count_users_in_lobbies do
    @lobbies_topic
    |> Presence.list()
    |> map_size()
  end

  @doc """
  Check if a specific user is viewing the lobbies page.
  """
  def user_viewing_lobbies?(user_id) do
    case Presence.get_by_key(@lobbies_topic, user_id) do
      [] -> false
      [_|_] -> true
    end
  end
end
