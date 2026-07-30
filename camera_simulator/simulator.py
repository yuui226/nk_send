#!/usr/bin/env python3
"""Minimal Nikon-like PTP/IP camera used to exercise ZTransfer without hardware."""

from __future__ import annotations

import argparse
import binascii
import datetime as dt
import signal
import socket
import socketserver
import struct
import threading
import zlib
from dataclasses import dataclass
from typing import Optional


PTP_PORT = 15740
STORAGE_ID = 0x00010001
SAMPLE_PHOTO_COUNT = 36
SAMPLE_IMAGE_VARIANTS = 12

INIT_CMD_REQ = 1
INIT_CMD_ACK = 2
INIT_EVT_REQ = 3
INIT_EVT_ACK = 4
CMD_REQUEST = 6
CMD_RESPONSE = 7
START_DATA_PACKET = 9
END_DATA_PACKET = 12
PING = 13
PONG = 14

GET_DEVICE_INFO = 0x1001
OPEN_SESSION = 0x1002
CLOSE_SESSION = 0x1003
GET_STORAGE_IDS = 0x1004
GET_OBJECT_HANDLES = 0x1007
GET_OBJECT_INFO = 0x1008
GET_OBJECT = 0x1009
GET_THUMB = 0x100A
NK_GET_FHD_PICTURE = 0x920F
NK_GET_EVENT = 0x90C7
NK_GET_OBJECT_SIZE = 0x9421
NK_GET_PARTIAL_OBJECT_EX = 0x9431

RESPONSE_OK = 0x2001
OPERATION_NOT_SUPPORTED = 0x2005
INVALID_OBJECT_HANDLE = 0x2009

FORMAT_PNG = 0x3804
CAMERA_GUID = bytes.fromhex("5a5452414e5346455253494d30303031")


