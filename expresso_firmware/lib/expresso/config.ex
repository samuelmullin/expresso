defmodule ExpressoFirmware.Config do
  @default_path "/root/expresso_config.json"

  def path, do: Application.get_env(:expresso_firmware, :config_path, @default_path)

  def load do
    case File.read(path()) do
      {:ok, contents} ->
        case Jason.decode(contents, keys: :atoms) do
          {:ok, map} -> {:ok, map}
          {:error, _} -> {:error, :invalid}
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, _reason} ->
        {:error, :not_found}
    end
  end

  def save(values) when is_map(values) do
    existing =
      case load() do
        {:ok, map} -> map
        _ -> %{}
      end

    merged = Map.merge(existing, values)
    tmp = path() <> ".tmp"

    with {:ok, json} <- Jason.encode(merged, pretty: true),
         :ok <- File.write(tmp, json),
         :ok <- File.rename(tmp, path()) do
      :ok
    end
  end
end
