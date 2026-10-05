defmodule YellowDog.Management.PostgresToolsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias YellowDog.Management.PostgresTools
  alias YellowDog.Management.PostgresToolsFixture, as: Fixture

  setup do
    fixture = Fixture.install!()
    %{fixture: fixture}
  end

  test "runs each allowed native tool with literal arguments and supplied environment", %{
    fixture: fixture
  } do
    literal = "literal; touch #{Path.join(fixture.directory, "not-created")}"

    env =
      PostgresTools.connection_env(
        "postgresql://test%3Auser:p%40ss%3Aword@db.example:5544/data%20base?sslmode=verify-full"
      )

    for tool <- ["pg_dump", "pg_restore", "tar"] do
      assert System.find_executable(tool) == Path.join(fixture.bin, tool)

      assert {:ok, output} =
               PostgresTools.run(
                 tool,
                 Fixture.arguments(fixture, "inspect", [literal, "two words"]),
                 env: env
               )

      result = Jason.decode!(output)
      assert result["tool"] == tool
      assert result["args"] == [literal, "two words"]

      assert result["env"] == %{
               "PGHOST" => "db.example",
               "PGPORT" => "5544",
               "PGUSER" => "test:user",
               "PGPASSWORD" => "p@ss:word",
               "PGDATABASE" => "data base",
               "PGCONNECT_TIMEOUT" => "10",
               "PGAPPNAME" => "yellow-dog-management-backup",
               "PGSSLMODE" => "verify-full"
             }

      assert Fixture.wait_until(fn -> not Fixture.alive?(Fixture.pid(fixture)) end)
    end

    refute File.exists?(Path.join(fixture.directory, "not-created"))
  end

  test "captures stdout and stderr without shell execution", %{fixture: fixture} do
    assert {:ok, "stdout\nstderr\n"} =
             PostgresTools.run("pg_dump", Fixture.arguments(fixture, "success"))

    assert Fixture.wait_until(fn -> not Fixture.alive?(Fixture.pid(fixture)) end)
  end

  test "accepts exactly 65536 output bytes", %{fixture: fixture} do
    assert {:ok, output} =
             PostgresTools.run("pg_dump", Fixture.arguments(fixture, "exact_output"))

    assert output == :binary.copy("x", 65_536)
    assert Fixture.wait_until(fn -> not Fixture.alive?(Fixture.pid(fixture)) end)
  end

  test "output overflow terminates the native child and stops further writes", %{fixture: fixture} do
    assert {:error, :command_output_limit} =
             PostgresTools.run("pg_dump", Fixture.arguments(fixture, "overflow"), timeout: 5_000)

    assert_child_stopped(fixture)
  end

  test "deadline terminates a writing native child before returning", %{fixture: fixture} do
    started = System.monotonic_time(:millisecond)

    assert {:error, :command_timeout} =
             PostgresTools.run("pg_dump", Fixture.arguments(fixture, "write_forever"),
               timeout: 200
             )

    assert System.monotonic_time(:millisecond) - started < 2_000
    assert_child_stopped(fixture)
  end

  test "caller death terminates the owned native child and stops further writes", %{
    fixture: fixture
  } do
    caller =
      spawn(fn ->
        PostgresTools.run("pg_dump", Fixture.arguments(fixture, "write_forever"), timeout: 10_000)
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    assert Fixture.wait_until(fn -> File.exists?(fixture.heartbeat) end)
    assert [{:process, owner}] = elem(Process.info(caller, :monitors), 1)
    owner_monitor = Process.monitor(owner)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, _reason}, 2_000
    assert_child_stopped(fixture)
  end

  test "nonzero native exit does not expose stderr credentials in errors or logs", %{
    fixture: fixture
  } do
    secret = "native-runner-secret-#{System.unique_integer([:positive])}"
    env = PostgresTools.connection_env("postgresql://user:#{secret}@localhost/database")

    logs =
      capture_log(fn ->
        assert {:error, {:command_exit, 7}} =
                 PostgresTools.run("pg_restore", Fixture.arguments(fixture, "exit"), env: env)
      end)

    refute logs =~ secret
    assert Fixture.wait_until(fn -> not Fixture.alive?(Fixture.pid(fixture)) end)
  end

  test "missing tools fail without starting a native child", %{fixture: fixture} do
    empty = Path.join(fixture.directory, "empty")
    File.mkdir!(empty)
    System.put_env("PATH", empty)
    assert {:error, {:missing_tool, "pg_dump"}} = PostgresTools.run("pg_dump", [])
    refute File.exists?(fixture.pid_path)
  end

  test "rejects tools outside the explicit allowlist", %{fixture: fixture} do
    assert_raise FunctionClauseError, fn -> PostgresTools.run("sh", ["-c", "true"]) end
    refute File.exists?(fixture.pid_path)
  end

  test "decodes socket directories and uses libpq's default port", %{fixture: fixture} do
    env =
      PostgresTools.connection_env(
        "postgres://socket%20user@unused.example/socket%20database?socket_dir=%2Ftmp%2Fpg%20socket&sslmode=disable"
      )

    assert {:ok, output} =
             PostgresTools.run("pg_dump", Fixture.arguments(fixture, "inspect"), env: env)

    result = Jason.decode!(output)["env"]
    assert result["PGHOST"] == "/tmp/pg socket"
    assert result["PGPORT"] == "5432"
    assert result["PGUSER"] == "socket user"
    assert result["PGDATABASE"] == "socket database"
    assert result["PGSSLMODE"] == "disable"
    assert is_nil(result["PGPASSWORD"])
  end

  test "passes a validated IPv6 host and decoded credentials to the native tool",
       %{fixture: fixture} do
    env =
      PostgresTools.connection_env(
        "postgresql://ipv6%20user:p%40ss%3Aword@[::1]:5544/ipv6%20database?sslmode=verify-full"
      )

    assert {:ok, output} =
             PostgresTools.run("pg_dump", Fixture.arguments(fixture, "inspect"), env: env)

    result = Jason.decode!(output)["env"]
    assert result["PGHOST"] == "::1"
    assert result["PGPORT"] == "5544"
    assert result["PGUSER"] == "ipv6 user"
    assert result["PGPASSWORD"] == "p@ss:word"
    assert result["PGDATABASE"] == "ipv6 database"
    assert result["PGSSLMODE"] == "verify-full"
    assert Fixture.wait_until(fn -> not Fixture.alive?(Fixture.pid(fixture)) end)
  end

  test "omitted URL password explicitly removes an inherited PGPASSWORD", %{fixture: fixture} do
    original = System.get_env("PGPASSWORD")
    on_exit(fn -> Fixture.restore_env("PGPASSWORD", original) end)
    System.put_env("PGPASSWORD", "inherited-secret")
    env = PostgresTools.connection_env("postgresql://user@localhost/database")
    assert {"PGPASSWORD", nil} in env

    assert {:ok, output} =
             PostgresTools.run("pg_dump", Fixture.arguments(fixture, "inspect"), env: env)

    assert is_nil(Jason.decode!(output)["env"]["PGPASSWORD"])
  end

  test "invalid database URLs fail with a credential-free error and no logs", %{fixture: fixture} do
    secret = "url-secret-#{System.unique_integer([:positive])}"

    invalid = [
      "mysql://user:#{secret}@localhost/database",
      "postgresql://:#{secret}@localhost/database",
      "postgresql://user:#{secret}@localhost/",
      "postgresql://user:#{secret}@localhost",
      "postgresql://localhost/database",
      ""
    ]

    logs =
      capture_log(fn ->
        for url <- invalid do
          error = assert_raise ArgumentError, fn -> PostgresTools.connection_env(url) end
          assert Exception.message(error) == "A PostgreSQL database URL is required"
          refute Exception.message(error) =~ secret
        end
      end)

    refute logs =~ secret
    refute File.exists?(fixture.pid_path)
  end

  test "malformed authority and invalid explicit ports are rejected without exposing credentials",
       %{fixture: fixture} do
    secret = "malformed-url-secret-#{System.unique_integer([:positive])}"

    invalid = [
      "postgresql://user:#{secret}@localhost:invalid/database",
      "postgresql://user:#{secret}@localhost:0/database",
      "postgresql://user:#{secret}@localhost:65536/database",
      "postgresql://user:#{secret}@[broken/database"
    ]

    logs =
      capture_log(fn ->
        for url <- invalid do
          error = assert_raise ArgumentError, fn -> PostgresTools.connection_env(url) end
          refute Exception.message(error) =~ secret
        end
      end)

    refute logs =~ secret
    refute File.exists?(fixture.pid_path)
  end

  defp assert_child_stopped(fixture) do
    pid = Fixture.pid(fixture)
    assert is_integer(pid), "native helper never recorded its OS PID"
    assert File.exists?(fixture.heartbeat), "native helper never started writing"

    assert Fixture.wait_until(fn -> not Fixture.alive?(pid) end),
           "native OS child #{pid} is still present"

    before = File.read!(fixture.heartbeat)
    Process.sleep(100)
    assert File.read!(fixture.heartbeat) == before
    refute Fixture.alive?(pid)
  end
end
