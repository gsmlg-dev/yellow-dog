defmodule DNS.Message.Record.Data.Registry do
  @moduledoc """
  Registry for DNS record type implementations.

  This module provides a centralized registry for DNS record type implementations,
  allowing runtime extensibility and eliminating hardcoded type dispatch patterns.
  """

  use GenServer

  @registry_name __MODULE__
  @type_table :dns_record_types

  @type record_module :: module()
  @type record_type :: non_neg_integer()

  @doc """
  Start the registry server.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @registry_name)
  end

  @doc """
  Register a record type implementation.
  """
  @spec register(record_type(), record_module()) :: :ok | {:error, term()}
  def register(type, module) when is_integer(type) and is_atom(module) do
    case GenServer.call(@registry_name, {:register, type, module}) do
      :ok -> :ok
      error -> error
    end
  end

  @doc """
  Look up a record type implementation.
  """
  @spec lookup(record_type()) :: {:ok, record_module()} | {:error, :not_found}
  def lookup(type) when is_integer(type) do
    # Ensure the registry is initialized
    ensure_registry_initialized()

    try do
      case :ets.lookup(@type_table, type) do
        [{^type, module}] -> {:ok, module}
        [] -> {:error, :not_found}
      end
    rescue
      ArgumentError ->
        # Table doesn't exist, try to initialize and retry once
        ensure_registry_initialized()

        case :ets.lookup(@type_table, type) do
          [{^type, module}] -> {:ok, module}
          [] -> {:error, :not_found}
        end
    end
  end

  defp ensure_registry_initialized do
    # Use a loop with retry to handle race conditions in concurrent environments
    case initialize_table_with_retry(0) do
      :ok ->
        :ok

      {:error, :max_retries} ->
        raise "Failed to initialize registry table after multiple attempts"
    end
  end

  defp initialize_table_with_retry(attempt) when attempt < 3 do
    case :ets.whereis(@type_table) do
      :undefined ->
        try do
          :ets.new(@type_table, [:set, :public, :named_table, read_concurrency: true])
          init_builtin_types()
          :ok
        rescue
          ArgumentError ->
            # Table was created by another process, wait briefly and retry
            Process.sleep(1)
            initialize_table_with_retry(attempt + 1)
        end

      table when is_reference(table) or is_integer(table) ->
        # Table exists, ensure builtins are loaded (idempotent operation)
        init_builtin_types()
        :ok
    end
  end

  defp initialize_table_with_retry(_attempt), do: {:error, :max_retries}

  @doc """
  Get all registered record types.
  """
  @spec list_types() :: [{record_type(), record_module()}]
  def list_types do
    :ets.tab2list(@type_table)
  end

  @doc """
  Check if a type is registered.
  """
  @spec registered?(record_type()) :: boolean()
  def registered?(type) when is_integer(type) do
    case :ets.lookup(@type_table, type) do
      [] -> false
      _ -> true
    end
  end

  @doc """
  Initialize built-in record types.
  """
  @spec init_builtin_types() :: :ok
  def init_builtin_types do
    builtins = [
      # Standard record types
      {1, DNS.Message.Record.Data.A},
      {2, DNS.Message.Record.Data.NS},
      {5, DNS.Message.Record.Data.CNAME},
      {6, DNS.Message.Record.Data.SOA},
      {12, DNS.Message.Record.Data.PTR},
      {15, DNS.Message.Record.Data.MX},
      {16, DNS.Message.Record.Data.TXT},
      {28, DNS.Message.Record.Data.AAAA},
      {33, DNS.Message.Record.Data.SRV},

      # DNSSEC record types
      {43, DNS.Message.Record.Data.DNSKEY},
      {46, DNS.Message.Record.Data.RRSIG},
      {47, DNS.Message.Record.Data.NSEC},
      {48, DNS.Message.Record.Data.DS},
      {50, DNS.Message.Record.Data.NSEC3},
      {51, DNS.Message.Record.Data.NSEC3PARAM},

      # Security and application record types
      {257, DNS.Message.Record.Data.CAA},
      {52, DNS.Message.Record.Data.TLSA},
      {65, DNS.Message.Record.Data.HTTPS},
      {64, DNS.Message.Record.Data.SVCB}
    ]

    # Insert into ETS table with error handling for concurrent access
    Enum.each(builtins, fn {type, module} ->
      try do
        :ets.insert(@type_table, {type, module})
      rescue
        ArgumentError ->
          # Table doesn't exist or was deleted, that's okay in concurrent scenarios
          :ok
      end
    end)

    :ok
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for type registry
    @type_table = :ets.new(@type_table, [:set, :public, :named_table, read_concurrency: true])

    # Initialize built-in record types
    init_builtin_types()

    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, type, module}, _from, state) do
    # Validate that the module implements the required behaviour
    case validate_record_module(module) do
      :ok ->
        :ets.insert(@type_table, {type, module})
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Private functions

  defp validate_record_module(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, :module_not_loaded}

      not function_exported?(module, :record_type, 0) ->
        {:error, :missing_record_type}

      not function_exported?(module, :new, 1) ->
        {:error, :missing_new}

      not function_exported?(module, :from_iodata, 2) ->
        {:error, :missing_from_iodata}

      true ->
        :ok
    end
  end
end
