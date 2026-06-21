defmodule ExpressoFirmware.HistoryTest do
  use ExUnit.Case
  alias ExpressoFirmware.History

  setup do
    tmp_path = Path.join(System.tmp_dir!(), "expresso_history_test_#{System.unique_integer()}.json")
    prev = Application.get_env(:expresso_firmware, :history_path)
    Application.put_env(:expresso_firmware, :history_path, tmp_path)

    on_exit(fn ->
      File.rm(tmp_path)
      File.rm(tmp_path <> ".tmp")
      if is_nil(prev),
        do: Application.delete_env(:expresso_firmware, :history_path),
        else: Application.put_env(:expresso_firmware, :history_path, prev)
    end)

    {:ok, path: tmp_path}
  end

  @sample %{t: 1_000_000, temp: 95.1, sp: 93.5, out: 45, mode: :pid}
  @sample2 %{t: 1_001_000, temp: 95.3, sp: 93.5, out: 40, mode: :disabled}

  test "load returns empty list when file does not exist" do
    assert {:ok, []} = History.load()
  end

  test "load returns empty list for corrupt JSON" do
    File.write!(History.path(), "not json {{{")
    assert {:ok, []} = History.load()
  end

  test "load returns empty list for valid JSON that is not an array" do
    File.write!(History.path(), ~s({"mode": "pid"}))
    assert {:ok, []} = History.load()
  end

  test "load returns empty list for valid JSON array with bad samples" do
    File.write!(History.path(), ~s([{"unknown": 1}]))
    assert {:ok, []} = History.load()
  end

  test "save and load round-trips a single sample" do
    assert :ok = History.save([@sample])
    assert {:ok, [loaded]} = History.load()
    assert loaded.t == @sample.t
    assert_in_delta loaded.temp, @sample.temp, 0.0001
    assert_in_delta loaded.sp, @sample.sp, 0.0001
    assert loaded.out == @sample.out
    assert loaded.mode == @sample.mode
  end

  test "save and load round-trips multiple samples preserving order" do
    assert :ok = History.save([@sample, @sample2])
    assert {:ok, [first, second]} = History.load()
    assert first.t == @sample.t
    assert second.t == @sample2.t
    assert second.mode == :disabled
  end

  test "save overwrites previous history (not merge)" do
    assert :ok = History.save([@sample, @sample2])
    assert :ok = History.save([@sample])
    assert {:ok, [_only_one]} = History.load()
  end

  test "save writes atomically (via rename, no leftover .tmp file)" do
    assert :ok = History.save([@sample])
    refute File.exists?(History.path() <> ".tmp")
    assert File.exists?(History.path())
  end

  test "load filters out samples with unknown keys (no atom creation)" do
    File.write!(History.path(), ~s([{"t":1,"temp":95.0,"sp":93.5,"out":45,"mode":"pid","extra_unknown_key":999}]))
    assert {:ok, [sample]} = History.load()
    refute Map.has_key?(sample, :extra_unknown_key)
    assert sample.mode == :pid
  end

  test "path/0 reads from application env" do
    custom = "/tmp/custom_history.json"
    Application.put_env(:expresso_firmware, :history_path, custom)
    assert History.path() == custom
  end
end
