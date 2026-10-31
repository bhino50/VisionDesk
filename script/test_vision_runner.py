#!/usr/bin/env python3
"""Test simulator selection and the native-test launcher using fake developer tools."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from vision_simulator import select_runtime, validate_device


VISION_ID = "11111111-1111-4111-8111-111111111111"
IOS_ID = "22222222-2222-4222-8222-222222222222"
RUNTIME = "com.apple.CoreSimulator.SimRuntime.xrOS-26-5"
DEVICE_TYPE = "com.apple.CoreSimulator.SimDeviceType.Apple-Vision-Pro-4K"


def fixture_inventory():
    return {
        "runtimes": [
            {"identifier": RUNTIME, "version": "26.5", "isAvailable": True,
             "supportedDeviceTypes": [{"identifier": DEVICE_TYPE}]},
            {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
             "version": "26.5", "isAvailable": True},
        ],
        "devicetypes": [{"identifier": DEVICE_TYPE, "minRuntimeVersionString": "3.0.0",
                         "maxRuntimeVersionString": "65535.255.255"}],
        "devices": {
            RUNTIME: [{"udid": VISION_ID, "isAvailable": True}],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [{"udid": IOS_ID, "isAvailable": True}],
        },
    }


class SimulatorSelectionTests(unittest.TestCase):
    def test_selects_newest_available_compatible_vision_runtime_numerically(self):
        inventory = fixture_inventory()
        inventory["runtimes"] += [
            {"identifier": "com.apple.CoreSimulator.SimRuntime.xrOS-26-10",
             "version": "26.10", "isAvailable": True},
            {"identifier": "com.apple.CoreSimulator.SimRuntime.xrOS-27-0",
             "version": "27.0", "isAvailable": False},
        ]
        self.assertEqual(select_runtime(inventory),
                         ("com.apple.CoreSimulator.SimRuntime.xrOS-26-10", DEVICE_TYPE))

    def test_missing_runtime_or_compatible_device_type_fails(self):
        for field in ("runtimes", "devicetypes"):
            inventory = fixture_inventory()
            inventory[field] = []
            with self.subTest(field=field), self.assertRaises(ValueError):
                select_runtime(inventory)

    def test_exact_available_vision_uuid_is_required(self):
        inventory = fixture_inventory()
        self.assertEqual(validate_device(inventory, VISION_ID.lower()), VISION_ID)
        for identifier in ("1111", ".*", "Apple Vision Pro", IOS_ID):
            with self.subTest(identifier=identifier), self.assertRaises(ValueError):
                validate_device(inventory, identifier)
        inventory["devices"][RUNTIME][0]["isAvailable"] = False
        with self.assertRaises(ValueError):
            validate_device(inventory, VISION_ID)

    def test_unavailable_runtime_invalidates_existing_device(self):
        inventory = fixture_inventory()
        inventory["runtimes"][0]["isAvailable"] = False
        with self.assertRaises(ValueError):
            validate_device(inventory, VISION_ID)


class NativeTestLauncherTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="visiondesk-runner-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.script = self.root / "script"
        self.script.mkdir()
        actual = Path(__file__).resolve().parent
        for name in ("test_vision.sh", "vision_simulator.py"):
            shutil.copyfile(actual / name, self.script / name)
        (self.script / "generate_xcode_project.py").write_text("# Synthetic project generator.\n")
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.developer = self.root / "FakeXcode/Contents/Developer"
        (self.developer / "usr/bin").mkdir(parents=True)
        self.inventory = self.root / "inventory.json"
        self.inventory.write_text(json.dumps(fixture_inventory()))
        self.marker = self.root / "xcodebuild-arguments.json"
        self.write_tool(self.tools / "xcrun", '''#!/usr/bin/env python3
import os, sys
from pathlib import Path
if sys.argv[1:] == ['simctl', 'list', '-j']:
    print(Path(os.environ['FIXTURE_INVENTORY']).read_text())
elif sys.argv[1:] == ['--sdk', 'xrsimulator', '--show-sdk-path']:
    if os.environ.get('FIXTURE_MISSING_SDK'):
        raise SystemExit(1)
    print('/fixture/visionOS.simulator.sdk')
else:
    raise SystemExit('Unexpected fake xcrun operation')
''')
        self.write_tool(self.developer / "usr/bin/xcodebuild", '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
arguments = sys.argv[1:]
Path(os.environ['FIXTURE_MARKER']).write_text(json.dumps(arguments))
result = Path(arguments[arguments.index('-resultBundlePath') + 1])
result.mkdir(parents=True)
(result / 'synthetic-result.txt').write_text('Synthetic result; no native tests executed.')
print('Synthetic xcodebuild output')
raise SystemExit(int(os.environ.get('FIXTURE_TEST_STATUS', '0')))
''')
        self.environment = dict(os.environ, DEVELOPER_DIR=str(self.developer),
                                PATH=str(self.tools) + os.pathsep + os.environ["PATH"],
                                FIXTURE_INVENTORY=str(self.inventory), FIXTURE_MARKER=str(self.marker),
                                VISION_DESK_TEST_OUTPUT_BASE=str(self.root / "results"))

    def write_tool(self, path, content):
        path.write_text(content)
        path.chmod(0o755)

    def run_launcher(self, identifier=VISION_ID):
        return subprocess.run(["bash", str(self.script / "test_vision.sh"), identifier],
                              cwd=self.root, env=self.environment, text=True, capture_output=True)

    def test_runs_native_test_action_on_exact_destination_and_preserves_previous_results(self):
        for _ in range(2):
            result = self.run_launcher()
            self.assertEqual(result.returncode, 0, result.stderr)
        runs = list((self.root / "results").glob("run.*"))
        self.assertEqual(len(runs), 2)
        for run in runs:
            self.assertTrue((run / "VisionTests.xcresult/synthetic-result.txt").is_file())
            self.assertIn("Synthetic xcodebuild output", (run / "xcodebuild.log").read_text())
        arguments = json.loads(self.marker.read_text())
        self.assertEqual(arguments[-1], "test")
        self.assertEqual(arguments[arguments.index("-destination") + 1],
                         "platform=visionOS Simulator,id=" + VISION_ID)
        self.assertEqual(arguments[arguments.index("-parallel-testing-enabled") + 1], "NO")
        self.assertEqual(arguments[arguments.index("-test-timeouts-enabled") + 1], "YES")
        self.assertEqual(arguments[arguments.index("-default-test-execution-time-allowance") + 1], "120")
        self.assertEqual(arguments[arguments.index("-maximum-test-execution-time-allowance") + 1], "120")

    def test_failed_native_run_returns_failure_and_preserves_log_and_result(self):
        self.environment["FIXTURE_TEST_STATUS"] = "65"
        result = self.run_launcher()
        self.assertEqual(result.returncode, 65)
        run = next((self.root / "results").glob("run.*"))
        self.assertTrue((run / "VisionTests.xcresult/synthetic-result.txt").is_file())
        self.assertIn("Synthetic xcodebuild output", (run / "xcodebuild.log").read_text())

    def test_nonvision_target_fails_before_xcodebuild(self):
        result = self.run_launcher(IOS_ID)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.marker.exists())

    def test_missing_sdk_fails_before_xcodebuild(self):
        self.environment["FIXTURE_MISSING_SDK"] = "1"
        result = self.run_launcher()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.marker.exists())


if __name__ == "__main__":
    unittest.main()
