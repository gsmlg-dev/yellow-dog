defmodule YellowDog.Store.CLI do
  @moduledoc """
  Release CLI command dispatcher for backup operations.

  Invoked via:

      bin/yellow_dog eval "YellowDog.Store.CLI.main([\\"backup\\", \\"create\\"])"

  Or via the wrapper script:

      bin/yellow_dog_cli backup create --label nightly
      bin/yellow_dog_cli backup restore --file ./backups/2026-03-13.backup --yes
      bin/yellow_dog_cli backup list
  """

  alias YellowDog.Store.Backup

  @doc "Main entry point for CLI commands."
  @spec main([String.t()]) :: :ok
  def main(["backup" | args]), do: handle_backup(args)
  def main(args), do: IO.puts("Unknown command: #{inspect(args)}")

  # ── Backup Commands ─────────────────────────────────────────────

  defp handle_backup(["create" | args]) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [dir: :string, label: :string],
        aliases: [d: :dir, l: :label]
      )

    case Backup.create(opts) do
      {:ok, path} ->
        IO.puts("Backup created: #{path}")
        size = file_size(path)
        IO.puts("Size: #{format_bytes(size)}")

      {:error, reason} ->
        IO.puts("Error: #{inspect(reason)}")
    end
  end

  defp handle_backup(["restore" | args]) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [file: :string, yes: :boolean, verify_only: :boolean],
        aliases: [f: :file, y: :yes]
      )

    file = Keyword.get(opts, :file)

    if is_nil(file) do
      IO.puts("Error: --file is required")
    else
      confirm = Keyword.get(opts, :yes, false)
      verify_only = Keyword.get(opts, :verify_only, false)

      if not confirm and not verify_only do
        IO.puts("This will overwrite all current data. Use --yes to confirm.")
      else
        case Backup.restore(file, confirm: confirm, verify_only: verify_only) do
          {:ok, stats} ->
            IO.puts("Restore complete: #{inspect(stats)}")

          {:error, :confirm_required} ->
            IO.puts("Restore requires --yes flag.")

          {:error, reason} ->
            IO.puts("Error: #{inspect(reason)}")
        end
      end
    end
  end

  defp handle_backup(["list" | args]) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [dir: :string],
        aliases: [d: :dir]
      )

    case Backup.list(opts) do
      {:ok, backups} ->
        if backups == [] do
          IO.puts("No backups found.")
        else
          IO.puts(
            String.pad_trailing("Filename", 50) <>
              String.pad_trailing("Timestamp", 25) <>
              String.pad_trailing("Size", 12) <>
              "Entries"
          )

          IO.puts(String.duplicate("-", 100))

          Enum.each(backups, fn backup ->
            IO.puts(
              String.pad_trailing(Path.basename(backup.path), 50) <>
                String.pad_trailing(to_string(backup.timestamp), 25) <>
                String.pad_trailing(format_bytes(backup.size_bytes), 12) <>
                to_string(Map.get(backup, :entry_count, "?"))
            )
          end)
        end

      {:error, reason} ->
        IO.puts("Error: #{inspect(reason)}")
    end
  end

  defp handle_backup(args) do
    IO.puts("Unknown backup command: #{inspect(args)}")
    IO.puts("Available: create, restore, list")
  end

  # ── Helpers ─────────────────────────────────────────────────────

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"
end
