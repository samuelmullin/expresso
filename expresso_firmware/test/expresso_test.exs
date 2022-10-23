defmodule ExpressoFirmwareTest do
  use ExUnit.Case
  doctest ExpressoFirmware

  test "greets the world" do
    assert ExpressoFirmware.hello() == :world
  end
end
