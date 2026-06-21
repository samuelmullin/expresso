defmodule ExpressoFirmware.ConfigTest do
  use ExUnit.Case

  alias ExpressoFirmware.Config

  setup do
    tmp_path = Path.join(System.tmp_dir!(), "expresso_test_#{System.unique_integer()}.json")
    prev = Application.get_env(:expresso_firmware, :config_path)
    Application.put_env(:expresso_firmware, :config_path, tmp_path)

    on_exit(fn ->
      File.rm(tmp_path)
      File.rm(tmp_path <> ".tmp")
      if is_nil(prev) do
        Application.delete_env(:expresso_firmware, :config_path)
      else
        Application.put_env(:expresso_firmware, :config_path, prev)
      end
    end)

    {:ok, path: tmp_path}
  end

  test "load returns :not_found when file does not exist" do
    assert {:error, :not_found} = Config.load()
  end

  test "load returns parsed map when file exists" do
    File.write!(Config.path(), ~s({"autotune_enabled":false,"brew_kp":1.5}))
    assert {:ok, %{autotune_enabled: false, brew_kp: 1.5}} = Config.load()
  end

  test "load returns :invalid for corrupt JSON" do
    File.write!(Config.path(), "not json {{{")
    assert {:error, :invalid} = Config.load()
  end

  test "save round-trips all persisted keys" do
    values = %{
      autotune_enabled: true,
      brew_kp: 0.82,
      brew_ki: 0.015,
      brew_kd: 0.0,
      lambda_seconds: 10.0,
      tau_seconds: 45.0,
      process_gain: 1.0,
      brew_setpoint: 93.5,
      steam_setpoint: 155.0,
      brew_cooling_compensation_c: 2.7,
      brew_kp_multiplier: 1.2,
      steam_kp: 0.75,
      steam_ki: 0.0125,
      steam_kd: 0.0,
      steam_lambda_seconds: 15.0
    }

    assert :ok = Config.save(values)
    assert {:ok, loaded} = Config.load()

    Enum.each(values, fn {k, v} ->
      if is_number(v) do
        assert_in_delta loaded[k], v, 0.0001, "key #{k} mismatch"
      else
        assert loaded[k] == v, "key #{k} mismatch"
      end
    end)
  end

  test "save merges over existing file — does not erase unmentioned keys" do
    File.write!(Config.path(), ~s({"autotune_enabled":true,"brew_kp":0.82}))
    assert :ok = Config.save(%{brew_kp: 1.5})
    assert {:ok, map} = Config.load()
    assert map[:autotune_enabled] == true
    assert_in_delta map[:brew_kp], 1.5, 0.0001
  end

  test "save writes atomically (via rename)" do
    assert :ok = Config.save(%{brew_kp: 0.82})
    refute File.exists?(Config.path() <> ".tmp")
    assert File.exists?(Config.path())
  end

  test "path/0 reads from application env" do
    custom = "/tmp/custom_expresso.json"
    Application.put_env(:expresso_firmware, :config_path, custom)
    assert Config.path() == custom
  end
end
