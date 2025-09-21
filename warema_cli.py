#!/usr/bin/env python3
"""
WAREMA CLI Application
Command-line interface for reading configuration and controlling WAREMA devices
"""

import argparse
import asyncio
import json
import sys
from typing import Dict, List, Optional, Any
from aiohttp import ClientSession
from wmspro.webcontrol import WebControlPro
from wmspro.const import (
    WMS_WebControl_pro_API_actionDescription,
    WMS_WebControl_pro_API_responseType,
    WMS_WebControl_pro_API_animationType
)
from config import WAREMA_HOST


class WaremaCLI:
    def __init__(self, host: str):
        self.host = host
        self.control = None
        self.session = None

    async def __aenter__(self):
        self.session = ClientSession()
        self.control = WebControlPro(self.host, self.session)
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb):
        if self.session:
            await self.session.close()

    async def connect(self):
        """Connect and test connection to WAREMA host"""
        if not await self.control.ping():
            raise ConnectionError(f"Failed to connect to WAREMA host {self.host}")
        await self.control.refresh()

    def convert_raw_to_percentage(self, raw_value: int) -> float:
        """Convert raw WAREMA value to percentage (0-100%)

        Based on calibration:
        - 0% = -45 (raw) - fully closed
        - 100% = 90 (raw) - fully open
        - Range: 135 raw units total
        """
        # Clamp to actual device range
        if raw_value < -45:
            raw_value = -45
        elif raw_value > 90:
            raw_value = 90

        # Convert: percentage = (raw_value + 45) × (100/135)
        percentage = (raw_value + 45) * (100.0 / 135.0)
        return percentage

    def convert_percentage_to_raw(self, percentage: float) -> int:
        """Convert percentage (0-100%) to raw WAREMA value"""
        if percentage < 0:
            percentage = 0
        elif percentage > 100:
            percentage = 100

        # Convert: raw_value = (percentage × 1.35) - 45
        raw_value = int((percentage * 1.35) - 45)
        return raw_value

    def convert_raw_to_degrees(self, raw_value: int) -> float:
        """Convert raw WAREMA value to degrees (0-135°)

        Based on the understanding that the slat device has 135 total units
        representing the full range of motion from fully closed to fully open.
        """
        # Clamp to actual device range
        if raw_value < -45:
            raw_value = -45
        elif raw_value > 90:
            raw_value = 90

        # Convert: degrees = raw_value + 45 (so -45 becomes 0°, 90 becomes 135°)
        degrees = raw_value + 45
        return float(degrees)

    def convert_degrees_to_raw(self, degrees: float) -> int:
        """Convert degrees (0-135°) to raw WAREMA value"""
        if degrees < 0:
            degrees = 0
        elif degrees > 135:
            degrees = 135

        # Convert: raw_value = degrees - 45
        raw_value = int(degrees - 45)
        return raw_value

    def find_slat_devices(self) -> List[Any]:
        """Find all devices that support slat rotation"""
        slat_devices = []
        for dest in self.control.dests.values():
            # Check for slat-capable device types
            if dest.animationType in [
                WMS_WebControl_pro_API_animationType.VenetianBlind,
                WMS_WebControl_pro_API_animationType.SlatRoof
            ]:
                # Check if device has slat rotation capability
                if dest.hasAction(WMS_WebControl_pro_API_actionDescription.SlatRotate):
                    slat_devices.append(dest)
        return slat_devices

    def find_device_by_name(self, device_name: str) -> Optional[Any]:
        """Find device by name (partial match)"""
        for dest in self.control.dests.values():
            if device_name.lower() in dest.name.lower():
                return dest
        return None

    async def get_configuration(self) -> Dict:
        """Get complete system configuration"""
        await self.connect()

        config_data = {
            "host": self.host,
            "system": dict(self.control.config),
            "devices": {},
            "rooms": {},
            "scenes": {},
            "summary": {
                "total_devices": len(self.control.dests),
                "total_rooms": len(self.control.rooms),
                "total_scenes": len(self.control.scenes),
                "slat_devices": 0
            }
        }

        # Process devices
        for dest_id, dest in self.control.dests.items():
            await dest.refresh()

            device_info = {
                "id": dest.id,
                "name": dest.name,
                "type": dest.animationType.name,
                "room": dest.room.name if dest.room else None,
                "available": dest.available,
                "driving_cause": dest.drivingCause.name,
                "actions": {}
            }

            # Process actions
            for action_id, action in dest.actions.items():
                action_info = {
                    "id": action.id,
                    "type": action.actionType.name,
                    "description": action.actionDescription.name,
                    "attributes": action._attrs,
                    "current_params": action._params
                }
                device_info["actions"][action_id] = action_info

            # Check if it's a slat device
            if dest.hasAction(WMS_WebControl_pro_API_actionDescription.SlatRotate):
                config_data["summary"]["slat_devices"] += 1
                device_info["slat_capable"] = True

                # Get current rotation if available
                rotation_action = dest.action(WMS_WebControl_pro_API_actionDescription.SlatRotate)
                if rotation_action._params.get("rotation") is not None:
                    raw_rotation = rotation_action._params["rotation"]
                    percentage = self.convert_raw_to_percentage(raw_rotation)
                    degrees = self.convert_raw_to_degrees(raw_rotation)
                    device_info["current_rotation"] = {
                        "raw": raw_rotation,
                        "percentage": round(percentage, 1),
                        "degrees": round(degrees, 1)
                    }
            else:
                device_info["slat_capable"] = False

            config_data["devices"][dest_id] = device_info

        # Process rooms
        for room_id, room in self.control.rooms.items():
            config_data["rooms"][room_id] = {
                "id": room.id,
                "name": room.name,
                "device_count": len(room.destinations),
                "scene_count": len(room.scenes),
                "devices": [dest.name for dest in room.destinations.values()],
                "scenes": [scene.name for scene in room.scenes.values()]
            }

        # Process scenes
        for scene_id, scene in self.control.scenes.items():
            config_data["scenes"][scene_id] = {
                "id": scene.id,
                "name": scene.name,
                "room": scene.room.name if scene.room else None
            }

        return config_data

    async def set_slat_percentage(self, device_name: str, percentage: float) -> Dict:
        """Set slat device to specified percentage (0-100%)"""
        await self.connect()

        # Find device
        if device_name:
            device = self.find_device_by_name(device_name)
            if not device:
                raise ValueError(f"Device '{device_name}' not found")
        else:
            # Use first available slat device
            slat_devices = self.find_slat_devices()
            if not slat_devices:
                raise ValueError("No slat-capable devices found")
            device = slat_devices[0]

        # Check if device supports slat rotation
        if not device.hasAction(WMS_WebControl_pro_API_actionDescription.SlatRotate):
            raise ValueError(f"Device '{device.name}' does not support slat rotation")

        await device.refresh()
        rotation_action = device.action(WMS_WebControl_pro_API_actionDescription.SlatRotate)

        # Convert percentage to raw value
        raw_value = self.convert_percentage_to_raw(percentage)

        # Execute rotation
        response = await rotation_action(
            rotation=raw_value,
            responseType=WMS_WebControl_pro_API_responseType.Detailed
        )

        # Wait for device to respond
        await asyncio.sleep(1)
        await device.refresh()

        # Get updated values
        current_raw = rotation_action._params.get("rotation", raw_value)
        current_percentage = self.convert_raw_to_percentage(current_raw)
        current_degrees = self.convert_raw_to_degrees(current_raw)

        return {
            "device_name": device.name,
            "device_id": device.id,
            "requested_percentage": percentage,
            "requested_raw": raw_value,
            "actual_percentage": round(current_percentage, 1),
            "actual_degrees": round(current_degrees, 1),
            "actual_raw": current_raw,
            "range_percentage": "0.0 to 100.0",
            "range_degrees": "0.0 to 135.0",
            "range_raw": "-45 to 90",
            "response": response
        }

    async def set_slat_degrees(self, device_name: str, degrees: float) -> Dict:
        """Set slat device to specified degrees (0-135°)"""
        await self.connect()

        # Find device
        if device_name:
            device = self.find_device_by_name(device_name)
            if not device:
                raise ValueError(f"Device '{device_name}' not found")
        else:
            # Use first available slat device
            slat_devices = self.find_slat_devices()
            if not slat_devices:
                raise ValueError("No slat-capable devices found")
            device = slat_devices[0]

        # Check if device supports slat rotation
        if not device.hasAction(WMS_WebControl_pro_API_actionDescription.SlatRotate):
            raise ValueError(f"Device '{device.name}' does not support slat rotation")

        await device.refresh()
        rotation_action = device.action(WMS_WebControl_pro_API_actionDescription.SlatRotate)

        # Convert degrees to raw value
        raw_value = self.convert_degrees_to_raw(degrees)

        # Execute rotation
        response = await rotation_action(
            rotation=raw_value,
            responseType=WMS_WebControl_pro_API_responseType.Detailed
        )

        # Wait for device to respond
        await asyncio.sleep(1)
        await device.refresh()

        # Get updated values
        current_raw = rotation_action._params.get("rotation", raw_value)
        current_percentage = self.convert_raw_to_percentage(current_raw)
        current_degrees = self.convert_raw_to_degrees(current_raw)

        return {
            "device_name": device.name,
            "device_id": device.id,
            "requested_degrees": degrees,
            "requested_raw": raw_value,
            "actual_percentage": round(current_percentage, 1),
            "actual_degrees": round(current_degrees, 1),
            "actual_raw": current_raw,
            "range_percentage": "0.0 to 100.0",
            "range_degrees": "0.0 to 135.0",
            "range_raw": "-45 to 90",
            "response": response
        }

    async def rotate_slat_device(self, device_name: str, degrees: float) -> Dict:
        """Rotate a slat device to specified degrees"""
        await self.connect()

        # Find device
        if device_name:
            device = self.find_device_by_name(device_name)
            if not device:
                raise ValueError(f"Device '{device_name}' not found")
        else:
            # Use first available slat device
            slat_devices = self.find_slat_devices()
            if not slat_devices:
                raise ValueError("No slat-capable devices found")
            device = slat_devices[0]

        # Check if device supports slat rotation
        if not device.hasAction(WMS_WebControl_pro_API_actionDescription.SlatRotate):
            raise ValueError(f"Device '{device.name}' does not support slat rotation")

        await device.refresh()
        rotation_action = device.action(WMS_WebControl_pro_API_actionDescription.SlatRotate)

        # Get rotation limits
        min_val = rotation_action._attrs.get("minValue", -127)
        max_val = rotation_action._attrs.get("maxValue", 127)

        # Convert degrees to raw value
        raw_value = self.convert_degrees_to_raw(degrees, min_val, max_val)

        # Execute rotation
        response = await rotation_action(
            rotation=raw_value,
            responseType=WMS_WebControl_pro_API_responseType.Detailed
        )

        # Wait for device to respond
        await asyncio.sleep(1)
        await device.refresh()

        # Get updated rotation value
        current_raw = rotation_action._params.get("rotation", raw_value)
        current_degrees = self.convert_raw_to_degrees(current_raw, min_val, max_val)

        return {
            "device_name": device.name,
            "device_id": device.id,
            "requested_degrees": degrees,
            "requested_raw": raw_value,
            "actual_degrees": round(current_degrees, 1),
            "actual_raw": current_raw,
            "range_degrees": "0.0 to 180.0",
            "range_raw": f"{min_val} to {max_val}",
            "response": response
        }


