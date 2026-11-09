#!/usr/bin/env python3
"""Run a Web Inspector debugger flow against one named iOS Simulator JSC process.

This is intentionally a Web Inspector client, not a CDP client. The caller supplies the exact webinspectord socket and target names, so this driver never selects an arbitrary simulator or application.
"""
from __future__ import annotations

import argparse
import json
import os
import plistlib
import queue
import re
import select
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
import uuid
from collections import deque
from typing import Any, Callable


def public(value: Any) -> Any:
    if isinstance(value, dict):
        return {str(key): public(item) for key, item in value.items() if key != "WIRApplicationIconKey"}
    if isinstance(value, list):
        return [public(item) for item in value]
    if isinstance(value, bytes):
        return {"bytes": len(value)}
    return value


def argument(message: dict[str, Any]) -> dict[str, Any]:
    value = message.get("__argument")
    return value if isinstance(value, dict) else {}


def protocol_messages(value: Any) -> list[dict[str, Any]]:
    pending = [value]
    messages: list[dict[str, Any]] = []
    while pending:
        current = pending.pop()
        if isinstance(current, dict):
            if isinstance(current.get("id"), int) or isinstance(current.get("method"), str):
                messages.append(current)
            pending.extend(current.values())
        elif isinstance(current, list):
            pending.extend(current)
        elif isinstance(current, bytes):
            try:
                pending.append(json.loads(current.decode("utf-8")))
            except (UnicodeDecodeError, json.JSONDecodeError):
                pass
        elif isinstance(current, str):
            try:
                pending.append(json.loads(current))
            except json.JSONDecodeError:
                pass
    return messages


class Wire:
    def __init__(self, path: str, deadline: float):
        self.deadline = deadline
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.settimeout(self.remaining())
        self.socket.connect(path)

    def remaining(self) -> float:
        left = self.deadline - time.monotonic()
        if left <= 0:
            raise TimeoutError("Web Inspector deadline expired")
        return left

    def close(self) -> None:
        self.socket.close()

    def read_exact(self, count: int) -> bytes:
        chunks = []
        while count:
            self.socket.settimeout(self.remaining())
            chunk = self.socket.recv(count)
            if not chunk:
                raise RuntimeError("webinspectord closed the socket")
            chunks.append(chunk)
            count -= len(chunk)
        return b"".join(chunks)

    def receive(self) -> dict[str, Any]:
        length = struct.unpack(">I", self.read_exact(4))[0]
        return plistlib.loads(self.read_exact(length))

    def send(self, selector: str, payload: dict[str, Any]) -> None:
        self.remaining()
        frame = plistlib.dumps({"__selector": selector, "__argument": payload}, fmt=plistlib.FMT_BINARY, sort_keys=False)
        self.socket.sendall(struct.pack(">I", len(frame)) + frame)


