#!/usr/bin/env python3
"""
Test the kernel bridge for ipynb.nvim

Run with: uv run python tests/test_kernel_bridge.py
Or: uv run pytest tests/test_kernel_bridge.py -v
"""

import subprocess
import time
import json
import os
import sys

# Get the path to the bridge script
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PLUGIN_DIR = os.path.dirname(SCRIPT_DIR)
BRIDGE_PATH = os.path.join(PLUGIN_DIR, "python", "kernel_bridge.py")


class KernelBridgeTest:
    """Test harness for kernel bridge."""

    def __init__(self):
        self.proc = None

    def start(self):
        """Start the kernel bridge process."""
        self.proc = subprocess.Popen(
            ["uv", "run", "python", BRIDGE_PATH],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            cwd=PLUGIN_DIR,
        )

    def stop(self):
        """Stop the kernel bridge process."""
        if self.proc:
            try:
                self.send({"action": "shutdown"})
                self.proc.wait(timeout=5)
            except Exception:
                self.proc.terminate()
            self.proc = None

    def send(self, cmd: dict):
        """Send a command to the bridge."""
        self.proc.stdin.write(json.dumps(cmd) + "\n")
        self.proc.stdin.flush()

    def read_message(self, timeout: float = 5.0) -> dict | None:
        """Read a single message from the bridge."""
        import select

        start = time.time()
        while time.time() - start < timeout:
            if select.select([self.proc.stdout], [], [], 0.1)[0]:
                line = self.proc.stdout.readline()
                if line:
                    return json.loads(line.strip())
        return None

    def read_messages(self, timeout: float = 5.0) -> list[dict]:
        """Read all available messages within timeout."""
        import select

        messages = []
        start = time.time()
        while time.time() - start < timeout:
            if select.select([self.proc.stdout], [], [], 0.1)[0]:
                line = self.proc.stdout.readline()
                if line:
                    messages.append(json.loads(line.strip()))
        return messages

    def wait_for_message(self, msg_type: str, timeout: float = 10.0) -> dict | None:
        """Wait for a specific message type."""
        start = time.time()
        while time.time() - start < timeout:
            msg = self.read_message(timeout=0.5)
            if msg and msg.get("type") == msg_type:
                return msg
        return None


def test_bridge_ready():
    """Test that bridge starts and sends ready message."""
    bridge = KernelBridgeTest()
    try:
        bridge.start()
        msg = bridge.read_message(timeout=5)
        assert msg is not None, "No message received"
        assert msg["type"] == "ready", f"Expected 'ready', got {msg['type']}"
        print("PASS: Bridge starts and sends ready message")
    finally:
        bridge.stop()


def test_ping_pong():
    """Test ping/pong functionality."""
    bridge = KernelBridgeTest()
    try:
        bridge.start()
        bridge.read_message()  # consume ready

        bridge.send({"action": "ping"})
        msg = bridge.read_message(timeout=2)
        assert msg is not None, "No pong received"
        assert msg["type"] == "pong", f"Expected 'pong', got {msg['type']}"
        print("PASS: Ping/pong works")
    finally:
        bridge.stop()


def test_kernel_start():
    """Test starting a kernel."""
    bridge = KernelBridgeTest()
    try:
        bridge.start()
        bridge.read_message()  # consume ready

        bridge.send({"action": "start", "kernel_name": "python3"})
        msg = bridge.wait_for_message("kernel_started", timeout=30)
        assert msg is not None, "Kernel did not start"
        assert msg["kernel_name"] == "python3"
        assert "kernel_id" in msg
        print(f"PASS: Kernel started with ID {msg['kernel_id']}")
    finally:
        bridge.stop()


def test_code_execution():
    """Test executing code in the kernel."""
    bridge = KernelBridgeTest()
    try:
        bridge.start()
        bridge.read_message()  # consume ready

        # Start kernel
        bridge.send({"action": "start", "kernel_name": "python3"})
        msg = bridge.wait_for_message("kernel_started", timeout=30)
        assert msg is not None, "Kernel did not start"

        # Execute code
        bridge.send({
            "action": "execute",
            "code": "print('Hello from test!')",
            "cell_idx": 0
        })

        # Collect messages until idle
        messages = []
        while True:
            msg = bridge.read_message(timeout=10)
            if msg is None:
                break
            messages.append(msg)
            if msg.get("type") == "status" and msg.get("state") == "idle":
                break

        # Verify we got expected message types
        msg_types = [m["type"] for m in messages]
        assert "execute_request" in msg_types, "Missing execute_request"
        assert "output" in msg_types, "Missing output"

        # Find the output message
        output_msg = next((m for m in messages if m["type"] == "output"), None)
        assert output_msg is not None
        assert output_msg["output"]["output_type"] == "stream"
        assert "Hello from test!" in output_msg["output"]["text"]

        print("PASS: Code execution works")
    finally:
        bridge.stop()


def test_execution_count():
    """Test that execution count increments."""
    bridge = KernelBridgeTest()
    try:
        bridge.start()
        bridge.read_message()  # consume ready

        # Start kernel
        bridge.send({"action": "start", "kernel_name": "python3"})
        bridge.wait_for_message("kernel_started", timeout=30)

        # Execute twice
        for i in range(2):
            bridge.send({
                "action": "execute",
                "code": f"x = {i}",
                "cell_idx": i
            })
            # Wait for idle
            while True:
                msg = bridge.read_message(timeout=10)
                if msg and msg.get("type") == "status" and msg.get("state") == "idle":
                    break

        # Execute a third time and check execution count
        bridge.send({
            "action": "execute",
            "code": "y = 2",
            "cell_idx": 2
        })

        exec_input = bridge.wait_for_message("execute_input", timeout=10)
        assert exec_input is not None
        assert exec_input["execution_count"] == 3, f"Expected count 3, got {exec_input['execution_count']}"

        print("PASS: Execution count increments correctly")
    finally:
        bridge.stop()


