fixture_path =
  Path.expand(
    "../experiments/2026-04-28-toml-middleware-parsing/raw/sample.toml",
    File.cwd!()
  )

IO.puts("Reading fixture: #{fixture_path}")
contents = File.read!(fixture_path)

IO.puts("\n--- Raw TOML ---")
IO.puts(contents)

IO.puts("\n--- Toml.decode/1 result ---")
result = Toml.decode(contents)
IO.inspect(result, pretty: true, limit: :infinity)

case result do
  {:ok, data} ->
    app_middleware = get_in(data, ["myapp", "middleware"])
    service_middleware = get_in(data, ["myapp", "services", "web", "middleware"])

    IO.puts("\n--- App-level middleware ---")
    IO.inspect(app_middleware, label: "value")
    IO.inspect(is_list(app_middleware), label: "is_list/1")

    if is_list(app_middleware) do
      IO.inspect(Enum.all?(app_middleware, &is_binary/1),
        label: "all binaries?"
      )
    end

    IO.puts("\n--- Service-level middleware (web) ---")
    IO.inspect(service_middleware, label: "value")
    IO.inspect(is_list(service_middleware), label: "is_list/1")

    if is_list(service_middleware) do
      IO.inspect(Enum.all?(service_middleware, &is_binary/1),
        label: "all binaries?"
      )
    end

    IO.puts("\n--- Service-level middleware (worker) ---")
    worker_middleware = get_in(data, ["myapp", "services", "worker", "middleware"])
    IO.inspect(worker_middleware, label: "value (should be nil/missing)")

  {:error, reason} ->
    IO.puts("Decode failed:")
    IO.inspect(reason)
end