class Client:
    def __init__(self, wire: Wire, connection: str, application: str, page: int, sender: str):
        self.wire = wire
        self.connection = connection
        self.application = application
        self.page = page
        self.sender = sender
        self.next_id = 1
        self.pending: deque[dict[str, Any]] = deque()

    def receive_matching(self, predicate: Callable[[dict[str, Any]], bool], label: str) -> dict[str, Any]:
        retained: deque[dict[str, Any]] = deque()
        while self.pending:
            item = self.pending.popleft()
            if predicate(item):
                self.pending.extendleft(reversed(retained))
                return item
            retained.append(item)
        self.pending.extend(retained)
        selectors: list[str] = []
        while True:
            try:
                self.wire.remaining()
                item = self.wire.receive()
            except (socket.timeout, RuntimeError) as error:
                raise TimeoutError(f"timeout waiting for {label}; selectors={selectors[-8:]}") from error
            selectors.append(str(item.get("__selector", "")))
            if predicate(item):
                return item
            self.pending.append(item)

    def request(self, method: str, params: dict[str, Any] | None = None, wait: bool = True) -> dict[str, Any] | int:
        request_id = self.next_id
        self.next_id += 1
        command = json.dumps({"id": request_id, "method": method, "params": params or {}}).encode("utf-8")
        self.wire.send("_rpc_forwardSocketData:", {
            "WIRSocketDataKey": command,
            "WIRConnectionIdentifierKey": self.connection,
            "WIRSenderKey": self.sender,
            "WIRApplicationIdentifierKey": self.application,
            "WIRPageIdentifierKey": self.page,
        })
        if not wait:
            return request_id
        try:
            message = self.receive_matching(
                lambda item: any(protocol.get("id") == request_id for protocol in protocol_messages(argument(item))), method,
            )
        except (TimeoutError, RuntimeError) as error:
            raise TimeoutError(f"{method}: {error}") from error
        answer = [protocol for protocol in protocol_messages(argument(message)) if protocol.get("id") == request_id][-1]
        if "error" in answer:
            raise RuntimeError(f"{method}: {public(answer['error'])}")
        return answer

    def close_inspector(self) -> None:
        self.wire.send("_rpc_forwardDidClose:", {
            "WIRConnectionIdentifierKey": self.connection,
            "WIRApplicationIdentifierKey": self.application,
            "WIRPageIdentifierKey": self.page,
            "WIRSenderKey": self.sender,
        })


def apps(message: dict[str, Any]) -> list[tuple[str, dict[str, Any]]]:
    values = argument(message)
    dictionary = values.get("WIRApplicationDictionaryKey")
    if isinstance(dictionary, dict):
        return [(str(identifier), metadata) for identifier, metadata in dictionary.items() if isinstance(metadata, dict)]
    identifier = values.get("WIRApplicationIdentifierKey")
    if isinstance(identifier, str) and isinstance(values.get("WIRApplicationNameKey"), str):
        return [(identifier, values)]
    return []


def page(message: dict[str, Any], name: str) -> tuple[int, dict[str, Any]] | None:
    listing = argument(message).get("WIRListingKey", {})
    if not isinstance(listing, dict):
        return None
    for identifier, metadata in listing.items():
        if isinstance(metadata, dict) and metadata.get("WIRTitleKey") == name and metadata.get("WIRTypeKey") == "WIRTypeJavaScript":
            return int(identifier), metadata
    return None


def listing_page(message: dict[str, Any], application: str, target_name: str) -> tuple[int, dict[str, Any]] | None:
    if argument(message).get("WIRApplicationIdentifierKey") != application:
        return None
    return page(message, target_name)


def listing_has_connection(message: dict[str, Any], application: str, target_name: str, connection: str) -> bool:
    selected = listing_page(message, application, target_name)
    return selected is not None and selected[1].get("WIRConnectionIdentifierKey") == connection


def listing_is_detached(message: dict[str, Any], application: str, target_name: str) -> bool:
    selected = listing_page(message, application, target_name)
    return selected is not None and not selected[1].get("WIRConnectionIdentifierKey")


