defmodule CstopiaBackend.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "users" do
    field :username, :string
    field :discord_id, :string
    field :avatar, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:discord_id, :username, :avatar])
    |> validate_required([:discord_id, :username, :avatar])
  end
end