async def cmd_config(args):
    """Get system configuration command"""
    async with WaremaCLI(args.host) as cli:
        try:
            config = await cli.get_configuration()

            if args.format == "json":
                print(json.dumps(config, indent=2, default=str))
            else:
                # Pretty formatted output
                print(f"WAREMA System Configuration - Host: {config['host']}")
                print("=" * 60)

                # Summary
                summary = config["summary"]
                print(f"\nSUMMARY:")
                print(f"  Total Devices: {summary['total_devices']}")
                print(f"  Slat Devices: {summary['slat_devices']}")
                print(f"  Rooms: {summary['total_rooms']}")
                print(f"  Scenes: {summary['total_scenes']}")

                # Devices
                print(f"\nDEVICES:")
                for device_id, device in config["devices"].items():
                    status = "✓" if device["available"] else "✗"
                    slat_info = ""
                    if device["slat_capable"] and "current_rotation" in device:
                        rotation = device['current_rotation']
                        slat_info = f" ({rotation['percentage']}% = {rotation['degrees']}°)"

                    print(f"  {status} {device['name']} ({device['type']}) - Room: {device['room']}{slat_info}")

                # Rooms
                if config["rooms"]:
                    print(f"\nROOMS:")
                    for room_id, room in config["rooms"].items():
                        print(f"  {room['name']} - {room['device_count']} devices, {room['scene_count']} scenes")

                # Scenes
                if config["scenes"]:
                    print(f"\nSCENES:")
                    for scene_id, scene in config["scenes"].items():
                        room_info = f" (Room: {scene['room']})" if scene['room'] else ""
                        print(f"  {scene['name']}{room_info}")

        except Exception as e:
            print(f"Error: {e}")
            sys.exit(1)


