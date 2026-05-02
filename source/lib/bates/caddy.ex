defmodule Bates.Caddy do
  use GenServer
  require Logger

  @caddy_command ~c"caddy run --config -"
  @admin_url "http://localhost:2019"

  # Public API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def update_route(hostname, port) do
    GenServer.call(__MODULE__, {:update_route, hostname, port})
  end

  def revert_route(hostname) do
    GenServer.call(__MODULE__, {:revert_route, hostname})
  end

  # Callbacks

  @impl GenServer
  def init(_opts) do
    {:ok, %{pid: nil, os_pid: nil}, {:continue, :start_caddy}}
  end

  @impl GenServer
  def handle_continue(:start_caddy, state) do
    case start_caddy() do
      {:ok, pid, os_pid} ->
        {:noreply, %{state | pid: pid, os_pid: os_pid}}

      {:error, reason} ->
        Logger.error("Failed to start Caddy: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_call({:update_route, hostname, _port}, _from, %{pid: nil} = state) do
    Logger.warning(
      "[caddy] Cannot update route for #{hostname}: Caddy not running"
    )

    {:reply, {:error, :not_running}, state}
  end

  def handle_call({:update_route, hostname, port}, _from, state) do
    result = do_update_route(hostname, port)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:revert_route, hostname}, _from, %{pid: nil} = state) do
    Logger.warning(
      "[caddy] Cannot revert route for #{hostname}: Caddy not running"
    )

    {:reply, {:error, :not_running}, state}
  end

  def handle_call({:revert_route, hostname}, _from, state) do
    result = do_revert_route(hostname)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_info({stream, _os_pid, data}, state)
      when stream in [:stdout, :stderr] do
    Logger.info("[caddy] #{String.trim(data)}")
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, _os_pid, :process, _pid, reason}, state) do
    Logger.warning("[caddy] Process exited: #{inspect(reason)}")
    new_state = %{state | pid: nil, os_pid: nil}

    case start_caddy() do
      {:ok, pid, os_pid} ->
        Logger.info(
          "[caddy] Restarted after crash, re-registering running apps"
        )

        re_register_running_routes()
        {:noreply, %{new_state | pid: pid, os_pid: os_pid}}

      {:error, reason} ->
        Logger.error("[caddy] Failed to restart: #{inspect(reason)}")
        {:noreply, new_state}
    end
  end

  # Admin API

  defp do_update_route(hostname, port) do
    control_port = control_interface_port()
    route_id = "route:#{hostname}"

    route = %{
      "@id" => route_id,
      "match" => [%{"host" => [hostname]}],
      "handle" => [
        %{
          "handler" => "subroute",
          "routes" => [
            %{
              "handle" => [
                %{
                  "handler" => "reverse_proxy",
                  "upstreams" => [%{"dial" => "127.0.0.1:#{port}"}],
                  "handle_response" => [
                    %{
                      "match" => %{"status_code" => [502]},
                      "routes" => [
                        %{
                          "handle" => [
                            %{
                              "handler" => "reverse_proxy",
                              "upstreams" => [
                                %{"dial" => "127.0.0.1:#{control_port}"}
                              ]
                            }
                          ]
                        }
                      ]
                    }
                  ]
                }
              ]
            }
          ]
        }
      ],
      "terminal" => true
    }

    admin_api_patch(route_id, route)
  end

  defp do_revert_route(hostname) do
    control_port = control_interface_port()
    route_id = "route:#{hostname}"

    route = %{
      "@id" => route_id,
      "match" => [%{"host" => [hostname]}],
      "handle" => [
        %{
          "handler" => "subroute",
          "routes" => [
            %{
              "handle" => [
                %{
                  "handler" => "reverse_proxy",
                  "upstreams" => [%{"dial" => "127.0.0.1:#{control_port}"}]
                }
              ]
            }
          ]
        }
      ],
      "terminal" => true
    }

    admin_api_patch(route_id, route)
  end

  defp admin_api_patch(route_id, route) do
    url = ~c"#{@admin_url}/id/#{route_id}"
    body = Jason.encode!(route)
    headers = [{~c"Content-Type", ~c"application/json"}]
    request = {url, headers, ~c"application/json", body}

    case :httpc.request(:patch, request, [], []) do
      {:ok, {{_, status, _}, _, _}} when status in 200..299 ->
        :ok

      {:ok, {{_, status, _}, _, response_body}} ->
        Logger.warning(
          "[caddy] Admin API PATCH #{route_id} returned #{status}: #{response_body}"
        )

        {:error, {:http_status, status}}

      {:error, reason} ->
        Logger.warning("[caddy] Admin API request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp re_register_running_routes do
    for name <- Bates.ProcessSupervisor.app_names(),
        service <- Bates.App.services(name),
        service.hostname != nil,
        service.port != nil do
      case do_update_route(service.hostname, service.port) do
        :ok ->
          Logger.info("[caddy] Re-registered route for #{service.hostname}")

        {:error, reason} ->
          Logger.warning(
            "[caddy] Failed to re-register #{service.hostname}: #{inspect(reason)}"
          )
      end
    end
  end

  # Startup

  defp start_caddy do
    config = generate_config()
    Logger.info("[caddy] Starting with generated JSON config")

    case :exec.run_link(@caddy_command, [:stdin, :stdout, :stderr, :monitor]) do
      {:ok, pid, os_pid} ->
        :ok = :exec.send(os_pid, config)
        :ok = :exec.send(os_pid, :eof)
        {:ok, pid, os_pid}

      error ->
        error
    end
  end

  # Config generation

  def generate_config do
    control_port = control_interface_port()
    routes = service_routes(control_port) ++ [catch_all_route(control_port)]

    config = %{
      "admin" => %{
        "listen" => "localhost:2019"
      },
      "apps" => %{
        "http" => %{
          "servers" => %{
            "bates" => %{
              "listen" => [":443", ":80"],
              "routes" => [control_route(control_port) | routes],
              "tls_connection_policies" => [
                %{"match" => %{}, "default_sni" => "bates.test"}
              ]
            }
          }
        },
        "tls" => %{
          "automation" => %{
            "policies" => [
              %{"issuers" => [%{"module" => "internal"}]}
            ]
          }
        }
      }
    }

    Jason.encode!(config)
  end

  defp control_route(control_port) do
    %{
      "@id" => "route:bates.test",
      "match" => [%{"host" => ["bates.test"]}],
      "handle" => [
        %{
          "handler" => "subroute",
          "routes" => [
            %{
              "handle" => [
                %{
                  "handler" => "reverse_proxy",
                  "upstreams" => [%{"dial" => "127.0.0.1:#{control_port}"}]
                }
              ]
            }
          ]
        }
      ],
      "terminal" => true
    }
  end

  defp service_routes(control_port) do
    for {_name, _root, services} <- Bates.Config.applications(),
        %{hostname: hostname} when not is_nil(hostname) <- services do
      %{
        "@id" => "route:#{hostname}",
        "match" => [%{"host" => [hostname]}],
        "handle" => [
          %{
            "handler" => "subroute",
            "routes" => [
              %{
                "handle" => [
                  %{
                    "handler" => "reverse_proxy",
                    "upstreams" => [%{"dial" => "127.0.0.1:#{control_port}"}]
                  }
                ]
              }
            ]
          }
        ],
        "terminal" => true
      }
    end
  end

  defp catch_all_route(control_port) do
    %{
      "@id" => "route:catch-all",
      "match" => [%{"host" => ["*.test"]}],
      "handle" => [
        %{
          "handler" => "subroute",
          "routes" => [
            %{
              "handle" => [
                %{
                  "handler" => "reverse_proxy",
                  "upstreams" => [%{"dial" => "127.0.0.1:#{control_port}"}]
                }
              ]
            }
          ]
        }
      ],
      "terminal" => true
    }
  end

  defp control_interface_port do
    BatesWeb.Endpoint.config(:http)[:port] || 4080
  end
end
