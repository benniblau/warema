# WAREMA Slat Control Script

A lightweight shell script for controlling WAREMA WebControl Pro devices via direct API calls.

## Overview

This standalone shell script provides command-line control for WAREMA slat devices (such as venetian blinds and slat roofs) connected to a WAREMA WebControl Pro system. Built using only shell scripting and standard Unix tools, it offers fast and reliable device control without external dependencies.

## Features

- **Position Control**: Set slat position from 0% (fully closed) to 100% (fully open)
- **Current Status**: Get current slat position as integer percentage
- **Stop Control**: Immediately stop any ongoing rotation/movement
- **Device Discovery**: List all registered devices with raw JSON configuration
- **Silent Operation**: Default silent mode with optional verbose output
- **Bounds Checking**: Automatic validation and clamping of input values
- **Error Handling**: Comprehensive connection testing and error reporting

## Requirements

- `curl` - For HTTP API communication
- `bc` - For mathematical calculations
- `bash` - Shell environment (version 4.0+)
- Standard Unix tools: `grep`, `sed`, `xargs`, `printf`
- Network access to WAREMA WebControl Pro host

**No Python or external libraries required** - Pure shell script implementation.

## Configuration

### Environment File Setup

1. Copy the example environment file:
```bash
cp .env.example .env
```

2. Edit `.env` to match your setup:
```bash
# WAREMA WebControl Pro Configuration
WAREMA_HOST=10.10.1.229     # Your WAREMA WebControl Pro IP address
DEVICE_ID=57789             # Target device ID (Lamaxa wenden)
ACTION_ID=6                 # SlatRotate action ID
STOP_ACTION_ID=16           # ManualCommand Stop action ID
TIMEOUT=10                  # API call timeout in seconds
```

The script automatically loads configuration from the `.env` file if present, otherwise uses built-in defaults.

## Usage

### Basic Commands

```bash
# Set slat position (silent mode)
./warema_slat.sh 50          # Set to 50% open
./warema_slat.sh 0           # Fully closed
./warema_slat.sh 100         # Fully open

# Get current position (returns integer only)
./warema_slat.sh get         # Returns: 50

# Stop current movement
./warema_slat.sh stop        # Stop rotation immediately

# List all devices
./warema_slat.sh devices     # Show raw JSON device configuration
```

### Options

```bash
-h, --help         Show help message
-v, --verbose      Enable verbose output (ignored in get mode)
-s, --silent       Silent mode - no output (default for set operations)
-d, --device ID    Use different device ID
-H, --host HOST    Use different WAREMA host
```

### Examples

```bash
# Verbose operation
./warema_slat.sh 75 --verbose

# Use different device
./warema_slat.sh 50 --device 12345

# Use different host
./warema_slat.sh get --host 192.168.1.100
```

## Position Mapping

The script converts percentage values to WAREMA raw values:

| Percentage | Raw Value | Description |
|------------|-----------|-------------|
| 0%         | -45       | Fully closed |
| 50%        | 22        | Half open |
| 100%       | 90        | Fully open |

**Total Range**: 135 units (-45 to +90)
**Device Limits**: -127 to +127 (hardware bounds)

## API Reference

### WAREMA WebControl Pro API

The script communicates with the WAREMA WebControl Pro API using JSON over HTTP.

#### Base URL
```
http://{WAREMA_HOST}/commonCommand
```

#### Authentication
No authentication required for local network access.

#### Common Headers
```
Content-Type: application/json
```

### API Commands