async def cmd_set_percentage(args):
    """Set slat device percentage command"""
    async with WaremaCLI(args.host) as cli:
        try:
            result = await cli.set_slat_percentage(args.device, args.percentage)

            print(f"✓ Slat percentage set!")
            print(f"Device: {result['device_name']} (ID: {result['device_id']})")
            print(f"Requested: {result['requested_percentage']}% (raw: {result['requested_raw']})")
            print(f"Actual: {result['actual_percentage']}% = {result['actual_degrees']}° (raw: {result['actual_raw']})")
            print(f"Range: {result['range_percentage']} = {result['range_degrees']} (raw: {result['range_raw']})")

            if args.verbose:
                print(f"API Response: {result['response']}")

        except Exception as e:
            print(f"Error: {e}")
            sys.exit(1)


async def cmd_set_degrees(args):
    """Set slat device degrees command"""
    async with WaremaCLI(args.host) as cli:
        try:
            result = await cli.set_slat_degrees(args.device, args.degrees)

            print(f"✓ Slat degrees set!")
            print(f"Device: {result['device_name']} (ID: {result['device_id']})")
            print(f"Requested: {result['requested_degrees']}° (raw: {result['requested_raw']})")
            print(f"Actual: {result['actual_degrees']}° = {result['actual_percentage']}% (raw: {result['actual_raw']})")
            print(f"Range: {result['range_degrees']} = {result['range_percentage']} (raw: {result['range_raw']})")

            if args.verbose:
                print(f"API Response: {result['response']}")

        except Exception as e:
            print(f"Error: {e}")
            sys.exit(1)


