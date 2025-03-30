import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :cstopia_backend, CstopiaBackend.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "cstopia_backend_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :cstopia_backend, CstopiaBackendWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "LKxAh/fvVNUQxXWSKGUGXerV6tXMiaycw3A39GxLbH1k1hKZX8aTd96AZrdyU5+B",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Discord OAuth credentials for testing
config :ueberauth, Ueberauth.Strategy.Discord.OAuth,
  client_id: "TEST_DISCORD_CLIENT_ID",
  client_secret: "TEST_DISCORD_CLIENT_SECRET"