class DiscoveryMonitor:
    def __init__(self, client: Client, target_name: str):
        self.client = client
        self.target_name = target_name

    @classmethod
    def connect(cls, socket_path: str, application_name: str, target_name: str, deadline: float) -> DiscoveryMonitor:
        wire = Wire(socket_path, deadline)
        connection = str(uuid.uuid4())
        wire.send("_rpc_reportIdentifier:", {"WIRConnectionIdentifierKey": connection})
        wire.send("_rpc_getConnectedApplications:", {"WIRConnectionIdentifierKey": connection})
        client = Client(wire, connection, "", 0, str(uuid.uuid4()))
        message = client.receive_matching(
            lambda item: any(metadata.get("WIRApplicationNameKey") == application_name for _, metadata in apps(item)),
            f"monitor application {application_name!r}",
        )
        client.application = next(identifier for identifier, metadata in apps(message) if metadata.get("WIRApplicationNameKey") == application_name)
        monitor = cls(client, target_name)
        monitor.request_listing()
        client.receive_matching(monitor.has_target, "initial monitor listing")
        return monitor

    def has_target(self, message: dict[str, Any]) -> bool:
        return listing_page(message, self.client.application, self.target_name) is not None

    def request_listing(self) -> None:
        self.client.wire.send("_rpc_forwardGetListing:", {
            "WIRConnectionIdentifierKey": self.client.connection,
            "WIRApplicationIdentifierKey": self.client.application,
        })

    def detach(self, debugger: Client) -> None:
        self.client.pending.clear()
        self.request_listing()
        self.client.receive_matching(
            lambda message: listing_has_connection(message, self.client.application, self.target_name, debugger.connection),
            "monitor attached target connection",
        )
        print("[ok] monitor sees active target connection")
        self.client.pending.clear()
        debugger.close_inspector()
        self.request_listing()
        self.client.receive_matching(
            lambda message: listing_is_detached(message, self.client.application, self.target_name),
            "monitor detached target connection",
        )
        print("[ok] monitor sees detached target connection")

    def close(self) -> None:
        self.client.wire.close()


def connect(socket_path: str, application_name: str, target_name: str, deadline: float) -> Client:
    wire = Wire(socket_path, deadline)
    connection = str(uuid.uuid4())
    sender = str(uuid.uuid4())
    wire.send("_rpc_reportIdentifier:", {"WIRConnectionIdentifierKey": connection})
    wire.send("_rpc_getConnectedApplications:", {"WIRConnectionIdentifierKey": connection})
    bootstrap = Client(wire, connection, "", 0, sender)
    match: tuple[str, dict[str, Any]] | None = None
    selectors: list[str] = []
    while match is None:
        try:
            bootstrap.wire.remaining()
            message = bootstrap.wire.receive()
        except (TimeoutError, RuntimeError) as error:
            raise TimeoutError(f"target application {application_name!r}: {error}; selectors={selectors[-8:]}") from error
        selectors.append(str(message.get("__selector", "")))
        match = next(((identifier, metadata) for identifier, metadata in apps(message) if metadata.get("WIRApplicationNameKey") == application_name), None)
    application, _ = match
    wire.send("_rpc_forwardGetListing:", {"WIRConnectionIdentifierKey": connection, "WIRApplicationIdentifierKey": application})
    listing = bootstrap.receive_matching(lambda message: listing_page(message, application, target_name) is not None, "JavaScript context")
    selected = listing_page(listing, application, target_name)
    if selected is None:
        raise RuntimeError(f"target {target_name!r} was not discovered")
    page_id, _ = selected
    wire.send("_rpc_forwardSocketSetup:", {
        "WIRApplicationIdentifierKey": application,
        "WIRConnectionIdentifierKey": connection,
        "WIRSenderKey": sender,
        "WIRPageIdentifierKey": page_id,
        "WIRMessageDataTypeChunkSupportedKey": 0,
    })
    return Client(wire, connection, application, page_id, sender)


def result_value(answer: dict[str, Any]) -> Any:
    return answer.get("result", {}).get("result", {}).get("value")


