# WAREMA WebControl Pro API Reference

Based on analysis of the pywmspro Python wrapper, this document provides a comprehensive reference for the WAREMA WebControl Pro API.

## Core API Classes

### WebControlPro
Main control class for interacting with WAREMA devices.

#### Connection & Configuration
```python
from aiohttp import ClientSession
from wmspro.webcontrol import WebControlPro

async with ClientSession() as session:
    control = WebControlPro("10.10.1.229", session)

    # Test connection
    is_connected = await control.ping()

    # Load configuration and devices
    await control.refresh()
```

#### Properties
- `host` - WAREMA host address
- `config` - System configuration dictionary
- `dests` - Dictionary of destination devices (ID -> Destination)
- `rooms` - Dictionary of rooms (ID -> Room)
- `scenes` - Dictionary of scenes (ID -> Scene)

#### Methods
- `ping()` - Test connection (returns bool)
- `refresh()` - Load/refresh all configuration and device data
- `dest(name)` - Find destination by name
- `diag()` - Get comprehensive diagnostic information

## Device Types (Animation Types)

### Supported Device Types
```python
class WMS_WebControl_pro_API_animationType(IntEnum):
    VenetianBlind = 0      # Venetian blinds with slats
    Awning = 1             # Retractable awnings
    RollerShutterBlind = 2 # Roller shutters
    SlatRoof = 3           # Slat roof systems (like pergolas)
    Window = 4             # Motorized windows
    Switch = 5             # On/off switches
    Dimmer = 6             # Dimmable lights/loads
    Unknown = 999
```

## Action Types

### Available Action Types
```python
class WMS_WebControl_pro_API_actionType(IntEnum):
    Percentage = 0         # 0-100% position control
    PercentageDelta = 1    # Relative percentage change
    Rotation = 2           # Absolute rotation (slats)
    RotationDelta = 3      # Relative rotation change
    Switch = 4             # On/off control
    Toggle = 5             # Toggle current state
    Stop = 6               # Stop movement
    Impulse = 7            # Single impulse command
    Identify = 8           # Device identification (blinking)
    Enumeration = 9        # Predefined value selection
    Unknown = 999
```

### Action Descriptions
```python
class WMS_WebControl_pro_API_actionDescription(IntEnum):
    AwningDrive = 0           # Control awning position
    ValanceDrive = 1          # Control valance position
    SlatDrive = 2             # Control slat position
    SlatRotate = 3            # Rotate slats
    RollerShutterBlindDrive = 4  # Control roller shutter
    WindowDrive = 5           # Control window position
    LightSwitch = 6           # Light switching
    LoadSwitch = 7            # Load switching
    LightDimming = 8          # Light dimming
    LoadDimming = 9           # Load dimming
    LightToggle = 10          # Light toggle
    LastToggle = 11           # Repeat last toggle
    ManualCommand = 12        # Manual control commands
    Identify = 13             # Device identification
    Unknown = 999
```

## Destination (Device) Class

### Properties
- `id` - Unique device identifier
- `name` - Device name
- `actions` - Dictionary of available actions
- `animationType` - Device type (see animation types)
- `drivingCause` - What triggered last movement
- `room` - Room object this device belongs to
- `available` - Whether device is available (not in error)
- `status` - Current device status

### Methods
- `refresh()` - Update device status
- `hasAction(actionDescription, actionType=None)` - Check if action exists
- `action(actionDescription, actionType=None)` - Get specific action
- `diag()` - Get diagnostic information

### Example Usage
```python
# Find device
device = control.dest("Lamaxa wenden")

# Check for rotation capability
if device.hasAction(WMS_WebControl_pro_API_actionDescription.SlatRotate):
    # Get rotation action
    rotate_action = device.action(WMS_WebControl_pro_API_actionDescription.SlatRotate)

    # Execute rotation to specific angle
    await rotate_action(rotation=90)
```

## Action Class

### Properties
- `id` - Action identifier
- `actionType` - Type of action (see action types)
- `actionDescription` - Description of action (see descriptions)
- Dynamic attributes from `_attrs` (e.g., `minValue`, `maxValue`)
- Dynamic parameters from `_params` (current values)

### Methods
- `__call__(**kwargs)` - Execute the action with parameters
- `diag()` - Get diagnostic information

### Common Action Parameters

#### Percentage Actions
```python
# Set to 50% position
await action(percentage=50)

# Move by 25% (relative)
await action(percentageDelta=25)
```