async def cmd_rotate(args):
    """Legacy rotate command (for backward compatibility)"""
    # Convert old 0-180 degrees to new 0-135 degrees range
    # This maintains backward compatibility while using correct mapping
    legacy_degrees = args.degrees
    if legacy_degrees > 135:
        legacy_degrees = 135

    await cmd_set_degrees(type('args', (), {
        'host': args.host,
        'device': args.device,
        'degrees': legacy_degrees,
        'verbose': getattr(args, 'verbose', False)
    })())


async def cmd_list_slats(args):
    """List all slat-capable devices"""
    async with WaremaCLI(args.host) as cli:
        try:
            await cli.connect()
            slat_devices = cli.find_slat_devices()

            if not slat_devices:
                print("No slat-capable devices found")
                return

            print(f"Found {len(slat_devices)} slat-capable device(s):")

            for device in slat_devices:
                await device.refresh()
                rotation_action = device.action(WMS_WebControl_pro_API_actionDescription.SlatRotate)

                current_rotation = "Unknown"
                if rotation_action._params.get("rotation") is not None:
                    raw_rotation = rotation_action._params["rotation"]
                    percentage = cli.convert_raw_to_percentage(raw_rotation)
                    degrees = cli.convert_raw_to_degrees(raw_rotation)
                    current_rotation = f"{percentage:.1f}% = {degrees:.1f}° (raw: {raw_rotation})"

                status = "✓" if device.available else "✗"
                room_info = f" - Room: {device.room.name}" if device.room else ""

                print(f"  {status} {device.name} (ID: {device.id}){room_info}")
                print(f"    Type: {device.animationType.name}")
                print(f"    Current Position: {current_rotation}")
                print(f"    Range: 0-100% = 0-135° (raw: -45 to 90)")

        except Exception as e:
            print(f"Error: {e}")
            sys.exit(1)