class SimulatorProcess:
    def __init__(self, simulator: str, binary: str, deadline: float):
        self.binary = os.path.realpath(binary)
        self.output: list[str] = []
        self.events: queue.Queue[str | None] = queue.Queue()
        subprocess.run(
            ["xcrun", "simctl", "spawn", simulator, "launchctl", "kickstart", "user/foreground/com.apple.webinspectord"],
            check=True,
            timeout=max(0.1, deadline - time.monotonic()),
        )
        self.process = subprocess.Popen(
            ["xcrun", "simctl", "spawn", simulator, binary],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        assert self.process.stdout is not None
        self.reader = threading.Thread(target=self._read, args=(self.process.stdout,), daemon=True)
        self.reader.start()
        self.demo_pid: int | None = None
        self.exit_watch: select.kqueue | None = None
        try:
            self._wait_ready(deadline)
            socket_path = subprocess.check_output(
                ["xcrun", "simctl", "spawn", simulator, "launchctl", "getenv", "RWI_LISTEN_SOCKET"],
                text=True,
                timeout=max(0.1, deadline - time.monotonic()),
            ).strip()
            if not socket_path or not os.path.exists(socket_path):
                raise RuntimeError("the selected simulator did not expose a Web Inspector socket")
            self.socket_path = socket_path
        except Exception as startup_error:
            if self.demo_pid is None:
                self.process.terminate()
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=5)
                raise RuntimeError("JSC simulator demo failed before it reported STARTED; demo-process cleanup is unmeasurable") from startup_error
            cleanup_error: Exception | None = None
            try:
                self._stop_demo()
            except Exception as caught:
                cleanup_error = caught
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
            if cleanup_error is not None:
                raise RuntimeError(f"JSC simulator demo startup cleanup failed: {cleanup_error}") from cleanup_error
            raise startup_error

    def _read(self, stream: Any) -> None:
        for line in stream:
            self.output.append(line)
            self.events.put(line)
        self.events.put(None)

    def _wait_ready(self, deadline: float) -> None:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("JSC simulator demo did not report READY")
            try:
                line = self.events.get(timeout=remaining)
            except queue.Empty as error:
                raise TimeoutError("JSC simulator demo did not report READY") from error
            if line is None:
                raise RuntimeError("JSC simulator demo exited before READY: " + "".join(self.output))
            started = re.fullmatch(r"STARTED ([1-9][0-9]*)\n?", line)
            if started:
                self.demo_pid = int(started.group(1))
                self._watch_demo()
                continue
            ready = re.fullmatch(r"READY ([1-9][0-9]*)\n?", line)
            if ready:
                if self.demo_pid is None or int(ready.group(1)) != self.demo_pid:
                    raise RuntimeError("JSC simulator demo reported an invalid READY process identifier")
                return

    def _state(self) -> str:
        assert self.demo_pid is not None
        result = subprocess.run(["ps", "-p", str(self.demo_pid), "-o", "state=", "-o", "command="], text=True, capture_output=True)
        if result.returncode != 0 or not result.stdout.strip():
            return "gone"
        fields = result.stdout.strip().split(maxsplit=1)
        if fields[0].startswith("Z"):
            return "gone"
        if len(fields) != 2:
            return "different"
        executable = fields[1].split(maxsplit=1)[0]
        return "owned" if os.path.realpath(executable) == self.binary else "different"

    def _watch_demo(self) -> None:
        if self._state() != "owned":
            raise RuntimeError("STARTED process identifier did not name the requested demo binary")
        self.exit_watch = select.kqueue()
        event = select.kevent(self.demo_pid, filter=select.KQ_FILTER_PROC, flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE | select.KQ_EV_ONESHOT, fflags=select.KQ_NOTE_EXIT)
        self.exit_watch.control([event], 0, 0)

    def _normal_exit_confirmed(self) -> bool:
        return self.process.poll() == 0 and "CLEAN_EXIT" in "".join(self.output)

    def _wait_for_normal_exit(self, timeout: float) -> bool:
        try:
            self.process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            return False
        self.reader.join(timeout=1)
        return self._normal_exit_confirmed()

    def _wait_demo_exit(self, timeout: float) -> bool:
        if self.exit_watch is None:
            raise RuntimeError("JSC simulator demo process identity changed before cleanup")
        if self.exit_watch.control([], 1, 0):
            return True
        if self._normal_exit_confirmed():
            return True
        if self._state() == "gone":
            return True
        if self._state() != "owned":
            if self._wait_for_normal_exit(timeout):
                return True
            raise RuntimeError("JSC simulator demo process identity changed before cleanup")
        events = self.exit_watch.control([], 1, timeout)
        return bool(events) or self._state() == "gone"

    def _stop_demo(self) -> None:
        assert self.demo_pid is not None
        if self._normal_exit_confirmed():
            return
        state = self._state()
        if state == "gone":
            return
        if state != "owned":
            raise RuntimeError("JSC simulator demo process identity changed before cleanup")
        os.kill(self.demo_pid, signal.SIGTERM)
        if self._wait_demo_exit(15):
            return
        if self._normal_exit_confirmed():
            return
        if self._state() != "owned":
            raise RuntimeError("JSC simulator demo process identity changed before forced cleanup")
        os.kill(self.demo_pid, signal.SIGKILL)
        if not self._wait_demo_exit(5):
            raise RuntimeError("JSC simulator demo did not exit after SIGKILL")

    def close(self) -> None:
        error: Exception | None = None
        try:
            self._stop_demo()
        except Exception as caught:
            error = caught
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        self.reader.join(timeout=1)
        if self.exit_watch is not None:
            self.exit_watch.close()
        output = "".join(self.output)
        if error is not None:
            raise RuntimeError(f"JSC simulator demo did not stop cleanly: {error}; output={output}") from error
        if self.process.returncode != 0 or "CLEAN_EXIT" not in output:
            raise RuntimeError(f"JSC simulator demo did not report CLEAN_EXIT: {output}")


