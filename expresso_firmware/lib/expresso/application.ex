defmodule ExpressoFirmware.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ExpressoFirmware.Supervisor]

    children =
      [
        # Children for all targets
        # Starts a worker by calling: Expresso.Worker.start_link(arg)
        # {ExpressoFirmware.Worker, arg},
        {Max31865.Server, [rtd_wires: 3, spi_device_cs_pin: 0]},
        ExpressoFirmware.PID,
        ExpressoFirmware.StubHeater,
      ] ++ children(target())

    Supervisor.start_link(children, opts)
  end

  # List all child processes to be supervised
  def children(:host) do
    [
    ]
  end

  def children(_target) do
    [
    ]
  end

  def target() do
    Application.get_env(:expresso_firmware, :target)
  end
end
