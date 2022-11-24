# This file is responsible for configuring your application and its
# dependencies.
#
# This configuration file is loaded before any dependency and is restricted to
# this project.
import Config

# Enable the Nerves integration with Mix
Application.start(:nerves_bootstrap)

config :expresso_firmware, target: Mix.target()

# Customize non-Elixir parts of the firmware. See
# https://hexdocs.pm/nerves/advanced-configuration.html for details.

config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"

# Set the SOURCE_DATE_EPOCH date for reproducible builds.
# See https://reproducible-builds.org/docs/source-date-epoch/ for more information

config :nerves, source_date_epoch: "1662989430"

# Use Ringlogger as the logger backend and remove :console.
# See https://hexdocs.pm/ring_logger/readme.html for more information on
# configuring ring_logger.

config :logger, backends: [RingLogger]

config :expresso_ui,
  controller_module: ExpressoFirmware.Controller

config :expresso_firmware,
  brew_switch_pin: 27,
  steam_switch_pin: 17

config :expresso_ui, ExpressoUiWeb.Endpoint,
  url: [host: "expresso.local"],
  http: [port: 80],
  cache_static_manifest: "priv/static/cache_manifest.json",
  secret_key_base: "8zkQ66jLWTAJNfsaKMOQfL1DquFzJb9tCuGBLm11MqHkV8RJsOslexi7XAS84Fu4",
  live_view: [signing_salt: "T8JB2Lqmlk/v1NI7gDl3EjLXotON7+5W"],
  check_origin: false,
  render_errors: [view: ExpressoUiWeb.ErrorView, accepts: ~w(html json), layout: false],
  pubsub_server: ExpressoUi.PubSub,
  # Start the server since we're running in a release instead of through `mix`
  server: true,
  # Nerves root filesystem is read-only, so disable the code reloader
  code_reloader: false

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end