def exercise(socket_path: str, application_name: str, target_name: str, deadline: float) -> None:
    client: Client | None = None
    reconnect: Client | None = None
    monitor: DiscoveryMonitor | None = None
    cleanup_errors: list[Exception] = []
    try:
        monitor = DiscoveryMonitor.connect(socket_path, application_name, target_name, deadline)
        client = connect(socket_path, application_name, target_name, deadline)
        print("[ok] discover")
        client.request("Runtime.enable")
        print("[ok] Runtime.enable")
        client.request("Debugger.enable")
        if result_value(client.request("Runtime.evaluate", {"expression": "40 + 2", "returnByValue": True})) != 42:
            raise RuntimeError("initial evaluation did not return 42")
        source = "function __jsbayWirProbe(){\n const marker=40+2;\n const stepped=marker+1;\n return stepped;\n}\n//# sourceURL=jsbay-wir-probe.js"
        client.request("Runtime.evaluate", {"expression": source, "returnByValue": True})
        client.request("Debugger.setBreakpointsActive", {"active": True})
        breakpoint = client.request("Debugger.setBreakpointByUrl", {"lineNumber": 2, "url": "jsbay-wir-probe.js"})
        breakpoint_id = breakpoint.get("result", {}).get("breakpointId")
        locations = breakpoint.get("result", {}).get("locations", [])
        resolved_scripts = {location.get("scriptId") for location in locations if location.get("lineNumber") == 2}
        if not breakpoint_id or not resolved_scripts:
            raise RuntimeError("breakpoint was not resolved")
        print("[ok] breakpoint")
        client.request("Runtime.evaluate", {"expression": "__jsbayWirProbe()", "returnByValue": True, "doNotPauseOnExceptionsAndMuteConsole": False}, wait=False)
        paused = client.receive_matching(lambda message: any(item.get("method") == "Debugger.paused" for item in protocol_messages(argument(message))), "breakpoint pause")
        event = [item for item in protocol_messages(argument(paused)) if item.get("method") == "Debugger.paused"][-1]
        pause_params = event.get("params", {})
        if pause_params.get("reason") != "Breakpoint" or pause_params.get("data", {}).get("breakpointId") != breakpoint_id:
            raise RuntimeError("pause did not identify the configured breakpoint")
        frames = event.get("params", {}).get("callFrames", [])
        if not frames:
            raise RuntimeError("pause did not include a call frame")
        top = frames[0]
        location = top.get("location", {})
        if location.get("lineNumber") != 2 or location.get("scriptId") not in resolved_scripts:
            raise RuntimeError(f"pause used unexpected source location: {public(location)}")
        if result_value(client.request("Debugger.evaluateOnCallFrame", {"callFrameId": top.get("callFrameId"), "expression": "marker", "returnByValue": True})) != 42:
            raise RuntimeError("paused frame did not expose marker")
        print("[ok] frame-evaluate")
        client.request("Debugger.stepOver")
        stepped = client.receive_matching(lambda message: any(item.get("method") == "Debugger.paused" for item in protocol_messages(argument(message))), "step pause")
        stepped_event = [item for item in protocol_messages(argument(stepped)) if item.get("method") == "Debugger.paused"][-1]
        stepped_frames = stepped_event.get("params", {}).get("callFrames", [])
        if not stepped_frames:
            raise RuntimeError("step did not include a call frame")
        stepped_location = stepped_frames[0].get("location", {})
        if stepped_location.get("scriptId") != location.get("scriptId") or stepped_location.get("lineNumber") != 3:
            raise RuntimeError(f"step did not advance within the probe function: {public(stepped_location)}")
        client.request("Debugger.resume")
        client.request("Debugger.removeBreakpoint", {"breakpointId": breakpoint_id})
        if result_value(client.request("Runtime.evaluate", {"expression": "__jsbayWirProbe()", "returnByValue": True})) != 43:
            raise RuntimeError("resumed probe did not return 43")
        print("[ok] step-resume43")
        monitor.detach(client)
        client.wire.close()
        client = None
        reconnect = connect(socket_path, application_name, target_name, deadline)
        try:
            reconnect.request("Runtime.enable")
            if result_value(reconnect.request("Runtime.evaluate", {"expression": "6 * 7", "returnByValue": True})) != 42:
                raise RuntimeError("reconnected evaluation did not return 42")
            print("[ok] reconnect42")
        finally:
            monitor.detach(reconnect)
            reconnect.wire.close()
            reconnect = None
        print("PASS JSC iOS Simulator Web Inspector debugger flow")
    finally:
        active = reconnect if reconnect is not None else client
        if active is not None:
            try:
                try:
                    active.request("Debugger.resume")
                except Exception:
                    pass
                if monitor is not None:
                    monitor.detach(active)
                else:
                    active.close_inspector()
            except Exception as error:
                cleanup_errors.append(error)
            finally:
                active.wire.close()
        if monitor is not None:
            try:
                monitor.close()
            except Exception as error:
                cleanup_errors.append(error)
        if cleanup_errors and sys.exc_info()[0] is None:
            raise cleanup_errors[0]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket")
    parser.add_argument("--simulator")
    parser.add_argument("--binary")
    parser.add_argument("--application-name", required=True)
    parser.add_argument("--target-name", default="js-bay-demo")
    parser.add_argument("--timeout", type=float, default=20)
    args = parser.parse_args()
    if bool(args.simulator) != bool(args.binary):
        parser.error("--simulator and --binary must be supplied together")
    if args.socket and args.simulator:
        parser.error("--socket cannot be combined with --simulator")
    if not args.socket and not args.simulator:
        parser.error("supply --socket or --simulator with --binary")
    deadline = time.monotonic() + args.timeout
    process: SimulatorProcess | None = None
    flow_error: Exception | None = None
    try:
        if args.simulator:
            process = SimulatorProcess(args.simulator, args.binary, deadline)
            socket_path = process.socket_path
        else:
            socket_path = args.socket
        assert socket_path is not None
        exercise(socket_path, args.application_name, args.target_name, deadline)
    except Exception as error:
        flow_error = error
    finally:
        cleanup_error: Exception | None = None
        if process is not None:
            try:
                process.close()
                print("[ok] simulator CLEAN_EXIT")
            except Exception as error:
                cleanup_error = error
        if flow_error is not None and cleanup_error is not None:
            raise RuntimeError(f"debugger flow failed: {flow_error}; cleanup failed: {cleanup_error}") from flow_error
        if flow_error is not None:
            raise flow_error
        if cleanup_error is not None:
            raise cleanup_error


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"FAIL {error}", file=sys.stderr)
        raise SystemExit(1)
