# WAREMA Slat Control Script

A lightweight shell script for controlling a WAREMA Lamaxa slat roof via the WMS WebControl Pro JSON API.

## Overview

Communicates directly with the WMS WebControl Pro gateway over HTTP — no external libraries required. Supports reading live device status, weather-sensor safety holds, and jog (impulse) control in addition to absolute angle positioning.

## Features

- **Angle control**: set 0–100% (0 = closed, 100 = open) or send raw values for calibration
- **Live status readback**: reads actual rotation and driving cause from the device when radio status is fresh
- **Weather safety hold**: blocks set commands when Rain/Wind/Ice/Safety triggered the last move
- **Impulse / jog**: step one increment open or closed without setting an absolute target
- **Driving cause visibility**: exposes what last triggered movement (Sun, Rain, Wind, Manual…)
- **Configurable range**: tune `SLAT_MIN_RAW` / `SLAT_MAX_RAW` to match your physical endpoints
- **Silent by default**: no stdout noise unless asked; `get` outputs a single integer

## Requirements

- `bash` 4.0+
- `curl`
- `bc`
- `python3` (for JSON parsing in status readback)
- Network access to the WMS WebControl Pro host

## Configuration

Copy and edit `.env`:

```bash
WAREMA_HOST=10.10.1.229   # WebControl Pro IP
DEVICE_ID=57789            # Lamaxa wenden destination ID
ACTION_ID=6                # SlatRotate action
STOP_ACTION_ID=16          # Stop action
IMPULSE_ACTION_ID=23       # Impulse (jog) action
TIMEOUT=10                 # curl timeout in seconds

# Tune these to match your physical endpoints (use `raw` + `status` to calibrate)
SLAT_MIN_RAW=-45           # raw value at 0%  (fully closed)
SLAT_MAX_RAW=90            # raw value at 100% (fully open)
```

## Usage

```bash
./warema_slat.sh <command> [options]
```

### Commands

| Command | Description |
| --- | --- |
| `<percentage>` | Set slat angle 0–100 |
| `raw <value>` | Send raw rotation value (-127 to 127), for calibration |
| `get` | Current position as integer (live if available, cached otherwise) |
| `status` | Full status: position, driving cause, health flags |
| `stop` | Halt current movement |
| `impulse up\|down` | Jog one step open or closed |
| `devices` | Dump full device configuration JSON |

### Options

| Flag | Description |
| --- | --- |
| `-v, --verbose` | Verbose output to stderr |
| `-s, --silent` | No output (default for set operations) |
| `-d, --device ID` | Override device ID |
| `-H, --host HOST` | Override host |
| `--force` | Override a Rain/Wind/Ice safety hold |

### Examples

```bash
# Control
./warema_slat.sh 0             # close (silent)
./warema_slat.sh 75            # set to 75%
./warema_slat.sh 75 --verbose  # same, with feedback
./warema_slat.sh stop          # halt motor

# Fine control
./warema_slat.sh impulse up    # jog open one step
./warema_slat.sh impulse down  # jog closed one step

# Calibration
./warema_slat.sh raw -40       # send raw value directly
./warema_slat.sh status        # read back actual position + cause

# Read position
./warema_slat.sh get           # → 75

# Override safety hold (e.g. after rain stopped)
./warema_slat.sh 75 --force
```

## Position Mapping

The percentage is mapped linearly to the raw rotation range:

```text
raw = (percentage / 100) × (SLAT_MAX_RAW − SLAT_MIN_RAW) + SLAT_MIN_RAW
```

Default calibration (adjust `SLAT_MIN_RAW` / `SLAT_MAX_RAW` in `.env`):

| %   | Raw | Physical     |
| --- | --- | ------------ |
| 0   | -45 | Fully closed |
| 50  | 22  | Half open    |
| 100 | 90  | Fully open   |

**Calibrating**: use `./warema_slat.sh raw <value> --verbose` to try a value, then `./warema_slat.sh status` to read back where the motor actually stopped. Adjust `SLAT_MIN_RAW` / `SLAT_MAX_RAW` accordingly.

## Status and Rain Sensor Integration

`getStatus` (with `responseType: 1`) returns the current rotation and what last triggered movement:

```bash
$ ./warema_slat.sh status
position: 75% (raw: 56)
drivingCause: 0 (None)
heartbeatError: false
blocking: false
```

### Driving cause codes

| ID   | Name            | Triggered by          |
| ---- | --------------- | --------------------- |
| 0    | None            | No cause / API command |
| 1    | Sun             | WMS sun sensor        |
| 2    | Dusk/Dawn       | Time-based automation |
| **3** | **Wind**       | WMS wind sensor       |
| **4** | **Rain**       | WMS rain sensor       |
| **5** | **Ice**        | Freeze protection     |
| 6    | Temperature     | Temperature sensor    |
| 7    | SwitchingTime   | Scheduled timer       |
| 8    | Scene           | Scene executed        |
| 9    | ControlMode     | Mode change           |
| 10   | Manual          | Physical remote       |
| **11** | **Safety**    | Safety override       |
| 12   | Contact         | Contact sensor        |
| 13   | CentralCommand  | Central system        |

