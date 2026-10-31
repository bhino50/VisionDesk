"""Select and validate visionOS simulators from simctl's JSON inventory."""

import argparse
import json
import re
import sys
import uuid


def version_tuple(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d+(?:\.\d+){0,2}", value):
        raise ValueError("Simulator runtime version is invalid.")
    return tuple(int(part) for part in value.split(".")) + (0,) * (3 - len(value.split(".")))


def vision_runtimes(inventory):
    return [runtime for runtime in inventory.get("runtimes", [])
            if runtime.get("isAvailable") is True
            and re.fullmatch(r"com\.apple\.CoreSimulator\.SimRuntime\.(?:xrOS|visionOS)-[0-9-]+",
                             runtime.get("identifier", ""))
            and version_tuple(runtime.get("version")) >= (2, 0, 0)]


def select_runtime(inventory):
    """Choose the newest available visionOS runtime and a compatible headset type."""
    for runtime in sorted(vision_runtimes(inventory), key=lambda item: version_tuple(item["version"]), reverse=True):
        supported = {item["identifier"] for item in runtime.get("supportedDeviceTypes", [])}
        for device in inventory.get("devicetypes", []):
            identifier = device.get("identifier", "")
            if not re.fullmatch(r"com\.apple\.CoreSimulator\.SimDeviceType\.Apple-Vision-Pro(?:-[A-Za-z0-9-]+)?", identifier):
                continue
            if supported:
                compatible = identifier in supported
            else:
                # Older simctl versions expose compatibility on the device type only.
                compatible = (version_tuple(device.get("minRuntimeVersionString"))
                              <= version_tuple(runtime["version"])
                              <= version_tuple(device.get("maxRuntimeVersionString")))
            if compatible:
                return runtime["identifier"], identifier
    raise ValueError("No available visionOS 2+ runtime with a compatible Apple Vision Pro type. Install platform support; native tests were not run.")


def validate_device(inventory, identifier):
    try:
        canonical = str(uuid.UUID(identifier)).upper()
    except (ValueError, AttributeError):
        raise ValueError("Pass a complete simulator UUID, not a name or partial match.") from None
    for runtime in vision_runtimes(inventory):
        for device in inventory.get("devices", {}).get(runtime["identifier"], []):
            if device.get("isAvailable") is True and device.get("udid", "").upper() == canonical:
                return canonical
    raise ValueError("The UUID is not an available visionOS simulator. Native tests were not run.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("select", "validate"))
    parser.add_argument("identifier", nargs="?")
    arguments = parser.parse_args()
    try:
        inventory = json.load(sys.stdin)
        if not isinstance(inventory, dict):
            raise ValueError("Simulator inventory must be an object.")
        if arguments.operation == "select":
            print("\t".join(select_runtime(inventory)))
        else:
            print(validate_device(inventory, arguments.identifier))
    except (ValueError, TypeError, KeyError, AttributeError) as error:
        print(f"Simulator setup failed: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