def test_execute_result():
    """Test execute_result output type."""
    bridge = KernelBridgeTest()
    try:
        bridge.start()
        bridge.read_message()  # consume ready

        # Start kernel
        bridge.send({"action": "start", "kernel_name": "python3"})
        bridge.wait_for_message("kernel_started", timeout=30)

        # Execute expression (should produce execute_result)
        bridge.send({
            "action": "execute",
            "code": "1 + 1",
            "cell_idx": 0
        })

        # Collect until idle
        messages = []
        while True:
            msg = bridge.read_message(timeout=10)
            if msg is None:
                break
            messages.append(msg)
            if msg.get("type") == "status" and msg.get("state") == "idle":
                break

        # Find execute_result
        result_msg = next(
            (m for m in messages if m["type"] == "output" and
             m["output"]["output_type"] == "execute_result"),
            None
        )
        assert result_msg is not None, "Missing execute_result output"
        assert "2" in result_msg["output"]["data"]["text/plain"]

        print("PASS: Execute result works")
    finally:
        bridge.stop()


def test_error_handling():
    """Test error output from invalid code."""
    bridge = KernelBridgeTest()
    try:
        bridge.start()
        bridge.read_message()  # consume ready

        # Start kernel
        bridge.send({"action": "start", "kernel_name": "python3"})
        bridge.wait_for_message("kernel_started", timeout=30)

        # Execute invalid code
        bridge.send({
            "action": "execute",
            "code": "undefined_variable",
            "cell_idx": 0
        })

        # Collect until idle
        messages = []
        while True:
            msg = bridge.read_message(timeout=10)
            if msg is None:
                break
            messages.append(msg)
            if msg.get("type") == "status" and msg.get("state") == "idle":
                break

        # Find error output
        error_msg = next(
            (m for m in messages if m["type"] == "output" and
             m["output"]["output_type"] == "error"),
            None
        )
        assert error_msg is not None, "Missing error output"
        assert error_msg["output"]["ename"] == "NameError"

        print("PASS: Error handling works")
    finally:
        bridge.stop()


def test_interrupt():
    """Test kernel interrupt."""
    bridge = KernelBridgeTest()
    try:
        bridge.start()
        bridge.read_message()  # consume ready

        # Start kernel
        bridge.send({"action": "start", "kernel_name": "python3"})
        bridge.wait_for_message("kernel_started", timeout=30)

        # Execute long-running code
        bridge.send({
            "action": "execute",
            "code": "import time; time.sleep(60)",
            "cell_idx": 0
        })

        # Wait for busy state
        bridge.wait_for_message("status", timeout=5)

        # Interrupt
        time.sleep(0.5)  # Give kernel time to start execution
        bridge.send({"action": "interrupt"})

        # Should get interrupted message
        msg = bridge.wait_for_message("interrupted", timeout=10)
        assert msg is not None, "Interrupt did not work"

        print("PASS: Kernel interrupt works")
    finally:
        bridge.stop()


def test_restart():
    """Test kernel restart."""
    bridge = KernelBridgeTest()
    try:
        bridge.start()
        bridge.read_message()  # consume ready

        # Start kernel
        bridge.send({"action": "start", "kernel_name": "python3"})
        bridge.wait_for_message("kernel_started", timeout=30)

        # Execute to set a variable
        bridge.send({
            "action": "execute",
            "code": "test_var = 'before_restart'",
            "cell_idx": 0
        })
        while True:
            msg = bridge.read_message(timeout=10)
            if msg and msg.get("type") == "status" and msg.get("state") == "idle":
                break

        # Restart - collect all messages until we see 'restarted'
        bridge.send({"action": "restart"})

        # Read messages until we get 'restarted' or timeout
        restarted = False
        start = time.time()
        while time.time() - start < 60:
            msg = bridge.read_message(timeout=1)
            if msg and msg.get("type") == "restarted":
                restarted = True
                break

        assert restarted, "Restart did not complete"

        # Wait a moment for kernel to be ready
        time.sleep(1)

        # Try to access the variable (should fail)
        bridge.send({
            "action": "execute",
            "code": "test_var",
            "cell_idx": 1
        })

        # Should get error (variable doesn't exist)
        messages = []
        while True:
            msg = bridge.read_message(timeout=10)
            if msg is None:
                break
            messages.append(msg)
            if msg.get("type") == "status" and msg.get("state") == "idle":
                break

        error_msg = next(
            (m for m in messages if m["type"] == "output" and
             m["output"]["output_type"] == "error"),
            None
        )
        assert error_msg is not None, "Variable should not exist after restart"

        print("PASS: Kernel restart works")
    finally:
        bridge.stop()


def run_all_tests():
    """Run all tests."""
    tests = [
        test_bridge_ready,
        test_ping_pong,
        test_kernel_start,
        test_code_execution,
        test_execution_count,
        test_execute_result,
        test_error_handling,
        test_interrupt,
        test_restart,
    ]

    print("=" * 60)
    print("Running kernel bridge tests")
    print("=" * 60)

    passed = 0
    failed = 0

    for test in tests:
        print(f"\n--- {test.__name__} ---")
        try:
            test()
            passed += 1
        except AssertionError as e:
            print(f"FAIL: {e}")
            failed += 1
        except Exception as e:
            print(f"ERROR: {e}")
            failed += 1

    print("\n" + "=" * 60)
    print(f"Results: {passed} passed, {failed} failed")
    print("=" * 60)

    return failed == 0


if __name__ == "__main__":
    success = run_all_tests()
    sys.exit(0 if success else 1)