#### Rotation Actions
```python
# Rotate to specific angle (-127 to 127 typically)
await action(rotation=90)

# Rotate by relative amount
await action(rotationDelta=15)
```

#### Switch Actions
```python
# Turn on
await action(switchValue=True)

# Turn off
await action(switchValue=False)
```

#### Control Actions
```python
# Stop movement
await action()  # Stop actions typically need no parameters

# Identify device (make it blink/move)
await action()
```

## Response Types

```python
class WMS_WebControl_pro_API_responseType(IntEnum):
    Instant = 0    # Return immediately
    Detailed = 1   # Wait for detailed response
```

## Scene Class

### Properties
- `id` - Scene identifier
- `name` - Scene name
- `room` - Room this scene belongs to

### Methods
- `__call__(**kwargs)` - Execute the scene
- `diag()` - Get diagnostic information

### Scene Actions
```python
# Execute scene
await scene()

# Relearn scene (save current positions)
await scene(sceneActionType=WMS_WebControl_pro_API_sceneActionType.Relearn)
```

## Room Class

### Properties
- `id` - Room identifier
- `name` - Room name
- `destinations` - Dictionary of devices in this room
- `scenes` - Dictionary of scenes in this room

## Driving Causes

Shows what triggered the last device movement:

```python
class WMS_WebControl_pro_API_drivingCause(IntEnum):
    _None = 0           # No driving cause
    Sun = 1             # Sun sensor
    DuskDawn = 2        # Time-based automation
    Wind = 3            # Wind sensor
    Rain = 4            # Rain sensor
    Ice = 5             # Ice sensor
    Temperature = 6     # Temperature sensor
    SwitchingTime = 7   # Scheduled time
    Scene = 8           # Scene execution
    ControlMode = 9     # Control mode change
    Manual = 10         # Manual operation
    Safety = 11         # Safety override
    Contact = 12        # Contact sensor
    CentralCommand = 13 # Central command
    Unknown = 999
```

## Common Device Control Patterns

### Blinds/Shutters
```python
# Move to 50% open
await device.action(WMS_WebControl_pro_API_actionDescription.SlatDrive)(percentage=50)

# Rotate slats to 45 degrees
await device.action(WMS_WebControl_pro_API_actionDescription.SlatRotate)(rotation=45)

# Stop movement
await device.action(WMS_WebControl_pro_API_actionDescription.ManualCommand,
                   WMS_WebControl_pro_API_actionType.Stop)()
```

### Lights
```python
# Turn light on
await device.action(WMS_WebControl_pro_API_actionDescription.LightSwitch)(switchValue=True)

# Dim to 75%
await device.action(WMS_WebControl_pro_API_actionDescription.LightDimming)(percentage=75)

# Toggle light
await device.action(WMS_WebControl_pro_API_actionDescription.LightToggle)()
```

### Awnings
```python
# Extend awning to 80%
await device.action(WMS_WebControl_pro_API_actionDescription.AwningDrive)(percentage=80)

# Retract completely
await device.action(WMS_WebControl_pro_API_actionDescription.AwningDrive)(percentage=0)
```

## Error Handling

Devices can report errors through:
- `heartbeatError` - Communication issues
- `blocking` - Physical obstructions
- `available` property combines both

## API Limits and Considerations

1. **Rate Limiting**: Avoid rapid successive commands
2. **Response Types**: Use `Detailed` for confirmation, `Instant` for speed
3. **Device Refresh**: Call `refresh()` to get current status
4. **Session Management**: Use proper async context managers
5. **Error Handling**: Always check device availability before commands

## Complete Example

```python
import asyncio
from aiohttp import ClientSession
from wmspro.webcontrol import WebControlPro
from wmspro.const import (
    WMS_WebControl_pro_API_actionDescription,
    WMS_WebControl_pro_API_responseType
)

async def control_warema_device():
    async with ClientSession() as session:
        control = WebControlPro("10.10.1.229", session)

        # Connect and load configuration
        if not await control.ping():
            print("Connection failed")
            return

        await control.refresh()

        # Find and control a device
        device = control.dest("Lamaxa wenden")
        await device.refresh()

        # Rotate slats to 90 degrees
        if device.hasAction(WMS_WebControl_pro_API_actionDescription.SlatRotate):
            action = device.action(WMS_WebControl_pro_API_actionDescription.SlatRotate)
            await action(rotation=90, responseType=WMS_WebControl_pro_API_responseType.Detailed)

        # Get updated status
        await device.refresh()
        print(f"Device status: {device.status}")

asyncio.run(control_warema_device())
```