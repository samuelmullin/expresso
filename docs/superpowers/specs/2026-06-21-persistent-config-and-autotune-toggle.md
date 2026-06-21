# Persistent Config and Autotune Toggle — Design Spec

**Date:** 2026-06-21
**Status:** Approved

---

## Goal

Add a persistent configuration layer so that PID gains, temperature setpoints, brew/steam tuning parameters, and the autotune toggle all survive reboots. When autotune is on, Lambda Tuning calculates gains at boot; when off, stored manual gains are used directly.

---

## Architecture

Two components:

1. **`ExpressoFirmware.Config`** — new pure-function module. Owns read/write of `/root/expresso_config.json`. No GenServer, no supervision. Called by the Controller at init and on relevant state changes.

2. **`ExpressoFirmware.Controller`** — modified. State gains new fields; mode transitions updated to swap between brew and steam gain sets; init reads from Config; save is triggered on changes to persisted keys.

---

## Config Module (`expresso_firmware/lib/expresso/config.ex`)

### Public API

```elixir
Config.load/0   → {:ok, map} | {:error, :not_found | :invalid}
Config.save/1   → :ok | {:error, reason}
Config.path/0   → "/root/expresso_config.json"   # overridable via app env for tests
```

### File format

JSON at `/root/expresso_config.json` (data partition — survives firmware updates).

All keys are optional. Missing keys fall back to the Controller's State struct defaults, so a fresh install with no file on disk works without special handling.

```json
{
  "autotune_enabled": true,
  "brew_kp": 0.82,
  "brew_ki": 0.015,
  "brew_kd": 0,
  "lambda_seconds": 10.0,
  "tau_seconds": 45.0,
  "process_gain": 1.0,
  "brew_setpoint": 101.0,
  "steam_setpoint": 155.0,
  "brew_cooling_compensation_c": 2.7,
  "brew_kp_multiplier": 1.2,
  "steam_kp": 0.75,
  "steam_ki": 0.01,
  "steam_kd": 0.0,
  "steam_lambda_seconds": 15.0
}
```

Active gains (`kp`, `ki`, `kd`) are not stored in the file — they are always derived from `brew_kp/ki/kd` at boot (since the controller always starts outside brew-boost and steam mode). This avoids redundant storage and drift between the two.

### Merge behaviour

`Config.save/1` accepts a partial map. Before writing, it merges the new values over the existing file contents so a save of `%{kp: 1.5}` does not erase `autotune_enabled`. Internally:

```
1. load existing file (or use empty map if not found)
2. Map.merge(existing, new_values)
3. JSON encode and write atomically (write to temp file, rename)
```

### Config path override (for tests)

```elixir
# config/test.exs
config :expresso_firmware, :config_path, "/tmp/expresso_test_config.json"
```

`Config.path/0` reads from application env, defaulting to `/root/expresso_config.json`.

---

## Controller Changes

### State struct — fields added

`base_kp` is renamed to `brew_kp`. Two new brew anchor fields (`brew_ki`, `brew_kd`) are added so steam-mode transitions can fully restore brew gains. `brew_cooling_compensation_c` and `brew_kp_multiplier` move from compile-time module attributes into State fields.

```elixir
# Renamed from base_kp — clean brew gains (without brew-phase boost)
brew_kp: 16.0,
brew_ki: 2.5,
brew_kd: 16.0,

# Steam mode gains
steam_kp: 0.75,
steam_ki: 0.01,
steam_kd: 0.0,
steam_lambda_seconds: 15.0,

# Moved from module attributes — now runtime-configurable
brew_cooling_compensation_c: 2.7,
brew_kp_multiplier: 1.2,

# New
autotune_enabled: true
```

The active gains (`kp`, `ki`, `kd`) remain. They are what the PID loop uses each cycle. The `brew_*` and `steam_*` fields are the sources of truth swapped in/out on mode transitions.

The module attributes `@brew_cooling_compensation_c` and `@brew_kp_multiplier` are removed.

### `init/1` flow

```
1. Open GPIO refs (unchanged)
2. Config.load() → merge file values (as keyword list) over compiled-in defaults
3. If autotune_enabled == true:
     {brew_kp, brew_ki, brew_kd} = calculate_lambda_gains(tau, lambda_seconds, process_gain)
     {steam_kp, steam_ki, steam_kd} = calculate_lambda_gains(tau, steam_lambda_seconds, process_gain)
     Inject all six into config, overwriting any stored values
   If autotune_enabled == false:
     Use kp/ki/kd/brew_kp/brew_ki/brew_kd/steam_* directly from file (or State defaults)
4. Set active kp/ki/kd = brew_kp/ki/kd (controller always starts in normal brew mode, not brew-boost or steam)
5. Construct State
6. Schedule first :control_loop
```

