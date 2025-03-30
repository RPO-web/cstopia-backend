defmodule CstopiaBackend.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      CstopiaBackendWeb.Telemetry,
      CstopiaBackend.Repo,
      {DNSCluster, query: Application.get_env(:cstopia_backend, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: CstopiaBackend.PubSub},
      # Start a worker by calling: CstopiaBackend.Worker.start_link(arg)
      # {CstopiaBackend.Worker, arg},
      # Start to serve requests, typically the last entry
      CstopiaBackendWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: CstopiaBackend.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CstopiaBackendWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
