#!/usr/bin/env python3
"""
Jupyter kernel bridge for ipynb.nvim

Communicates with Neovim via JSON over stdin/stdout.
Uses jupyter_client to manage kernel connections.
"""

import json
import sys
import threading
import queue
from typing import Optional, Dict, Any

from inspect_parsers import get_parser


try:
    import jupyter_client
except ImportError:
    print(json.dumps({
        "type": "error",
        "error": "jupyter_client not installed. Install with: pip install jupyter_client"
    }), flush=True)
    sys.exit(1)


class KernelBridge:
    """Manages a Jupyter kernel connection and handles message passing."""

    def __init__(self):
        self.kernel_manager: Optional[jupyter_client.KernelManager] = None
        self.kernel_client: Optional[jupyter_client.KernelClient] = None
        self.kernel_name: str = "python3"
        self.kernel_language: Optional[str] = None
        self.execution_count: int = 0
        self.pending_executions: Dict[str, Dict[str, Any]] = {}
        self.iopub_thread: Optional[threading.Thread] = None
        self.running = True
        self.output_queue = queue.Queue()

    def send_message(self, msg: Dict[str, Any]):
        """Send a JSON message to stdout."""
        print(json.dumps(msg), flush=True)

    def start_kernel(self, kernel_name: str = "python3") -> bool:
        """Start a new Jupyter kernel."""
        try:
            self.kernel_name = kernel_name
            self.kernel_manager = jupyter_client.KernelManager(kernel_name=kernel_name)
            self.kernel_manager.start_kernel()
            self.kernel_client = self.kernel_manager.client()
            self.kernel_client.start_channels()

            # Wait for kernel to be ready
            self.kernel_client.wait_for_ready(timeout=30)

            # Start iopub listener thread
            self._start_iopub_listener()

            # Get language from kernelspec
            language = None
            try:
                language = self.kernel_manager.kernel_spec.language
            except Exception:
                pass
            self.kernel_language = language

            self.send_message({
                "type": "kernel_started",
                "kernel_name": kernel_name,
                "kernel_id": self.kernel_manager.kernel_id or "unknown",
                "language": language
            })
            return True
        except Exception as e:
            self.send_message({
                "type": "error",
                "error": f"Failed to start kernel: {str(e)}"
            })
            return False

    def connect_to_kernel(self, connection_file: str) -> bool:
        """Connect to an existing kernel via connection file."""
        try:
            self.kernel_manager = jupyter_client.KernelManager(connection_file=connection_file)
            self.kernel_manager.load_connection_file()
            self.kernel_client = self.kernel_manager.client()
            self.kernel_client.start_channels()
            self.kernel_client.wait_for_ready(timeout=30)

            self._start_iopub_listener()

            language = None
            try:
                language = self.kernel_manager.kernel_spec.language
            except Exception:
                pass
            self.kernel_language = language

            self.send_message({
                "type": "kernel_connected",
                "connection_file": connection_file
            })
            return True
        except Exception as e:
            self.send_message({
                "type": "error",
                "error": f"Failed to connect to kernel: {str(e)}"
            })
            return False

    def _start_iopub_listener(self):
        """Start a thread to listen for iopub messages."""
        def listener():
            while self.running and self.kernel_client:
                try:
                    msg = self.kernel_client.get_iopub_msg(timeout=0.5)
                    self._handle_iopub_message(msg)
                except queue.Empty:
                    continue
                except Exception as e:
                    if self.running:
                        self.send_message({
                            "type": "error",
                            "error": f"IOPub listener error: {str(e)}"
                        })

        self.iopub_thread = threading.Thread(target=listener, daemon=True)
        self.iopub_thread.start()

    def _handle_iopub_message(self, msg: Dict[str, Any]):
        """Handle a message from the iopub channel."""
        msg_type = msg.get("msg_type", "")
        content = msg.get("content", {})
        parent_header = msg.get("parent_header", {})
        msg_id = parent_header.get("msg_id", "")

        # Find the cell this message belongs to
        exec_info = self.pending_executions.get(msg_id, {})
        cell_idx = exec_info.get("cell_idx")

        if msg_type == "status":
            execution_state = content.get("execution_state", "")
            self.send_message({
                "type": "status",
                "state": execution_state,
                "cell_idx": cell_idx
            })

        elif msg_type == "stream":
            self.send_message({
                "type": "output",
                "cell_idx": cell_idx,
                "output": {
                    "output_type": "stream",
                    "name": content.get("name", "stdout"),
                    "text": content.get("text", "")
                }
            })

        elif msg_type == "execute_result":
            self.send_message({
                "type": "output",
                "cell_idx": cell_idx,
                "output": {
                    "output_type": "execute_result",
                    "execution_count": content.get("execution_count"),
                    "data": content.get("data", {}),
                    "metadata": content.get("metadata", {})
                }
            })

        elif msg_type == "display_data":
            self.send_message({
                "type": "output",
                "cell_idx": cell_idx,
                "output": {
                    "output_type": "display_data",
                    "data": content.get("data", {}),
                    "metadata": content.get("metadata", {})
                }
            })

        elif msg_type == "error":
            self.send_message({
                "type": "output",
                "cell_idx": cell_idx,
                "output": {
                    "output_type": "error",
                    "ename": content.get("ename", "Error"),
                    "evalue": content.get("evalue", ""),
                    "traceback": content.get("traceback", [])
                }
            })

        elif msg_type == "execute_input":
            # Execution started
            self.send_message({
                "type": "execute_input",
                "cell_idx": cell_idx,
                "execution_count": content.get("execution_count")
            })

    def execute(self, code: str, cell_idx: int, user_expressions: Optional[Dict[str, str]] = None) -> Optional[str]:
        """Execute code in the kernel with optional user_expressions for namespace capture."""
        if not self.kernel_client:
            self.send_message({
                "type": "error",
                "error": "No kernel connected"
            })
            return None

        try:
            msg_id = self.kernel_client.execute(code, user_expressions=user_expressions or {})
            self.pending_executions[msg_id] = {
                "cell_idx": cell_idx,
                "code": code,
                "has_user_expressions": bool(user_expressions)
            }
            self.send_message({
                "type": "execute_request",
                "cell_idx": cell_idx,
                "msg_id": msg_id
            })

            # If user_expressions provided, wait for execute_reply on shell channel
            if user_expressions:
                self._wait_for_execute_reply(msg_id, cell_idx)

            return msg_id
        except Exception as e:
            self.send_message({
                "type": "error",
                "error": f"Execution failed: {str(e)}",
                "cell_idx": cell_idx
            })
            return None

    def _wait_for_execute_reply(self, msg_id: str, cell_idx: int):
        """Wait for execute_reply on shell channel and extract user_expressions results."""
        try:
            # Poll shell channel for the execute_reply (with timeout)
            while True:
                reply = self.kernel_client.get_shell_msg(timeout=10)
                if not reply:
                    break
                # Check if this is the reply for our execution
                if reply.get("parent_header", {}).get("msg_id") == msg_id:
                    if reply.get("msg_type") == "execute_reply":
                        content = reply.get("content", {})
                        user_expr_results = content.get("user_expressions", {})

                        # Extract __ns__ result if present
                        ns_result = user_expr_results.get("__ns__", {})
                        if ns_result.get("status") == "ok":
                            ns_data = ns_result.get("data", {}).get("text/plain", "{}")
                            self.send_message({
                                "type": "namespace",
                                "cell_idx": cell_idx,
                                "namespace_repr": ns_data
                            })
                        elif ns_result.get("status") == "error":
                            # user_expressions evaluation failed, don't crash
                            pass
                        break
        except Exception as e:
            # Don't fail execution if namespace capture fails
            self.send_message({
                "type": "error",
                "error": f"Warning: Failed to capture namespace: {str(e)}"
            })

    def interrupt(self):
        """Interrupt the kernel."""
        if self.kernel_manager:
            try:
                self.kernel_manager.interrupt_kernel()
                self.send_message({"type": "interrupted"})
            except Exception as e:
                self.send_message({
                    "type": "error",
                    "error": f"Failed to interrupt: {str(e)}"
                })

    def restart(self):
        """Restart the kernel."""
        if self.kernel_manager:
            try:
                self.kernel_manager.restart_kernel()
                self.kernel_client.wait_for_ready(timeout=30)
                self.execution_count = 0
                self.pending_executions.clear()
                self.send_message({"type": "restarted"})
            except Exception as e:
                self.send_message({
                    "type": "error",
                    "error": f"Failed to restart: {str(e)}"
                })

    def shutdown(self):
        """Shutdown the kernel."""
        self.running = False
        if self.kernel_client:
            self.kernel_client.stop_channels()
        if self.kernel_manager:
            try:
                self.kernel_manager.shutdown_kernel(now=True)
            except Exception:
                pass
        self.send_message({"type": "shutdown"})

    def get_kernel_info(self):
        """Get kernel information."""
        if self.kernel_client:
            try:
                info = self.kernel_client.kernel_info()
                self.send_message({
                    "type": "kernel_info",
                    "info": info
                })
            except Exception as e:
                self.send_message({
                    "type": "error",
                    "error": f"Failed to get kernel info: {str(e)}"
                })
        else:
            self.send_message({
                "type": "kernel_info",
                "info": None,
                "connected": False
            })

    def is_alive(self) -> bool:
        """Check if the kernel is alive."""
        if self.kernel_manager:
            return self.kernel_manager.is_alive()
        return False

    def complete(self, code: str, cursor_pos: int):
        """Request code completion."""
        if not self.kernel_client:
            self.send_message({
                "type": "error",
                "error": "No kernel connected"
            })
            return

        try:
            msg_id = self.kernel_client.complete(code, cursor_pos)
            # Completions come back on shell channel
            reply = self.kernel_client.get_shell_msg(timeout=5)
            if reply and reply.get("msg_type") == "complete_reply":
                content = reply.get("content", {})
                self.send_message({
                    "type": "complete_reply",
                    "matches": content.get("matches", []),
                    "cursor_start": content.get("cursor_start", 0),
                    "cursor_end": content.get("cursor_end", cursor_pos),
                    "metadata": content.get("metadata", {})
                })
        except Exception as e:
            self.send_message({
                "type": "error",
                "error": f"Completion failed: {str(e)}"
            })

    def inspect(self, code: str, cursor_pos: int, detail_level: int = 0, request_id: Optional[str] = None):
        """Request variable/object inspection using Jupyter's inspect_request protocol."""
        if not self.kernel_client:
            self.send_message({
                "type": "error",
                "error": "No kernel connected"
            })
            return

        try:
            msg_id = self.kernel_client.inspect(code, cursor_pos, detail_level)
            # Inspection reply comes back on shell channel - wait for OUR reply
            while True:
                reply = self.kernel_client.get_shell_msg(timeout=5)
                if not reply:
                    break
                # Check if this reply is for our request
                parent_msg_id = reply.get("parent_header", {}).get("msg_id")
                if parent_msg_id != msg_id:
                    # Not our reply, keep waiting
                    continue
                if reply.get("msg_type") == "inspect_reply":
                    content = reply.get("content", {})
                    data = content.get("data", {})
                    sections = {}
                    # Return raw text/plain for now; no custom parsing
                    parser = get_parser(self.kernel_language, self.kernel_name)
                    sections = parser(data)
                    self.send_message({
                        "type": "inspect_reply",
                        "request_id": request_id,
                        "found": content.get("found", False),
                        "sections": sections,
                        "data": data,
                        "metadata": content.get("metadata", {})
                    })
                    return
                break
            # No valid reply found
            self.send_message({
                "type": "inspect_reply",
                "request_id": request_id,
                "found": False,
                "sections": {},
                "data": {},
                "metadata": {}
            })
        except Exception as e:
            self.send_message({
                "type": "error",
                "error": f"Inspection failed: {str(e)}"
            })


