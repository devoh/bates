defmodule ConjureWeb.Router do
  use ConjureWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :put_root_layout, html: {ConjureWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug ConjureWeb.Plugs.AppRedirect
  end

  scope "/", ConjureWeb do
    pipe_through :api

    get "/status", ProcessController, :status
    post "/processes/:name/start", ProcessController, :start
    post "/processes/:name/stop", ProcessController, :stop
  end

  scope "/", ConjureWeb do
    pipe_through :browser

    live "/loading/:app_name", LoadingLive
    get "/*path", FallbackController, :index
  end
end
