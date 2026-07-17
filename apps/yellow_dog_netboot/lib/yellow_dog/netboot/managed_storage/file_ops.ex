defmodule YellowDog.Netboot.ManagedStorage.FileOps do
  @moduledoc false

  @callback read(Path.t(), term()) :: {:ok, binary()} | {:error, term()}
  @callback size(Path.t(), term()) :: {:ok, non_neg_integer()} | {:error, term()}
  @callback mkdir_p(Path.t(), term()) :: :ok | {:error, term()}
  @callback open(Path.t(), term()) :: {:ok, term()} | {:error, term()}
  @callback write(term(), binary(), term()) :: :ok | {:error, term()}
  @callback sync(term(), term()) :: :ok | {:error, term()}
  @callback close(term(), term()) :: :ok | {:error, term()}
  @callback rename(Path.t(), Path.t(), term()) :: :ok | {:error, term()}
  @callback rm(Path.t(), term()) :: :ok | {:error, term()}

  def read(path, _context), do: File.read(path)

  def size(path, _context) do
    with {:ok, stat} <- File.stat(path) do
      {:ok, stat.size}
    end
  end

  def mkdir_p(path, _context), do: File.mkdir_p(path)
  def open(path, _context), do: File.open(path, [:write, :exclusive, :binary])
  def write(device, contents, _context), do: IO.binwrite(device, contents)
  def sync(device, _context), do: :file.sync(device)
  def close(device, _context), do: File.close(device)
  def rename(source, target, _context), do: File.rename(source, target)
  def rm(path, _context), do: File.rm(path)
end