def main():
    """Main CLI function"""
    parser = argparse.ArgumentParser(
        description="WAREMA Device Configuration and Control CLI",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s config                         # Show configuration in readable format
  %(prog)s config --format json          # Show configuration as JSON
  %(prog)s set-percent 50                 # Set first slat device to 50 percent
  %(prog)s set-percent 75 --device lamaxa # Set specific device to 75 percent
  %(prog)s set-degrees 67                 # Set first slat device to 67 degrees
  %(prog)s set-degrees 100 --device lamaxa # Set specific device to 100 degrees
  %(prog)s list-slats                     # List all slat-capable devices
  %(prog)s rotate 90                      # Legacy command for backward compatibility
        """
    )

    parser.add_argument('--host', default=WAREMA_HOST,
                       help=f'WAREMA host address (default: {WAREMA_HOST})')
    parser.add_argument('--verbose', '-v', action='store_true',
                       help='Enable verbose output')

    subparsers = parser.add_subparsers(dest='command', help='Available commands')

    # Config command
    config_parser = subparsers.add_parser('config', help='Get system configuration')
    config_parser.add_argument('--format', choices=['pretty', 'json'], default='pretty',
                              help='Output format (default: pretty)')

    # Set percentage command
    percent_parser = subparsers.add_parser('set-percent', help='Set slat device percentage 0-100 percent')
    percent_parser.add_argument('percentage', type=float, help='Percentage 0-100 percent')
    percent_parser.add_argument('--device', help='Device name partial match, uses first slat device if not specified')
    percent_parser.add_argument('--verbose', '-v', action='store_true', help='Enable verbose output')

    # Set degrees command
    degrees_parser = subparsers.add_parser('set-degrees', help='Set slat device degrees 0-135 degrees')
    degrees_parser.add_argument('degrees', type=float, help='Degrees 0-135 degrees')
    degrees_parser.add_argument('--device', help='Device name partial match, uses first slat device if not specified')
    degrees_parser.add_argument('--verbose', '-v', action='store_true', help='Enable verbose output')

    # Legacy rotate command (for backward compatibility)
    rotate_parser = subparsers.add_parser('rotate', help='Legacy rotate command use set-degrees instead')
    rotate_parser.add_argument('degrees', type=float, help='Rotation in degrees 0-135 degrees, values over 135 will be clamped')
    rotate_parser.add_argument('--device', help='Device name partial match, uses first slat device if not specified')
    rotate_parser.add_argument('--verbose', '-v', action='store_true', help='Enable verbose output')

    # List slats command
    list_parser = subparsers.add_parser('list-slats', help='List all slat-capable devices')

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    try:
        if args.command == 'config':
            asyncio.run(cmd_config(args))
        elif args.command == 'set-percent':
            asyncio.run(cmd_set_percentage(args))
        elif args.command == 'set-degrees':
            asyncio.run(cmd_set_degrees(args))
        elif args.command == 'rotate':
            asyncio.run(cmd_rotate(args))
        elif args.command == 'list-slats':
            asyncio.run(cmd_list_slats(args))
    except KeyboardInterrupt:
        print("\nOperation cancelled by user")
        sys.exit(1)


if __name__ == "__main__":
    main()