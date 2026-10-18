"""RhyLive -> ShapeKeySystem bridge (the 面捕 page, scheme RhyLive).

RhyLive pushes OSC over UDP to the PC: in the app, set the target to this PC's LAN IP and the
port below. No trigger is needed. Each "/Face" message carries 52 float32 values in ARKit52 order
(the same order as Names.ARKIT52); RhyLive sends no head rotation, so "head" stays null.

The latest frame goes to reframework/data/ShapeKeySystem/mocap/live.json, the same file
ifm_bridge.py writes; ShapeKeySystem reads it every frame (REFramework Lua has no sockets).
Exclude that folder from Windows Defender real-time scanning: with scanning on, each read in the
game costs ~5 ms.

    python rhylive_bridge.py            # listen on UDP 9000
    python rhylive_bridge.py 9001       # another port

Standard library only.
"""

import json
import math
import os
import socket
import struct
import sys
import time

PORT = 9000
FACE_ADDRESS = "/Face"
CHANNELS = 52
FACE_TAGS = "," + "f" * CHANNELS
MAX_DEPTH = 8   # bundles nest; deeper input is treated as malformed
# builtin/ is replaced on every update: the output goes to data/ShapeKeySystem/mocap
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "mocap")
OUT = os.path.normpath(os.path.join(OUT_DIR, "live.json"))
TMP = OUT + ".tmp"


class Malformed(ValueError):
    pass


def osc_string(buf, pos, end):
    """OSC string at pos: NUL-terminated, padded to 4 bytes. Returns (text, next pos)."""
    stop = buf.find(b"\0", pos, end)
    if stop < 0:
        raise Malformed("unterminated string")
    nxt = (stop + 4) & ~3
    if nxt > end:
        raise Malformed("string padding past the end")
    try:
        return buf[pos:stop].decode("ascii"), nxt
    except UnicodeDecodeError:
        raise Malformed("non-ASCII string")


def face_message(buf, pos, end):
    """A message at buf[pos:end]. Returns 52 clamped floats for a valid /Face message, else None.

    Other addresses are ignored. A /Face message with the wrong type tags, the wrong length or a
    non-finite value is dropped, not partly applied.
    """
    address, pos = osc_string(buf, pos, end)
    if address != FACE_ADDRESS:
        return None
    if pos >= end:
        return None   # OSC 1.0 allows a message without type tags; /Face always has them
    tags, pos = osc_string(buf, pos, end)
    if tags != FACE_TAGS or end - pos != 4 * CHANNELS:
        return None
    vals = struct.unpack_from(">%df" % CHANNELS, buf, pos)
    if not all(math.isfinite(v) for v in vals):
        return None
    return [min(max(v, 0.0), 1.0) for v in vals]


def walk(buf, pos, end, frames, depth):
    if depth > MAX_DEPTH:
        raise Malformed("bundles nested too deep")
    if end - pos >= 8 and buf[pos:pos + 8] == b"#bundle\0":
        pos += 16   # "#bundle\0" + 8-byte time tag (frames are applied as they arrive)
        if pos > end:
            raise Malformed("truncated bundle header")
        while pos < end:
            if end - pos < 4:
                raise Malformed("truncated element size")
            (size,) = struct.unpack_from(">i", buf, pos)
            pos += 4
            if size <= 0 or size % 4 or pos + size > end:
                raise Malformed("bad element size")
            walk(buf, pos, pos + size, frames, depth + 1)
            pos += size
        return
    if pos >= end or buf[pos:pos + 1] != b"/":
        raise Malformed("not an OSC message or bundle")
    w = face_message(buf, pos, end)
    if w is not None:
        frames.append(w)


def parse(pkt):
    """All valid /Face frames in one UDP packet, in order; [] for a malformed packet."""
    frames = []
    if len(pkt) % 4:
        return frames
    try:
        walk(pkt, 0, len(pkt), frames, 0)
    except (Malformed, struct.error):
        return []
    return frames


def lan_ipv4():
    """This PC's IPv4 addresses the phone may reach (loopback and link-local left out)."""
    found = []
    try:
        # connecting a UDP socket sends nothing; it only picks the outgoing interface
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("192.0.2.1", 9))
            found.append(s.getsockname()[0])
    except OSError:
        pass
    try:
        for ip in socket.gethostbyname_ex(socket.gethostname())[2]:
            if ip not in found:
                found.append(ip)
    except OSError:
        pass
    return [ip for ip in found if not ip.startswith(("127.", "169.254."))]


def write(data):
    # write a temp file and swap it in, so the game never reads a half-written frame
    try:
        with open(TMP, "w", encoding="ascii") as f:
            f.write(data)
        os.replace(TMP, OUT)
        return True
    except OSError:
        return False   # the game had live.json open this instant; the next packet retries


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else PORT
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.bind(("0.0.0.0", port))
    except OSError as e:
        print(f"cannot listen on UDP {port}: {e} (another program uses the port? pass another port)")
        return
    sock.settimeout(0.5)
    ips = lan_ipv4()
    print(f"listening on UDP {port}, writing {OUT}")
    print("in RhyLive, send to " + (", ".join(f"{ip}:{port}" for ip in ips) if ips else f"this PC's LAN IP, port {port}"))

    seq = 0
    writes = fails = bad = 0
    last_rx = 0.0
    rx_count, rx_window = 0, time.time()

    while True:
        try:
            pkt, addr = sock.recvfrom(65535)
        except socket.timeout:
            pkt = None
        except ConnectionResetError:
            pkt = None   # Windows reports an earlier ICMP port-unreachable as a recv error
        now = time.time()
        if pkt:
            frames = parse(pkt)
            if frames:
                if last_rx == 0.0 or now - last_rx > 2.0:
                    print(f"receiving from {addr[0]}")
                last_rx = now
                seq += 1
                rx_count += 1
                frame = {"seq": seq, "w": [round(x, 4) for x in frames[-1]], "head": None}
                if write(json.dumps(frame, separators=(",", ":"))):
                    writes += 1
                else:
                    fails += 1
            else:
                bad += 1
        if now - rx_window >= 5.0:
            span = now - rx_window
            if rx_count:
                state = f"{rx_count / span:5.1f} packets/s, {writes / span:5.1f} writes/s, {fails} busy"
            else:
                state = "no data (RhyLive open, sending to this PC's IP and port?)"
            if bad:
                state += f", {bad} packets without a valid /Face"
            print(f"[{time.strftime('%H:%M:%S')}] {state}")
            rx_count, rx_window, writes, fails, bad = 0, now, 0, 0, 0


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
