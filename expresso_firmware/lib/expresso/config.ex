defmodule ExpressoFirmware.Config do
  require Logger

  @default_path "/root/expresso_config.json"

  # Only these string keys are ever converted to atoms, preventing arbitrary atom creation
  # from hand-edited or malformed config files.
  @safe_keys ~w(autotune_enabled brew_kp brew_ki brew_kd lambda_seconds
                tau_seconds process_gain brew_setpoint steam_setpoint
                brew_cooling_compensation_c brew_kp_multiplier
                steam_kp steam_ki steam_kd steam_lambda_seconds)

  def path, do: Application.get_env(:expresso_firmware, :config_path, @default_path)

  def load do
    case File.read(path()) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, map} ->
            result =
              map
              |> Map.take(@safe_keys)
              |> Map.new(fn {k, v} -> {String.to_atom(k), v} end)

            {:ok, result}

          {:error, _} ->
            {:error, :invalid}
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        Logger.error("Config file read failed: #{inspect(reason)}")
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
