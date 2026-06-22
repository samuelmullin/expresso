defmodule ExpressoFirmware.History do
  require Logger

  @default_path "/root/expresso_history.json"
  @mode_atoms %{"pid" => :pid, "disabled" => :disabled, "pwm" => :pwm}

  def path, do: Application.get_env(:expresso_firmware, :history_path, @default_path)

  def load do
    with {:ok, contents} <- File.read(path()),
         {:ok, parsed} when is_list(parsed) <- Jason.decode(contents) do
      {:ok, Enum.flat_map(parsed, &parse_sample/1)}
    else
      _ -> {:ok, []}
    end
  rescue
    reason ->
      Logger.error("History file load failed: #{inspect(reason)}")
      {:ok, []}
  end

  def save(samples) when is_list(samples) do
    tmp = path() <> ".tmp"
    json_samples = Enum.map(samples, &serialize_sample/1)

    with {:ok, json} <- Jason.encode(json_samples, pretty: false),
         :ok <- File.write(tmp, json),
         :ok <- File.rename(tmp, path()) do
      :ok
    end
  end

  defp serialize_sample(%{t: t, temp: temp, sp: sp, out: out, mode: mode}) do
    %{"t" => t, "temp" => temp, "sp" => sp, "out" => out, "mode" => Atom.to_string(mode)}
  end

  defp parse_sample(map) when is_map(map) do
    with {:ok, t} <- integer_value(map["t"]),
         {:ok, temp} <- float_value(map["temp"]),
         {:ok, sp} <- float_value(map["sp"]),
         {:ok, out} <- integer_value(map["out"]),
         {:ok, mode} <- mode_atom(map["mode"]) do
      [%{t: t, temp: temp, sp: sp, out: out, mode: mode}]
    else
      _ -> []
    end
  end

  defp parse_sample(_), do: []

  defp integer_value(value) when is_integer(value), do: {:ok, value}
  defp integer_value(value) when is_float(value), do: {:ok, trunc(value)}
  defp integer_value(_), do: :error

  defp float_value(value) when is_integer(value), do: {:ok, value * 1.0}
  defp float_value(value) when is_float(value), do: {:ok, value}
  defp float_value(_), do: :error

  defp mode_atom(mode) when is_binary(mode), do: Map.fetch(@mode_atoms, mode)
  defp mode_atom(_), do: :error
end
