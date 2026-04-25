# Bates

A server process manager for local development.

## Configuration

The configuration file is defined in [TOML][] format.

[toml]: https://toml.io

```toml
[test_server]
env = { SECRET = "Shh…" }
dir = "/apps/test_server"
command = "bundle exec rackup -p $PORT"
```

The command will have the `$PORT` placeholder replaced with a dynamically
assigned port at startup. A port may be manually specified via the `port` key,
instead.
