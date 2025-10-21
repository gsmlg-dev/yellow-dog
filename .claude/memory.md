# Project Memory

## Logging and Telemetry Standards

### YellowDog.Telemetry Usage
- **ALWAYS** use `YellowDog.Telemetry` for all messaging and logging instead of Elixir's built-in `Logger`
- This allows centralized configuration of log output and formatting
- Default behavior: In development environment, print debug level logs
- In production, configure appropriate log levels through telemetry configuration

### Implementation Guidelines
- Replace any `Logger.debug/1`, `Logger.info/1`, `Logger.warn/1`, `Logger.error/1` calls with equivalent `YellowDog.Telemetry` functions
- Configure telemetry handlers based on environment (dev/test/prod)
- Maintain consistent telemetry event naming conventions across the project
