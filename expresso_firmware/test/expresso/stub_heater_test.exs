defmodule ExpressoFirmware.StubHeaterTest do
  use ExUnit.Case

  alias ExpressoFirmware.StubHeater

  test "uses its opened GPIO ref when turning the simulated heater on and off" do
    {:ok, output_ref} = Circuits.GPIO.open(12, :output, initial_value: 0)
    state = %StubHeater.HeaterState{output_ref: output_ref, output: 10}

    assert {:noreply, %{heater: :on}} = StubHeater.handle_info(:pid_loop, state)
    assert {:noreply, %{heater: :off}} = StubHeater.handle_info({:heater_off, 10}, state)
  end
end
