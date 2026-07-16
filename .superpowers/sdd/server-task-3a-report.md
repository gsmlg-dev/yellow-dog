# Server Task 3A Evidence Report

## Status

Complete at base commit `ff71c5e9785886a3fd353bb7d8e75a9e7be0a7f9`.

Implemented the DNS read/wire adapter boundary only. All DNS mutation dispatches
remain typed `unsupported` and perform no dependency calls.

## Scope

- `apps/yellow_dog/lib/yellow_dog/server/control/dns.ex`
- `apps/yellow_dog/test/yellow_dog/server/control/dns_test.exs`
- `apps/yellow_dog/test/support/server_dns_control_fake.ex`

The adapter uses fixed production module dependencies and test-only overrides
limited to known dependency keys. DNS modules that are not compile-time
dependencies of `yellow_dog` are invoked dynamically through those fixed keys.

## TDD Evidence

Initial RED before production code:

```text
1 test, 1 failure
UndefinedFunctionError: YellowDog.Server.Control.Dns.dispatch/2 is undefined
```

Required full-matrix RED before production code:

```text
14 tests, 14 failures
All failures were UndefinedFunctionError for absent Dns.dispatch/2 or Dns.current/2.
```

Final focused GREEN after adding all eight fixed RR type coverage:

```text
15 tests, 0 failures
```

Coverage includes all seven reads, `Operation.validate_result/2`, bounded and
cursor-aware deterministic lists, fixed-clock observations, mutation snapshots,
record ID stability and scope failures, provider projection and redaction,
runtime-field stripping, typed dependency failures, unsupported side-effect
checks, and atom-count stability.

## Verification

All commands ran through `devenv shell` from the shared checkout.

```text
cd apps/yellow_dog && mix test test/yellow_dog/server/control/dns_test.exs
15 tests, 0 failures

cd apps/yellow_dog && mix test
270 tests, 0 failures

cd apps/yellow_dog && MIX_ENV=dev mix compile --force --warnings-as-errors
exit 0

cd apps/yellow_dog && MIX_ENV=test mix compile --force --warnings-as-errors
exit 0

cd apps/yellow_dog && mix format --check-formatted <three Task 3A Elixir files>
exit 0

cd apps/yellow_dog && mix credo --strict <three Task 3A Elixir files>
170 mods/funs, found no issues
```

The protected console files and root `mix.exs` retained their original dirty
diff counts throughout the task. No protected file was formatted, staged, or
reverted.

## Concerns

`ViewManager.stats/0` currently does not expose runtime ACL match clients. The
adapter consumes `match_clients` when the public stats facade supplies it and
otherwise emits the schema-valid empty list; it does not inspect process state
or local configuration paths.
