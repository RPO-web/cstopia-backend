defmodule CstopiaBackend.Repo do
  use Ecto.Repo,
    otp_app: :cstopia_backend,
    adapter: Ecto.Adapters.Postgres
end