### Safety hold

When the WMS system closes the roof due to rain, wind, ice, or a safety event, the `drivingCause` is set accordingly. The script refuses to override these automatically:

```bash
$ ./warema_slat.sh 75
ERROR: Blocked: device is under Rain safety hold (drivingCause=4). Use --force to override.
```

Use `--force` only once you've confirmed conditions are safe:

```bash
./warema_slat.sh 75 --force
```

**Note**: `getStatus` is intermittent — the WMS gateway only has fresh status when the SlatRoof device last sent a radio update. When unavailable, `get` falls back to the last value sent by this script, and the safety check is skipped (not blocked).

### Rain automation example

```bash
#!/bin/bash
# Called by your external rain sensor or home automation

CAUSE=$(./warema_slat.sh status 2>/dev/null | awk '/drivingCause/ {print $2}')
if [[ "$CAUSE" == "4" ]]; then
    echo "Rain hold active — not overriding"
    exit 0
fi

./warema_slat.sh "$1"   # e.g. 0 to close, 75 to open to sun position
```

## Home Assistant Integration

Use the [command_line](https://www.home-assistant.io/integrations/command_line/) integration with a `cover` entity:

```yaml
cover:
  - platform: command_line
    name: Lamaxa Slat Roof
    command_open: "/path/to/warema_slat.sh 100"
    command_close: "/path/to/warema_slat.sh 0"
    command_stop: "/path/to/warema_slat.sh stop"
    command_state: "/path/to/warema_slat.sh get"
    value_template: "{{ value }}"
    position_template: "{{ value }}"
    command_set_position: "/path/to/warema_slat.sh {{ position }}"
    scan_interval: 30
```

## API Reference

**Endpoint**: `POST http://{host}/commonCommand`  
**Auth**: none (local network only)  
**Protocol version**: `1.0`  
**Source**: always `2`

### API Commands

| Command | Key parameters | Notes |
| --- | --- | --- |
| `ping` | — | Returns `{"status": 0}` on success |
| `getConfiguration` | — | Returns all devices, rooms, scenes |
| `getStatus` | `responseType: 1`, `destinations: [id]` | **Must include `responseType: 1`** or returns error |
| `action` | `responseType: 0`, `actions: [...]` | Use `responseType: 0` (Instant) for speed |
| `sceneActions` | `sceneId`, `sceneActionType` | Execute or relearn a scene |

### getStatus — correct form

```json
{
  "protocolVersion": "1.0",
  "command": "getStatus",
  "source": 2,
  "responseType": 1,
  "destinations": [57789]
}
```

> **Important**: omitting `responseType: 1` causes error `327684` on SlatRoof devices.

**Response when fresh:**
```json
{
  "command": "getStatus",
  "protocolVersion": "1.0.0",
  "details": [{
    "destinationId": 57789,
    "data": {
      "drivingCause": 4,
      "heartbeatError": false,
      "blocking": false,
      "productData": [
        {"actionId": 6,  "value": {"rotation": -40}},
        {"actionId": 23, "value": {"rotation": -40}}
      ]
    }
  }]
}
```

### Device actions (id=57789, Lamaxa wenden)

| Action ID | Type | Description | Parameters |
| --- | --- | --- | --- |
| 6 | Rotation (2) | SlatRotate | `{"rotation": -127…127}` |
| 16 | Stop (6) | ManualCommand | `{}` |
| 22 | Identify (8) | Identify | `{}` |
| 23 | Impulse (7) | ManualCommand | `{"impulse": 0}` up / `{"impulse": 1}` down |

### Error codes

| Code | Hex | Meaning |
| --- | --- | --- |
| 327681 | 0x50001 | Unknown |
| 327682 | 0x50002 | Invalid action parameters |
| 327683 | 0x50003 | Missing required field |
| 327684 | 0x50004 | Destination unavailable / status stale |

## Troubleshooting

**`getStatus` always returns error 327684**  
Include `"responseType": 1` in the request. If still failing, the WMS gateway doesn't have fresh radio status yet — try again after the device moves or wait for its next heartbeat.

**Position reported by `status` doesn't match what was commanded**  
The SlatRoof motor has mechanical tolerance (~5 raw units). Calibrate `SLAT_MIN_RAW` and `SLAT_MAX_RAW` using `raw` + `status` to find the actual physical endpoints.

**Set command blocked with "safety hold"**  
The Warema rain/wind/ice sensor triggered a protective close. Wait for conditions to clear or use `--force`.

**Device not found / ping fails**  
Verify `WAREMA_HOST` in `.env` and check network connectivity with `ping 10.10.1.229`.

## References

- [Official WMS WebControl Pro API Documentation (PDF)](https://media.warema.com/dokumente/anleitungen-handbuecher/966664/warema_2064534_alhb_de_v0.pdf)
- [pywmspro Python library](https://github.com/mback2k/pywmspro) — reference implementation
