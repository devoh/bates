# Conjure

Local multi-application development server.

## Repo Structure

```
source/          Elixir application (code, tests, config)
specs/           Domain specs (what the system is and why)
workflow/        Proposals, plans, and blueprints (CDD pipeline)
playbook/        Coding conventions and code review checklist
research/        Distilled external knowledge
transcripts/     Cleaned call transcripts and meeting notes
experiments/     Prototypes and POCs
docs/            External-facing content
```

## Setup

### Install Caddy

```bash
brew install caddy
```

### Configure DNS resolver

Create a resolver file so `.test` domains resolve to localhost:

```bash
sudo bash -c 'echo "nameserver 127.0.0.1" > /etc/resolver/test'
```

### Trust the Caddy CA

Caddy automatically generates SSL certificates for local domains. Trust
its root CA so browsers accept the certificates:

```bash
caddy trust
```

## Configuration

The configuration file is defined in [TOML][] format.

[toml]: https://toml.io

```toml
[test_server]
environment = { SECRET = "Shh…" }
root = "/apps/test_server"
command = "bundle exec rackup -p $PORT"
```

## Methodology

This repo follows [Context-Driven Development](CDD.md). Every decision,
conversation, and research finding is written down in the repo. Agents and
humans navigate the same context.
