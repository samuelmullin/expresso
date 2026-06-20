defmodule ExpressoFirmware.ControllerTest do
  use ExUnit.Case

  alias ExpressoFirmware.Controller

  defmodule TestHeater do
    def set_output(output, max_output) do
      send(ExpressoFirmware.ControllerTest, {:set_output, output, max_output})
      :ok
    end
  end

  setup do
    previous_heater = Application.get_env(:expresso_firmware, :heater_module)
    Application.put_env(:expresso_firmware, :heater_module, TestHeater)
    Process.register(self(), __MODULE__)

    on_exit(fn ->
      if is_nil(previous_heater) do
        Application.delete_env(:expresso_firmware, :heater_module)
      else
        Application.put_env(:expresso_firmware, :heater_module, previous_heater)
      end

      if Process.whereis(__MODULE__) == self() do
        Process.unregister(__MODULE__)
      end
    end)
  end

  test "defaults brew switch PWM output to 30 percent" do
    assert %Controller.State{brew_pwm_output: 30.0} = %Controller.State{}
  end

  test "is supervised as a permanent worker" do
    assert %{restart: :permanent, type: :worker} = Controller.child_spec([])
  end

  test "forces heater output off when the controller terminates" do
    state = %Controller.State{max_output: 100}

    assert :ok = Controller.terminate(:sensor_failure, state)
    assert_receive {:set_output, 0, 100}
  end
end
