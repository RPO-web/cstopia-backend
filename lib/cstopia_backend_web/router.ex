defmodule CstopiaBackendWeb.Router do
  use CstopiaBackendWeb, :router
  import CstopiaBackendWeb.RateLimiter

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CstopiaBackendWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug CstopiaBackendWeb.Plugs.RemoteIp
    plug :rate_limit_general
    plug CstopiaBackendWeb.UserAuth, :fetch_current_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Add a stricter rate limit for auth routes
  pipeline :auth_rate_limit do
    plug :rate_limit_auth
  end

  # Unauthenticated routes that can be accessed by anyone
  scope "/", CstopiaBackendWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Authentication routes with stricter rate limiting
  scope "/auth", CstopiaBackendWeb do
    pipe_through [:browser, :auth_rate_limit]

    get "/:provider", AuthController, :request
    get "/:provider/callback", AuthController, :callback
    delete "/logout", AuthController, :delete
  end

  # Routes that require authentication
  scope "/", CstopiaBackendWeb do
    pipe_through [:browser, :require_authenticated_user]

    # Add protected routes here

    # Team Finder routes with LiveView - ensure the session gets the user data
    live_session :authenticated,
                 on_mount: {CstopiaBackendWeb.UserAuthHooks, :default},
                 session: {CstopiaBackendWeb.LiveSessionUtils, :put_user_in_session, []} do
      live "/teamfinder", TeamfinderLive, :index
      live "/teamfinder/create", TeamfinderLive, :create
      live "/teamfinder/:id", TeamfinderLive, :view
    end
  end

  # Protected routes pipeline
  pipeline :require_authenticated_user do
    plug CstopiaBackendWeb.UserAuth, :require_authenticated_user
  end

  # Other scopes may use custom stacks.
  # scope "/api", CstopiaBackendWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:cstopia_backend, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: CstopiaBackendWeb.Telemetry
    end
  end
end
