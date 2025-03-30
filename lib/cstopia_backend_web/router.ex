defmodule CstopiaBackendWeb.Router do
  use CstopiaBackendWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CstopiaBackendWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug CstopiaBackendWeb.UserAuth, :fetch_current_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Unauthenticated routes that can be accessed by anyone
  scope "/", CstopiaBackendWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Authentication routes
  scope "/auth", CstopiaBackendWeb do
    pipe_through :browser

    get "/:provider", AuthController, :request
    get "/:provider/callback", AuthController, :callback
    delete "/logout", AuthController, :delete
  end

  # Routes that require authentication
  scope "/", CstopiaBackendWeb do
    pipe_through [:browser, :require_authenticated_user]

    # Add protected routes here
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
