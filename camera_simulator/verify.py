#!/usr/bin/env python3
"""Protocol verifier for the standalone ZTransfer camera simulator."""

from __future__ import annotations

import argparse
import pathlib
import socket
import struct
import subprocess
import sys
import time
from typing import Optional


INIT_CMD_REQ = 1
INIT_CMD_ACK = 2
INIT_EVT_REQ = 3
INIT_EVT_ACK = 4
CMD_REQUEST = 6
CMD_RESPONSE = 7
START_DATA_PACKET = 9
END_DATA_PACKET = 12

OPEN_SESSION = 0x1002
CLOSE_SESSION = 0x1003
GET_STORAGE_IDS = 0x1004
GET_OBJECT_HANDLES = 0x1007
GET_OBJECT_INFO = 0x1008
GET_OBJECT = 0x1009
GET_THUMB = 0x100A
NK_GET_EVENT = 0x90C7
RESPONSE_OK = 0x2001


def recv_exact(sock: socket.socket, size: int) -> bytes:
    data = bytearray()
    while len(data) < size:
        block = sock.recv(size - len(data))
        if not block:
            raise EOFError("simulator closed the connection")
        data.extend(block)
    return bytes(data)


def read_packet(sock: socket.socket) -> tuple[int, bytes]:
    length, kind = struct.unpack("<II", recv_exact(sock, 8))
    return kind, recv_exact(sock, length - 8)


def packet(kind: int, payload: bytes = b"") -> bytes:
    return struct.pack("<II", len(payload) + 8, kind) + payload


def init_command(sock: socket.socket) -> int:
    name = "Verifier".encode("utf-16le") + b"\0\0"
    payload = bytes(range(16)) + name + struct.pack("<H", 1)
    sock.sendall(packet(INIT_CMD_REQ, payload))
    kind, response = read_packet(sock)
    if kind != INIT_CMD_ACK or len(response) < 20:
        raise AssertionError(f"bad InitCmdAck: type={kind}, bytes={len(response)}")
    return struct.unpack_from("<I", response, 0)[0]


def init_event(host: str, port: int, connection_number: int) -> socket.socket:
    event = socket.create_connection((host, port), timeout=3)
    event.settimeout(3)
    event.sendall(packet(INIT_EVT_REQ, struct.pack("<I", connection_number)))
    kind, _payload = read_packet(event)
    if kind != INIT_EVT_ACK:
        raise AssertionError(f"bad InitEvtAck: type={kind}")
    return event


def command(
    sock: socket.socket,
    transaction_id: int,
    operation: int,
    *params: int,
) -> tuple[int, bytes]:
    payload = struct.pack("<IHI", 1, operation, transaction_id)
    payload += b"".join(struct.pack("<I", value & 0xFFFFFFFF) for value in params)
    sock.sendall(packet(CMD_REQUEST, payload))

    data = bytearray()
    while True:
        kind, response = read_packet(sock)
        if kind == START_DATA_PACKET:
            continue
        if kind == END_DATA_PACKET:
            if len(response) >= 4:
                data.extend(response[4:])
            continue
        if kind == CMD_RESPONSE:
            code = struct.unpack_from("<H", response, 0)[0]
            return code, bytes(data)


def verify(host: str, port: int) -> None:
    command_socket = socket.create_connection((host, port), timeout=3)
    command_socket.settimeout(3)
    event_socket: Optional[socket.socket] = None
    try:
        connection_number = init_command(command_socket)
        event_socket = init_event(host, port, connection_number)

        code, _ = command(command_socket, 1, OPEN_SESSION, connection_number)
        assert code == RESPONSE_OK, f"OpenSession failed: 0x{code:04X}"

        code, storage_data = command(command_socket, 2, GET_STORAGE_IDS)
        assert code == RESPONSE_OK and len(storage_data) >= 8
        storage_count, storage_id = struct.unpack_from("<II", storage_data, 0)
        assert storage_count == 1 and storage_id & 0xFFFF

        code, handle_data = command(
            command_socket, 3, GET_OBJECT_HANDLES, storage_id, 0xFFFFFFFF, 0
        )
        assert code == RESPONSE_OK and len(handle_data) >= 8
        handle_count = struct.unpack_from("<I", handle_data, 0)[0]
        handles = list(struct.unpack_from(f"<{handle_count}I", handle_data, 4))
        assert handle_count >= 3

        code, info = command(command_socket, 4, GET_OBJECT_INFO, handles[0])
        assert code == RESPONSE_OK and len(info) >= 53
        name_chars = info[52]
        name = info[53 : 53 + name_chars * 2].decode("utf-16le").rstrip("\0")
        assert name.endswith(".PNG"), name

        code, thumb = command(command_socket, 5, GET_THUMB, handles[0])
        assert code == RESPONSE_OK and thumb.startswith(b"\x89PNG\r\n\x1a\n")

        code, full_image = command(command_socket, 6, GET_OBJECT, handles[0])
        assert code == RESPONSE_OK and full_image == thumb

        code, events = command(command_socket, 7, NK_GET_EVENT)
        assert code == RESPONSE_OK and events == b""

        code, _ = command(command_socket, 8, CLOSE_SESSION)
        assert code == RESPONSE_OK
        print(
            "OK: dual-channel handshake, OpenSession, storage, "
            f"{handle_count} objects, ObjectInfo, thumbnail, download and event poll "
            f"verified ({name})"
        )
    finally:
        command_socket.close()
        if event_socket is not None:
            event_socket.close()


def unused_local_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify the camera simulator protocol")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=15740)
    parser.add_argument(
        "--spawn",
        action="store_true",
        help="start a temporary local simulator, verify it, then stop it",
    )
    args = parser.parse_args()

    process: Optional[subprocess.Popen[bytes]] = None
    if args.spawn:
        args.host = "127.0.0.1"
        args.port = unused_local_port()
        simulator = pathlib.Path(__file__).with_name("simulator.py")
        process = subprocess.Popen(
            [
                sys.executable,
                str(simulator),
                "--bind",
                args.host,
                "--port",
                str(args.port),
                "--quiet",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                with socket.create_connection((args.host, args.port), timeout=0.2):
                    break
            except OSError:
                if process.poll() is not None:
                    error = process.stderr.read().decode(errors="replace") if process.stderr else ""
                    raise RuntimeError(f"simulator exited early: {error}")
                time.sleep(0.05)
        else:
            process.terminate()
            raise TimeoutError("simulator did not start within 5 seconds")

    try:
        verify(args.host, args.port)
    finally:
        if process is not None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
