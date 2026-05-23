defmodule BatesWeb.Router do
  use BatesWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :put_root_layout, html: {BatesWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug BatesWeb.Plugs.AppRedirect
  end

  # The loading page must respond to both HTML browsers and JSON-only
  # clients (curl/HTTP libraries that hit a hostname while the app is
  # paused get a 503 JSON body instead of an HTML page).
  pipeline :loading do
    plug :accepts, ["html", "json"]
    plug :fetch_session
    plug :put_root_layout, html: {BatesWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug BatesWeb.Plugs.AppRedirect
  end

  scope "/", BatesWeb do
    pipe_through :api

    get "/status", ProcessController, :status
    get "/processes/:name/logs", ProcessController, :logs
    post "/processes/:name/start", ProcessController, :start
    post "/processes/:name/stop", ProcessController, :stop
    post "/processes/:name/restart", ProcessController, :restart
    post "/processes/:name/env", ProcessController, :env

    post "/processes/:app/services/:service/start",
         ProcessController,
         :start_service

    post "/processes/:app/services/:service/stop",
         ProcessController,
         :stop_service
  end

  scope "/", BatesWeb do
    pipe_through :loading

    get "/loading/:app_name/:service_name", LoadingController, :show
  end

  scope "/", BatesWeb do
    pipe_through :browser

    live "/", DashboardLive
    get "/*path", FallbackController, :index
  end
end
