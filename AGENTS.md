# Repository Guidelines

## Project Structure & Module Organization

- Umbrella root with shared config in `mix.exs` and `config/`.
- Apps live under `apps/`: core services (`yellow_dog`, `yellow_dog_dns`, `yellow_dog_dhcpv4`, `yellow_dog_dhcpv6`, `yellow_dog_mdns`, `yellow_dog_telemetry`), web console (`yellow_dog_console`), and libraries (`abyss`, `ex_dns`, `ex_dhcp`).
- Tests live in each app’s `test/` plus end-to-end suites in `e2e_test/`.
- Console assets live in `apps/yellow_dog_console/assets/`, built output goes to `priv/static/` (umbrella) and `apps/yellow_dog_console/priv/static/`.
- Specs and design notes are in `specs/`.

## Build, Test, and Development Commands

- `mix run --no-halt` starts all services; `iex -S mix` for interactive shell.
- `mix test` runs umbrella tests; `mix test apps/yellow_dog_dns` limits scope.
- `mix test.e2e` runs all E2E tests; service-specific aliases include `mix test.e2e.dns` and `mix test.e2e.dhcpv6`.
- `mix format`, `mix lint`, and `mix dialyzer` enforce formatting, linting, and static analysis.
- Console dev: `cd apps/yellow_dog_console && mix phx.server`.
- Console assets: `mix assets.setup`, `mix assets.build`, `mix assets.deploy` (or `bun run build`).

## Coding Style & Naming Conventions

- Elixir formatting is managed by `mix format` and `.formatter.exs`; use 2-space indentation.
- Module naming follows dot notation: `YellowDog.<AppName>.ModuleName` with paths mirroring module hierarchy (e.g., `apps/yellow_dog_dns/lib/yellow_dog/dns/`).
- Keep configuration in TOML files under `priv/` or `apps/*/config/` and access via `YellowDog.Config`.

## Testing Guidelines

- ExUnit is the default test framework; name files `*_test.exs` and mirror module paths.
- E2E tests live in `e2e_test/` and start services with auto-selected ports.
- Run app-specific suites from the umbrella root unless a README calls out local setup.

## Commit & Pull Request Guidelines

- Commit messages follow Conventional Commits with optional scopes (e.g., `feat(dns): add tcp_enabled config`).
- PRs should describe behavior changes, include test coverage notes, and add screenshots for console UI changes.

## Configuration & Environment Notes

- Use `direnv allow` or `devenv shell` for the Nix-based dev environment (Elixir 1.18, OTP 27/28, Bun).
- Test env uses non-privileged ports; don’t hard-code privileged ports in tests.
