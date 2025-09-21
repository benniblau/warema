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

    def convert_raw_to_degrees(self, raw_value: int, min_val: int = -127, max_val: int = 127) -> float:
        """Convert raw WAREMA value to degrees (0-180)"""
        if raw_value < min_val:
            raw_value = min_val
        elif raw_value > max_val:
            raw_value = max_val

        # Map from [-127, 127] to [0, 180] degrees
        normalized = (raw_value - min_val) / (max_val - min_val)
        return normalized * 180.0

    def convert_degrees_to_raw(self, degrees: float, min_val: int = -127, max_val: int = 127) -> int:
        """Convert degrees (0-180) to raw WAREMA value"""
        if degrees < 0:
            degrees = 0
        elif degrees > 180:
            degrees = 180

        # Map from [0, 180] to [-127, 127]
        normalized = degrees / 180.0
        raw_value = int(min_val + normalized * (max_val - min_val))
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
                    min_val = rotation_action._attrs.get("minValue", -127)
                    max_val = rotation_action._attrs.get("maxValue", 127)
                    degrees = self.convert_raw_to_degrees(raw_rotation, min_val, max_val)
                    device_info["current_rotation"] = {
                        "raw": raw_rotation,
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
                        slat_info = f" (rotation: {device['current_rotation']['degrees']}°)"

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


async def cmd_rotate(args):
    """Rotate slat device command"""
    async with WaremaCLI(args.host) as cli:
        try:
            result = await cli.rotate_slat_device(args.device, args.degrees)

            print(f"✓ Slat rotation completed!")
            print(f"Device: {result['device_name']} (ID: {result['device_id']})")
            print(f"Requested: {result['requested_degrees']}° (raw: {result['requested_raw']})")
            print(f"Actual: {result['actual_degrees']}° (raw: {result['actual_raw']})")
            print(f"Range: {result['range_degrees']} (raw: {result['range_raw']})")

            if args.verbose:
                print(f"API Response: {result['response']}")

        except Exception as e:
            print(f"Error: {e}")
            sys.exit(1)


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
                    min_val = rotation_action._attrs.get("minValue", -127)
                    max_val = rotation_action._attrs.get("maxValue", 127)
                    degrees = cli.convert_raw_to_degrees(raw_rotation, min_val, max_val)
                    current_rotation = f"{degrees:.1f}° (raw: {raw_rotation})"

                status = "✓" if device.available else "✗"
                room_info = f" - Room: {device.room.name}" if device.room else ""

                print(f"  {status} {device.name} (ID: {device.id}){room_info}")
                print(f"    Type: {device.animationType.name}")
                print(f"    Current Rotation: {current_rotation}")
                print(f"    Range: {rotation_action._attrs.get('minValue', -127)} to {rotation_action._attrs.get('maxValue', 127)} (raw)")

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
  %(prog)s rotate 90                      # Rotate first slat device to 90°
  %(prog)s rotate 45 --device lamaxa     # Rotate specific device to 45°
  %(prog)s list-slats                     # List all slat-capable devices
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

    # Rotate command
    rotate_parser = subparsers.add_parser('rotate', help='Rotate slat device')
    rotate_parser.add_argument('degrees', type=float, help='Rotation in degrees (0-180)')
    rotate_parser.add_argument('--device', help='Device name (partial match, uses first slat device if not specified)')
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
        elif args.command == 'rotate':
            asyncio.run(cmd_rotate(args))
        elif args.command == 'list-slats':
            asyncio.run(cmd_list_slats(args))
    except KeyboardInterrupt:
        print("\nOperation cancelled by user")
        sys.exit(1)


if __name__ == "__main__":
    main()