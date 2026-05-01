# WMS WebControl Pro API Reference

Based on live reverse engineering against device `10.10.1.229`, the official API documentation PDF (`warema_2064534_alhb_de_v0.pdf`), and the [pywmspro](https://github.com/mback2k/pywmspro) Python library.

---

## Transport

- **Endpoint**: `POST http://{host}/commonCommand`
- **Content-Type**: `application/json`
- **Auth**: none — local network only
- **Protocol version**: `"1.0"` (response echoes `"1.0.0"`)
- **Source**: always `2`

Every request includes:

```json
{
  "protocolVersion": "1.0",
  "command": "<name>",
  "source": 2,
  "<additional fields>": "..."
}
```

---

## Commands

### ping

Test gateway connectivity.

**Request:**

```json
{
  "protocolVersion": "1.0",
  "command": "ping",
  "source": 2
}
```

**Response:**

```json
{
  "command": "ping",
  "protocolVersion": "1.0.0",
  "status": 0
}
```

---

### getConfiguration

Returns all configured devices (destinations), rooms, and scenes. Use this to discover destination IDs and available action IDs.

**Request:**

```json
{
  "protocolVersion": "1.0",
  "command": "getConfiguration",
  "source": 2
}
```

**Response (Lamaxa wenden — this device):**

```json
{
  "command": "getConfiguration",
  "protocolVersion": "1.0.0",
  "destinations": [
    {
      "id": 57789,
      "animationType": 3,
      "names": ["Lamaxa wenden", "", "", ""],
      "actions": [
        {"id": 6,  "actionType": 2, "actionDescription": 3, "minValue": -127, "maxValue": 127},
        {"id": 16, "actionType": 6, "actionDescription": 12},
        {"id": 22, "actionType": 8, "actionDescription": 13},
        {"id": 23, "actionType": 7, "actionDescription": 12}
      ]
    }
  ],
  "rooms": [
    {"id": 26759, "name": "Terrasse", "destinations": [57789], "scenes": []}
  ],
  "scenes": []
}
```

---

### getStatus

Returns live device state: current rotation, what last triggered movement (`drivingCause`), and health flags.

> **Critical**: must include `"responseType": 1`. Without it, SlatRoof devices return error `327684`.
>
> **Intermittent**: the WMS gateway only has fresh status when the device last sent a radio heartbeat. On error, retry after the device moves or wait for the next heartbeat cycle.

**Request:**

```json
{
  "protocolVersion": "1.0",
  "command": "getStatus",
  "source": 2,
  "responseType": 1,
  "destinations": [57789]
}
```

**Response (success):**

```json
{
  "command": "getStatus",
  "protocolVersion": "1.0.0",
  "details": [
    {
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
    }
  ]
}
```

**Response (status unavailable):**

```json
{"protocolVersion": "1.0.0", "command": "getStatus", "errors": [327684]}
```

#### drivingCause values

| ID | Name | Description |
| --- | --- | --- |
| 0 | None | No trigger / API command |
| 1 | Sun | WMS sun sensor |
| 2 | Dusk/Dawn | Time-based automation |
| 3 | Wind | WMS wind sensor |
| 4 | Rain | WMS rain sensor |
| 5 | Ice | Freeze protection |
| 6 | Temperature | Temperature sensor |
| 7 | SwitchingTime | Scheduled timer |
| 8 | Scene | Scene execution |
| 9 | ControlMode | Control mode change |
| 10 | Manual | Physical remote control |
| 11 | Safety | Safety override |
| 12 | Contact | Contact sensor |
| 13 | CentralCommand | Central system command |
| 999 | Unknown | Unrecognised |

---

### action

Send a control command to one or more destinations. Multiple actions targeting the **same** destination can be batched in one request.

**Request:**

```json
{
  "protocolVersion": "1.0",
  "command": "action",
  "source": 2,
  "responseType": 0,
  "actions": [
    {
      "destinationId": 57789,
      "actionId": 6,
      "parameters": {"rotation": 22}
    }
  ]
}
```

**Response:**

```json
{"command": "action", "protocolVersion": "1.0.0"}
```

#### responseType

| Value | Name | Behaviour |
| --- | --- | --- |
| 0 | Instant | Returns as soon as the gateway receives the command (~70 ms). **Use this.** |
| 1 | Detailed | Waits for radio acknowledgment from device. Falls back to Instant if unsupported. |

#### Action parameters by actionType

| actionType | Name | Parameter key | Range / Values |
| --- | --- | --- | --- |
| 0 | Percentage | `percentage` | 0–100 |
| 1 | PercentageDelta | `percentageDelta` | -100–100 |
| 2 | Rotation | `rotation` | -360–360 (device reports -127–127) |
| 3 | RotationDelta | `rotationDelta` | -720–720 |
| 4 | Switch | `onOffState` | `true` / `false` |
| 5 | Toggle | *(none)* | — |
| 6 | Stop | *(none)* | — |
| 7 | Impulse | `impulse` | `0` = Up, `1` = Down |
| 8 | Identify | *(none)* | — |
| 9 | Enumeration | `enumeration` | 0–16 (see table below) |

#### Enumeration values (potential-free actor devices)

| Value | Action |
| --- | --- |
| 0 | No action |
| 1 | Short run up |
| 2 | Short run down |
| 3 | Long run up |
| 4 | Long run down |
| 5 | Continuous up |
| 6 | Continuous down |
| 7 | Toggle run up |
| 8 | Toggle run down |
| 9 | Up and down off |
| 10 | Toggle up and down simultaneously |
| 11 | Continuous up and down simultaneously |
| 12 | Up off |
| 13 | Down off |
| 14 | Short run in reverse |
| 15 | Toggle up |
| 16 | Toggle down |

---

### sceneActions

Execute or relearn a configured scene.

**Request:**

```json
{
  "protocolVersion": "1.0",
  "command": "sceneActions",
  "source": 2,
  "responseType": 0,
  "sceneId": 688966,
  "sceneActionType": 1
}
```

| sceneActionType | Meaning |
| --- | --- |
| 0 | Relearn (save current positions into scene) |
| 1 | Execute scene |

---

## Device: Lamaxa wenden (id 57789)

- **Type**: animationType 3 — SlatRoof
- **Room**: Terrasse (id 26759)

### Actions

| ID | actionType | actionDescription | Parameters | Notes |
| --- | --- | --- | --- | --- |
| 6 | 2 (Rotation) | 3 (SlatRotate) | `{"rotation": N}` | N in -127…127; physical range ~-40…90 |
| 16 | 6 (Stop) | 12 (ManualCommand) | `{}` | Halts movement immediately |
| 22 | 8 (Identify) | 13 (Identify) | `{}` | Device identification (jog) |
| 23 | 7 (Impulse) | 12 (ManualCommand) | `{"impulse": 0\|1}` | 0 = open direction, 1 = close direction |

### Raw value calibration

The `rotation` parameter is a dimensionless integer, not degrees. Empirical measurements on this device:

| Commanded | Reported | Notes |
| --- | --- | --- |
| -45 | -40 | Physical minimum (fully closed) |
| 0 | 0 | |
| 22 | 22 | ~50% open |
| 90 | ~90 | Physical maximum (fully open) |

Tolerance is approximately ±5 raw units. Adjust `SLAT_MIN_RAW` / `SLAT_MAX_RAW` in `.env` to match your physical endpoints.

---

## Type Reference

### AnimationType

| ID | Name |
| --- | --- |
| 0 | VenetianBlind |
| 1 | Awning |
| 2 | RollerShutterBlind |
| 3 | SlatRoof |
| 4 | Window |
| 5 | Switch |
| 6 | Dimmer |
| 999 | Unknown |

### ActionType

| ID | Name |
| --- | --- |
| 0 | Percentage |
| 1 | PercentageDelta |
| 2 | Rotation |
| 3 | RotationDelta |
| 4 | Switch |
| 5 | Toggle |
| 6 | Stop |
| 7 | Impulse |
| 8 | Identify |
| 9 | Enumeration |
| 999 | Unknown |

### ActionDescription

| ID | Name |
| --- | --- |
| 0 | AwningDrive |
| 1 | ValanceDrive |
| 2 | SlatDrive |
| 3 | SlatRotate |
| 4 | RollerShutterBlindDrive |
| 5 | WindowDrive |
| 6 | LightSwitch |
| 7 | LoadSwitch |
| 8 | LightDimming |
| 9 | LoadDimming |
| 10 | LightToggle |
| 11 | LastToggle |
| 12 | ManualCommand |
| 13 | Identify |
| 999 | Unknown |

---

## Error Codes

| Code | Hex | Observed when |
| --- | --- | --- |
| 327681 | 0x50001 | Unknown |
| 327682 | 0x50002 | Impulse action sent without required `impulse` parameter |
| 327683 | 0x50003 | getStatus missing required field (e.g. no `destinations`) |
| 327684 | 0x50004 | getStatus: destination unreachable, radio status stale, or `responseType` omitted |
| 393218 | 0x60002 | sceneActions: invalid or non-existent scene ID |

---

## Rain Sensor Integration

The WMS rain sensor does **not** appear as a separate destination in `getConfiguration`. Rain automation is handled internally by the WebControl Pro (configured via WMS studio pro) and is visible only through `drivingCause` in `getStatus`:

- `drivingCause: 4` → rain sensor triggered the last close
- `drivingCause: 3` → wind sensor triggered
- `drivingCause: 5` → ice/freeze protection active
- `drivingCause: 11` → safety override

Poll `getStatus` before sending manual position commands. If `drivingCause` is 3, 4, 5, or 11, weather protection is active and commands should be suppressed (or `--force` used explicitly).

---

## References

- [Official API Documentation (PDF)](https://media.warema.com/dokumente/anleitungen-handbuecher/966664/warema_2064534_alhb_de_v0.pdf)
- [pywmspro source](https://github.com/mback2k/pywmspro/tree/master/wmspro)
- [pywmspro simulator](https://github.com/mback2k/pywmspro/blob/master/simulator/simulator.py) — shows expected JSON shapes for all commands