def main():
    """Main entry point - read commands from stdin, send responses to stdout."""
    bridge = KernelBridge()

    # Signal ready
    bridge.send_message({"type": "ready"})

    try:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue

            try:
                cmd = json.loads(line)
            except json.JSONDecodeError as e:
                bridge.send_message({
                    "type": "error",
                    "error": f"Invalid JSON: {str(e)}"
                })
                continue

            action = cmd.get("action", "")

            if action == "start":
                kernel_name = cmd.get("kernel_name", "python3")
                bridge.start_kernel(kernel_name)

            elif action == "connect":
                connection_file = cmd.get("connection_file")
                if connection_file:
                    bridge.connect_to_kernel(connection_file)
                else:
                    bridge.send_message({
                        "type": "error",
                        "error": "Missing connection_file parameter"
                    })

            elif action == "execute":
                code = cmd.get("code", "")
                cell_idx = cmd.get("cell_idx", 0)
                user_expressions = cmd.get("user_expressions")
                bridge.execute(code, cell_idx, user_expressions)

            elif action == "interrupt":
                bridge.interrupt()

            elif action == "restart":
                bridge.restart()

            elif action == "shutdown":
                bridge.shutdown()
                break

            elif action == "info":
                bridge.get_kernel_info()

            elif action == "is_alive":
                bridge.send_message({
                    "type": "is_alive",
                    "alive": bridge.is_alive()
                })

            elif action == "complete":
                code = cmd.get("code", "")
                cursor_pos = cmd.get("cursor_pos", len(code))
                bridge.complete(code, cursor_pos)

            elif action == "inspect":
                code = cmd.get("code", "")
                cursor_pos = cmd.get("cursor_pos", len(code))
                detail_level = cmd.get("detail_level", 0)
                request_id = cmd.get("request_id")
                bridge.inspect(code, cursor_pos, detail_level, request_id)

            elif action == "ping":
                bridge.send_message({"type": "pong"})

            else:
                bridge.send_message({
                    "type": "error",
                    "error": f"Unknown action: {action}"
                })

    except KeyboardInterrupt:
        pass
    finally:
        bridge.shutdown()


if __name__ == "__main__":
    main()