#### 1. Ping (Connection Test)
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
  "status": 0,
  "command": "ping",
  "protocolVersion": "1.0.0"
}
```

#### 2. Get Configuration
```json
{
  "protocolVersion": "1.0",
  "command": "getConfiguration",
  "source": 2
}
```

**Response:** Contains complete system configuration including devices, rooms, and actions.

#### 3. Get Status
```json
{
  "protocolVersion": "1.0",
  "command": "getStatus",
  "source": 2,
  "destinations": [57789]
}
```

**Response:** Contains current device status and position values.

#### 4. Set Rotation
```json
{
  "protocolVersion": "1.0",
  "command": "action",
  "source": 2,
  "responseType": 1,
  "actions": [{
    "destinationId": 57789,
    "actionId": 6,
    "parameters": {
      "rotation": -45
    }
  }]
}
```

#### 5. Stop Movement
```json
{
  "protocolVersion": "1.0",
  "command": "action",
  "source": 2,
  "responseType": 1,
  "actions": [{
    "destinationId": 57789,
    "actionId": 16,
    "parameters": {}
  }]
}
```

### Device Types

| ID | Type | Description |
|----|------|-------------|
| 0  | VenetianBlind | Standard venetian blinds |
| 1  | Awning | Retractable awnings |
| 2  | RollerShutterBlind | Roller shutters |
| 3  | SlatRoof | Slat roof systems |
| 4  | Window | Window operators |
| 5  | Switch | Simple on/off devices |
| 6  | Dimmer | Dimmable devices |
| 999| Unknown | Unrecognized device type |

### Action Types

| ID | Type | Description |
|----|------|-------------|
| 0  | Percentage | Position by percentage |
| 1  | PercentageDelta | Relative percentage change |
| 2  | Rotation | Absolute rotation value |
| 3  | RotationDelta | Relative rotation change |
| 4  | Switch | On/off toggle |
| 5  | Toggle | State toggle |
| 6  | Stop | Stop movement |
| 7  | Impulse | Momentary action |
| 8  | Identify | Device identification |
| 9  | Enumeration | Enumerated value |

### Action Descriptions

| ID | Description | Usage |
|----|-------------|-------|
| 0  | AwningDrive | Awning extension/retraction |
| 1  | ValanceDrive | Valance movement |
| 2  | SlatDrive | Slat position control |
| 3  | SlatRotate | Slat rotation angle |
| 4  | RollerShutterBlindDrive | Shutter up/down |
| 5  | WindowDrive | Window open/close |
| 6  | LightSwitch | Light on/off |
| 7  | LoadSwitch | Load switching |
| 8  | LightDimming | Light dimming |
| 9  | LoadDimming | Load dimming |
| 10 | LightToggle | Light toggle |
| 11 | LastToggle | Repeat last action |
| 12 | ManualCommand | Manual control |
| 13 | Identify | Device identification |

## Error Handling

The script includes comprehensive error handling:

- **Connection Testing**: Validates host connectivity before operations
- **Input Validation**: Checks percentage values and device IDs
- **Bounds Checking**: Clamps values to valid ranges
- **Response Validation**: Verifies API responses for success
- **Timeout Handling**: Configurable timeout for API calls

### Exit Codes

- `0` - Success
- `1` - Error (connection failure, invalid input, API error)

## Conversion Functions

### Percentage to Raw Value
```bash
raw_value = (percentage × 1.35) - 45
```
- Input: 0-100 (percentage)
- Output: -45 to 90 (raw value)
- Bounds: Clamped to -127 to 127

### Raw Value to Percentage
```bash
percentage = (raw_value + 45) × (100/135)
```
- Input: -127 to 127 (raw value)
- Output: 0.0 to 100.0 (percentage)
- Precision: 1 decimal place

## Troubleshooting

### Connection Issues
1. Verify WAREMA host IP address
2. Check network connectivity: `ping 10.10.1.229`
3. Test API directly: `curl http://10.10.1.229/commonCommand`

### Device Not Responding
1. Verify device ID in `.env` configuration
2. Check device status with: `./warema_slat.sh devices`
3. Ensure device is powered and connected

### Unexpected Behavior
1. Use verbose mode: `./warema_slat.sh 50 --verbose`
2. Check current position: `./warema_slat.sh get`
3. Verify conversion calculations
4. Check .env file configuration is correct

## Project Files

- `warema_slat.sh` - Main shell script application
- `.env` - Environment configuration file (not tracked in git)
- `.env.example` - Example configuration template
- `.gitignore` - Git ignore rules for sensitive files
- `README.md` - This documentation

## Installation

1. Clone or download the script:
```bash
wget https://your-repo/warema_slat.sh
chmod +x warema_slat.sh
```

2. Copy and configure environment file:
```bash
cp .env.example .env
# Edit .env with your WAREMA host and device settings
```

3. Test connection:
```bash
./warema_slat.sh get --verbose
```

## Architecture

This is a **pure shell script implementation** with the following design principles:

- **Zero Dependencies**: Uses only standard Unix tools available on all systems
- **Direct API**: Communicates directly with WAREMA WebControl Pro JSON API
- **Lightweight**: Fast execution with minimal resource usage
- **Portable**: Runs on any Unix-like system with bash
- **Self-Contained**: All functionality in a single script file

## References

- [WAREMA WebControl Pro API Documentation](https://media.warema.com/dokumente/anleitungen-handbuecher/966664/warema_2064534_alhb_de_v0.pdf)

## License

This script is provided as-is for controlling WAREMA devices in home automation setups.