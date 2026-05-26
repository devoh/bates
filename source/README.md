# Bates

A server process manager for local development.

## Configuration

The configuration file is defined in [TOML][] format.

[toml]: https://toml.io

```toml
[test_server]
root = "/apps/test_server"
command = "rails server -p $PORT"
addons = ["postgresql"]
middleware = ["direnv"]
```

The command will have the `$PORT` placeholder replaced with a dynamically
assigned port at startup. A port may be manually specified via the `port` key,
instead.

Multiple services are supported, as well.

```toml
[multi_service_app]
root = "/apps/multi_service_app"
middleware = ["direnv"]

  [multi_service_app.services.web]
  hostname = true
  command = "bin/rails server"

  [multi_service_app.services.css]
  command = "bin/rails tailwindcss:watch[always]"
```
