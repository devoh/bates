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

  scope "/", BatesWeb do
    pipe_through :api

    get "/status", ProcessController, :status
    post "/processes/:name/start", ProcessController, :start
    post "/processes/:name/stop", ProcessController, :stop
    post "/processes/:name/restart", ProcessController, :restart
  end

  scope "/", BatesWeb do
    pipe_through :browser

    live "/", DashboardLive
    live "/loading/:app_name", LoadingLive
    get "/*path", FallbackController, :index
  end
end