def recv_exact(sock: socket.socket, size: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < size:
        block = sock.recv(size - len(chunks))
        if not block:
            raise EOFError("peer closed the connection")
        chunks.extend(block)
    return bytes(chunks)


def read_packet(sock: socket.socket) -> tuple[int, bytes]:
    header = recv_exact(sock, 8)
    length, packet_type = struct.unpack("<II", header)
    if length < 8 or length > 256 * 1024 * 1024:
        raise ValueError(f"invalid PTP/IP packet length: {length}")
    return packet_type, recv_exact(sock, length - 8)


def packet(packet_type: int, payload: bytes = b"") -> bytes:
    return struct.pack("<II", 8 + len(payload), packet_type) + payload


def ptp_string(value: str) -> bytes:
    if not value:
        return b"\x00"
    encoded = (value + "\0").encode("utf-16le")
    char_count = len(encoded) // 2
    if char_count > 255:
        raise ValueError("PTP string is too long")
    return bytes((char_count,)) + encoded


def u16_array(values: list[int]) -> bytes:
    return struct.pack("<I", len(values)) + b"".join(struct.pack("<H", v) for v in values)


def png_chunk(kind: bytes, data: bytes) -> bytes:
    checksum = binascii.crc32(kind + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", checksum)


def make_sample_png(width: int, height: int, seed: int) -> bytes:
    """Create a dependency-free RGB PNG with a distinct photographic-looking pattern."""
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        horizon = height * (35 + seed * 4) // 100
        for x in range(width):
            if y < horizon:
                r = 28 + (x * 75 // width) + seed * 9
                g = 75 + (y * 95 // max(1, horizon)) + seed * 5
                b = 145 + (x * 60 // width)
            else:
                depth = (y - horizon) * 120 // max(1, height - horizon)
                r = 42 + depth + seed * 11
                g = 92 - depth // 3 + (x * 35 // width)
                b = 48 + seed * 7

            # A bright off-centre subject and a few diagonal highlights make each tile obvious.
            cx = width * (22 + seed * 11) // 100
            cy = height * (52 + (seed % 2) * 9) // 100
            radius = min(width, height) * (10 + seed % 3) // 100
            if (x - cx) ** 2 + (y - cy) ** 2 < radius**2:
                r, g, b = 235, 178 + seed * 7, 70 + seed * 13
            if abs((x + seed * 31) - (y * width // max(1, height))) < 3:
                r, g, b = 225, 232, 220

            rows.extend((r & 0xFF, g & 0xFF, b & 0xFF))

    signature = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return signature + png_chunk(b"IHDR", ihdr) + png_chunk(
        b"IDAT", zlib.compress(bytes(rows), level=7)
    ) + png_chunk(b"IEND", b"")


@dataclass(frozen=True)
class SimObject:
    handle: int
    file_name: str
    capture_date: str
    protected: bool
    image: bytes
    width: int
    height: int

    def object_info(self) -> bytes:
        info = bytearray(52)
        struct.pack_into("<I", info, 0, STORAGE_ID)
        struct.pack_into("<H", info, 4, FORMAT_PNG)
        struct.pack_into("<H", info, 6, 1 if self.protected else 0)
        struct.pack_into("<I", info, 8, len(self.image))
        struct.pack_into("<H", info, 12, FORMAT_PNG)
        struct.pack_into("<I", info, 14, len(self.image))
        struct.pack_into("<I", info, 18, self.width)
        struct.pack_into("<I", info, 22, self.height)
        struct.pack_into("<I", info, 26, self.width)
        struct.pack_into("<I", info, 30, self.height)
        struct.pack_into("<I", info, 34, 24)
        struct.pack_into("<I", info, 38, 0)
        struct.pack_into("<H", info, 42, 0)
        struct.pack_into("<I", info, 44, 0)
        struct.pack_into("<I", info, 48, self.handle)
        return (
            bytes(info)
            + ptp_string(self.file_name)
            + ptp_string(self.capture_date)
            + ptp_string(self.capture_date)
            + ptp_string("")
        )


def build_objects(photo_count: int = SAMPLE_PHOTO_COUNT) -> dict[int, SimObject]:
    now = dt.datetime.now().replace(microsecond=0)
    objects: dict[int, SimObject] = {}
    image_variants: dict[tuple[int, int, int], bytes] = {}
    for index in range(photo_count):
        variant = index % SAMPLE_IMAGE_VARIANTS
        width, height = (320, 480) if variant in (3, 9) else (480, 320)
        image_key = (width, height, variant)
        if image_key not in image_variants:
            image_variants[image_key] = make_sample_png(width, height, variant + 1)
        image = image_variants[image_key]
        captured = now - dt.timedelta(hours=index * 5)
        handle = 0x1001 + index
        objects[handle] = SimObject(
            handle=handle,
            file_name=f"ZSIM_{index + 1:04d}.PNG",
            capture_date=captured.strftime("%Y%m%dT%H%M%S"),
            protected=index % 11 == 1,
            image=image,
            width=width,
            height=height,
        )
    return objects


def device_info() -> bytes:
    operations = [
        GET_DEVICE_INFO,
        OPEN_SESSION,
        CLOSE_SESSION,
        GET_STORAGE_IDS,
        GET_OBJECT_HANDLES,
        GET_OBJECT_INFO,
        GET_OBJECT,
        GET_THUMB,
    ]
    return b"".join(
        [
            struct.pack("<HIH", 100, 0x0000000A, 100),
            ptp_string("ZTransfer Camera Simulator"),
            struct.pack("<H", 0),
            u16_array(operations),
            u16_array([]),
            u16_array([]),
            u16_array([]),
            u16_array([FORMAT_PNG]),
            ptp_string("Nikon Simulator"),
            ptp_string("Z SIM"),
            ptp_string("1.0"),
            ptp_string("ZSIM0001"),
        ]
    )


class CameraState:
    def __init__(self, verbose: bool = True) -> None:
        self.objects = build_objects()
        self.verbose = verbose
        self._connection_number = 0
        self._lock = threading.Lock()

    def next_connection_number(self) -> int:
        with self._lock:
            self._connection_number += 1
            return self._connection_number

    def log(self, message: str) -> None:
        if self.verbose:
            print(message, flush=True)


class PtpIpHandler(socketserver.BaseRequestHandler):
    server: "PtpIpServer"

    def handle(self) -> None:
        sock: socket.socket = self.request
        sock.settimeout(70)
        try:
            packet_type, payload = read_packet(sock)
            if packet_type == INIT_CMD_REQ:
                self.handle_command_channel(sock, payload)
            elif packet_type == INIT_EVT_REQ:
                self.handle_event_channel(sock, payload)
            else:
                self.server.camera.log(
                    f"[reject] {self.client_address[0]} first packet type={packet_type}"
                )
        except (EOFError, ConnectionError, OSError):
            return
        except Exception as error:
            self.server.camera.log(f"[error] {self.client_address[0]}: {error}")

    def handle_command_channel(self, sock: socket.socket, _payload: bytes) -> None:
        connection_number = self.server.camera.next_connection_number()
        friendly_name = "Z SIM".encode("utf-16le") + b"\0\0"
        ack = struct.pack("<I", connection_number) + CAMERA_GUID + friendly_name
        sock.sendall(packet(INIT_CMD_ACK, ack))
        self.server.camera.log(
            f"[connect] command channel {self.client_address[0]} id={connection_number}"
        )

        while True:
            packet_type, payload = read_packet(sock)
            if packet_type == PING:
                sock.sendall(packet(PONG))
                continue
            if packet_type != CMD_REQUEST or len(payload) < 10:
                continue

            _data_phase = struct.unpack_from("<I", payload, 0)[0]
            operation = struct.unpack_from("<H", payload, 4)[0]
            transaction_id = struct.unpack_from("<I", payload, 6)[0]
            params = [
                struct.unpack_from("<I", payload, offset)[0]
                for offset in range(10, len(payload) - 3, 4)
            ]
            should_close = self.dispatch(sock, operation, transaction_id, params)
            if should_close:
                return

    def handle_event_channel(self, sock: socket.socket, payload: bytes) -> None:
        connection_number = struct.unpack_from("<I", payload, 0)[0] if len(payload) >= 4 else 0
        sock.sendall(packet(INIT_EVT_ACK))
        # The real camera keeps this channel open indefinitely even when no events occur.
        sock.settimeout(None)
        self.server.camera.log(
            f"[connect] event channel {self.client_address[0]} id={connection_number}"
        )
        while True:
            packet_type, _payload = read_packet(sock)
            if packet_type == PING:
                sock.sendall(packet(PONG))

    def send_response(
        self,
        sock: socket.socket,
        transaction_id: int,
        response_code: int = RESPONSE_OK,
    ) -> None:
        payload = struct.pack("<HI", response_code, transaction_id)
        sock.sendall(packet(CMD_RESPONSE, payload))

    def send_data(
        self,
        sock: socket.socket,
        transaction_id: int,
        data: bytes,
        response_code: int = RESPONSE_OK,
    ) -> None:
        sock.sendall(packet(START_DATA_PACKET, struct.pack("<IQ", transaction_id, len(data))))
        sock.sendall(packet(END_DATA_PACKET, struct.pack("<I", transaction_id) + data))
        self.send_response(sock, transaction_id, response_code)

    def dispatch(
        self,
        sock: socket.socket,
        operation: int,
        transaction_id: int,
        params: list[int],
    ) -> bool:
        camera = self.server.camera
        camera.log(
            f"[command] op=0x{operation:04X} tid={transaction_id} "
            f"params={[hex(value) for value in params]}"
        )

        if operation == OPEN_SESSION:
            self.send_response(sock, transaction_id)
            return False
        if operation == CLOSE_SESSION:
            self.send_response(sock, transaction_id)
            return True
        if operation == GET_DEVICE_INFO:
            self.send_data(sock, transaction_id, device_info())
            return False
        if operation == GET_STORAGE_IDS:
            self.send_data(sock, transaction_id, struct.pack("<II", 1, STORAGE_ID))
            return False
        if operation == GET_OBJECT_HANDLES:
            handles = sorted(camera.objects, reverse=True)
            data = struct.pack("<I", len(handles)) + b"".join(
                struct.pack("<I", handle) for handle in handles
            )
            self.send_data(sock, transaction_id, data)
            return False

        handle = params[0] if params else 0
        obj: Optional[SimObject] = camera.objects.get(handle)
        if operation in {
            GET_OBJECT_INFO,
            GET_OBJECT,
            GET_THUMB,
            NK_GET_FHD_PICTURE,
            NK_GET_OBJECT_SIZE,
            NK_GET_PARTIAL_OBJECT_EX,
        } and obj is None:
            self.send_response(sock, transaction_id, INVALID_OBJECT_HANDLE)
            return False

        if operation == GET_OBJECT_INFO and obj is not None:
            self.send_data(sock, transaction_id, obj.object_info())
        elif operation in {GET_OBJECT, GET_THUMB, NK_GET_FHD_PICTURE} and obj is not None:
            self.send_data(sock, transaction_id, obj.image)
        elif operation == NK_GET_OBJECT_SIZE and obj is not None:
            self.send_data(sock, transaction_id, struct.pack("<Q", len(obj.image)))
        elif operation == NK_GET_PARTIAL_OBJECT_EX and obj is not None:
            offset_low = params[1] if len(params) > 1 else 0
            offset_high = params[2] if len(params) > 2 else 0
            size_low = params[3] if len(params) > 3 else len(obj.image)
            size_high = params[4] if len(params) > 4 else 0
            offset = offset_low | (offset_high << 32)
            requested = size_low | (size_high << 32)
            self.send_data(sock, transaction_id, obj.image[offset : offset + requested])
        elif operation == NK_GET_EVENT:
            self.send_data(sock, transaction_id, b"")
        else:
            self.send_response(sock, transaction_id, OPERATION_NOT_SUPPORTED)
        return False


class PtpIpServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, address: tuple[str, int], camera: CameraState) -> None:
        self.camera = camera
        super().__init__(address, PtpIpHandler)


def main() -> int:
    parser = argparse.ArgumentParser(description="ZTransfer Nikon-like PTP/IP camera simulator")
    parser.add_argument("--bind", default="0.0.0.0", help="IPv4 address to listen on")
    parser.add_argument("--port", type=int, default=PTP_PORT, help="TCP port (default: 15740)")
    parser.add_argument("--quiet", action="store_true", help="hide per-command logs")
    args = parser.parse_args()

    camera = CameraState(verbose=not args.quiet)
    server = PtpIpServer((args.bind, args.port), camera)
    stopping = threading.Event()

    def stop_server(_signum: int, _frame: object) -> None:
        if not stopping.is_set():
            stopping.set()
            threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT, stop_server)
    if hasattr(signal, "SIGTERM"):
        signal.signal(signal.SIGTERM, stop_server)

    print(
        f"ZTransfer camera simulator listening on {args.bind}:{args.port} "
        f"with {len(camera.objects)} sample photos",
        flush=True,
    )
    try:
        server.serve_forever(poll_interval=0.25)
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
