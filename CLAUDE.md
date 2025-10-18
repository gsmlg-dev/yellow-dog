# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Yellow Dog DNS is a distributed DNS server written in Erlang/Elixir using an umbrella project structure. The project is currently in early development with an empty `apps/` directory, indicating that the individual applications have not been created yet.

## Development Environment Setup

This project uses [devenv](https://devenv.sh) for development environment management:

```bash
# Activate the development environment
direnv allow  # or use devenv shell

# The environment includes:
# - Elixir 1.16.1 with OTP 26
# - Git, figlet, lolcat, watchman, inotify-tools
# - JavaScript support with pnpm and bun
# - Custom hello script that displays "YellowDog"
```

## Common Commands

### Running the Application
```bash
# Start the application (once apps are added)
mix run --no-halt
```

### Testing
```bash
# Run tests (once apps are added)
mix test

# Run tests for specific path
mix test path/to/test_file.exs

# Batch fix test failures using the custom command
/elixir-fix-tests-batch [test_path]
```

### Code Formatting
```bash
# Format all code according to .formatter.exs configuration
mix format

# The formatter covers mix.exs, config/*.exs, and all apps/* subdirectories
```

### Dependencies
```bash
# Get dependencies
mix deps.get

# Update dependencies
mix deps.update
```

## Architecture

This is an Elixir umbrella project designed to host multiple applications:

- **Umbrella Structure**: The `apps/` directory will contain individual OTP applications
- **Shared Configuration**: All applications share the same configuration in `config/config.exs`
- **Centralized Dependencies**: Dependencies are managed at the umbrella level in `mix.exs`

### Future Application Structure
When implemented, this will likely include:
- DNS server core application
- Distributed node management
- Network handling
- Configuration management
- Testing utilities

## CI/CD

### GitHub Actions Workflows

1. **Elixir CI** (`.github/workflows/elixir.yml`):
   - Runs on push to `main`/`dev` branches and PRs to `main`
   - Tests with Elixir 1.16.1 and OTP 26
   - Builds and pushes Docker images for `dev` branch

2. **Docker Build** (`.github/workflows/docker.yml`):
   - Multi-architecture builds (x86_64, aarch64)
   - Uses Nix for reproducible builds
   - Pushes to GitHub Container Registry

### Docker Images
- **Development**: `docker.io/gsmlg/yellowdogdns:dev` and `ghcr.io/gsmlg-dev/yellowdogdns:dev`
- **Production**: Multi-arch images pushed to `ghcr.io/gsmlg-dev/yellowdogdns`

## DNS Testing/Benchmarking

Once the DNS server is implemented, you can benchmark it using:

```bash
# Create test queries file
echo "www.turku.fi A" > t.txt
echo "www.helsinki.fi A" >> t.txt

# Run DNS performance test
dnsperf -n 100000 -d t.txt -s 127.0.0.1 -p 5454
```

## Development Notes

- The project uses Git for version control
- The `apps/` directory is currently empty and ready for application creation
- Configuration is centralized in the umbrella project
- The project follows Elixir/OTP conventions for umbrella projects
- Use the provided batch test fixing command for efficient test maintenance