Log line on init:
```
"Controller init: autotune=#{enabled}, kp=#{kp}, ki=#{ki}, brew_setpoint=#{bp}°C, steam_setpoint=#{sp}°C"
```

### Mode transition gain table

| Event | `kp` | `ki` | `kd` | `setpoint` |
|---|---|---|---|---|
| Steam switch ON | `steam_kp` | `steam_ki` | `steam_kd` | `steam_setpoint` |
| Steam switch OFF | `brew_kp` | `brew_ki` | `brew_kd` | `brew_setpoint` |
| Brew switch ON | `brew_kp * brew_kp_multiplier` | `brew_ki` | `brew_kd` | `brew_setpoint + brew_cooling_compensation_c` |
| Brew switch OFF | `brew_kp` | `brew_ki` | `brew_kd` | `brew_setpoint` |
| `enable_pid` (brew switch off) | unchanged | unchanged | unchanged | unchanged |

All transitions also set `initialized: false` and reset `error_sum: 0.0`, `last_error: 0`.

### `autotune_lambda/1`

When `autotune_enabled == false`: returns `{:error, :autotune_disabled}`, no state change, no file write.

When `autotune_enabled == true`: recalculates both brew and steam gains using `state.tau_seconds`, `lambda_seconds` (caller-supplied), and `state.steam_lambda_seconds`. Updates `brew_kp/ki/kd` and `steam_kp/ki/kd`. Updates active `kp/ki/kd` to brew values (or steam values if currently in steam mode). Updates `base_kp → brew_kp` in state. Calls `Config.save/1`. Returns `{:ok, {brew_kp, brew_ki, brew_kd}}`.

### `set_config` behaviour

`handle_call({:set_config, new_config}, ...)` is updated to keep brew anchors in sync:

- If `new_config` includes `kp`: also set `brew_kp: new_config[:kp]`
- If `new_config` includes `ki`: also set `brew_ki: new_config[:ki]`
- If `new_config` includes `kd`: also set `brew_kd: new_config[:kd]`

After merging, call `Config.save/1` with the subset of persisted keys from the updated state.

The broken `set_config/2` (`key, value` 2-arity variant dispatching a 3-tuple) is removed — it has no matching handler and silently kills heater output.

### Save triggers

`Config.save/1` is called after:
- `handle_call({:set_config, ...})` — always (cheap, infrequent)
- `handle_call({:autotune_lambda, ...})` — on success only

Save is synchronous within the GenServer call (not fire-and-forget) so the caller knows if persistence failed. Config.save/1 failure is logged at `:error` level but does not crash the controller.

---

## Testing

### `Config` module (pure function tests, no GenServer)

- `load/0` on missing file → `{:error, :not_found}`
- `load/0` on valid file → `{:ok, map}` with correct values
- `load/0` on partial file (only some keys present) → returns `{:ok, map}` with only those keys; Controller merges over State struct defaults via `Keyword.merge`
- `load/0` on corrupt file → `{:error, :invalid}`
- `save/1` round-trips all keys
- `save/1` merges over existing file — does not erase unmentioned keys
- `path/0` reads from application env

### `Controller` (direct `handle_info`/`handle_cast` calls with synthetic State structs)

- Steam switch ON: active gains = steam gains, setpoint = steam_setpoint
- Steam switch OFF: active gains = brew gains, setpoint = brew_setpoint
- Brew switch ON: kp = brew_kp * multiplier, setpoint = brew_setpoint + compensation
- Brew switch OFF: kp = brew_kp restored
- `set_config(%{kp: 1.5})` updates brew_kp, kp, and calls save
- `autotune_lambda/1` with autotune_enabled: false → `{:error, :autotune_disabled}`
- `autotune_lambda/1` with autotune_enabled: true → updates both gain sets
- Init with autotune on: Lambda gains overwrite file gains
- Init with autotune off: file gains used as-is

Tests use a temp config path via application env so no real `/root/` writes occur.

---

## Files Changed

| File | Change |
|---|---|
| `expresso_firmware/lib/expresso/config.ex` | **Create** |
| `expresso_firmware/lib/expresso/controller.ex` | Modify: State, init, handlers, set_config |
| `expresso_firmware/test/expresso/config_test.exs` | **Create** |
| `expresso_firmware/test/expresso/controller_test.exs` | Modify: add new test cases |
| `expresso_firmware/test/expresso/controller_integration_test.exs` | Modify: update base_state helper |
| `expresso_firmware/config/test.exs` | Modify: add config_path override |

---

## Out of Scope

- `brew_cooling_compensation_c` auto-measurement from live temperature data (ADR Phase 3)
- Per-shot statistics or telemetry
- Web UI for config editing (separate concern)
- `autotune_enabled` per-mode (shared toggle only)
