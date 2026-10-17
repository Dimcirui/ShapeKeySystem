"""iFacialMocap -> ShapeKeySystem bridge (the 面捕 page).

Receives iFacialMocap UDP packets and writes the latest frame to
reframework/data/ShapeKeySystem/mocap/live.json, which ShapeKeySystem reads every frame
(REFramework Lua has no sockets). Exclude that folder from Windows Defender real-time scanning:
with scanning on, each read in the game costs ~5 ms.

    python ifm_bridge.py <iPhone IP>        # sends the start trigger to the phone
    python ifm_bridge.py                    # listen only (phone already streaming to this PC)

Once packets arrive, the trigger follows the address they come from, so the stream restarts on
its own after the phone stops sending (app in the background, screen locked, Wi-Fi drop).

Standard library only.
"""

import json
import os
import socket
import sys
import time

PORT = 49983
TRIGGER = b"iFacialMocap_sahuasouryya9218sauhuiayeta91555dy3719"
# builtin/ is replaced on every update: the output goes to data/ShapeKeySystem/mocap
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "mocap")
OUT = os.path.normpath(os.path.join(OUT_DIR, "live.json"))
TMP = OUT + ".tmp"

ARKIT52 = [
    "browDownLeft", "browDownRight", "browInnerUp", "browOuterUpLeft", "browOuterUpRight",
    "cheekPuff", "cheekSquintLeft", "cheekSquintRight",
    "eyeBlinkLeft", "eyeBlinkRight", "eyeLookDownLeft", "eyeLookDownRight", "eyeLookInLeft", "eyeLookInRight",
    "eyeLookOutLeft", "eyeLookOutRight", "eyeLookUpLeft", "eyeLookUpRight", "eyeSquintLeft", "eyeSquintRight",
    "eyeWideLeft", "eyeWideRight",
    "jawForward", "jawLeft", "jawOpen", "jawRight",
    "mouthClose", "mouthDimpleLeft", "mouthDimpleRight", "mouthFrownLeft", "mouthFrownRight", "mouthFunnel",
    "mouthLeft", "mouthLowerDownLeft", "mouthLowerDownRight", "mouthPressLeft", "mouthPressRight", "mouthPucker",
    "mouthRight", "mouthRollLower", "mouthRollUpper", "mouthShrugLower", "mouthShrugUpper", "mouthSmileLeft",
    "mouthSmileRight", "mouthStretchLeft", "mouthStretchRight", "mouthUpperUpLeft", "mouthUpperUpRight",
    "noseSneerLeft", "noseSneerRight",
    "tongueOut",
]
INDEX = {n: i for i, n in enumerate(ARKIT52)}


def canonical(name):
    # iFacialMocap: "eyeBlink_L" -> ARKit "eyeBlinkLeft"
    if name.endswith("_L"):
        return name[:-2] + "Left"
    if name.endswith("_R"):
        return name[:-2] + "Right"
    return name


def parse(text, w):
    """Fill w (52 floats, 0..1) in place. Returns (head[6] or None, leftEye[3], rightEye[3], hits)."""
    head = le = re_ = None
    hits = 0
    for field in text.split("|"):
        if not field:
            continue
        if "#" in field:
            key, _, vals = field.partition("#")
            try:
                nums = [float(x) for x in vals.split(",")]
            except ValueError:
                continue
            key = key.lstrip("=")
            if key == "head" and len(nums) == 6:
                head = nums
            elif key == "leftEye" and len(nums) == 3:
                le = nums
            elif key == "rightEye" and len(nums) == 3:
                re_ = nums
            continue
        # blendshape: "name-12" (classic) or "name&12" (newer app versions)
        sep = max(field.rfind("&"), field.rfind("-"))
        if sep <= 0:
            continue
        i = INDEX.get(canonical(field[:sep]))
        if i is None:
            continue
        try:
            v = float(field[sep + 1:]) / 100.0
        except ValueError:
            continue
        w[i] = min(max(v, 0.0), 1.0)
        hits += 1
    return head, le, re_, hits


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
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    phone = sys.argv[1] if len(sys.argv) > 1 else None
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", PORT))
    sock.settimeout(0.5)
    print(f"listening on UDP {PORT}, writing {OUT}")
    if phone:
        print(f"trigger -> {phone}:{PORT}")

    w = [0.0] * len(ARKIT52)
    seq = 0
    writes = fails = 0
    last_rx = 0.0
    last_trigger = 0.0
    rx_count, rx_window = 0, time.time()
    pending = None

    while True:
        now = time.time()
        if phone and now - last_rx > 2.0 and now - last_trigger > 2.0:
            try:
                sock.sendto(TRIGGER, (phone, PORT))
            except OSError as e:
                print("trigger failed:", e)
            last_trigger = now
        try:
            pkt, addr = sock.recvfrom(8192)
        except socket.timeout:
            pkt = None
        except ConnectionResetError:
            pkt = None   # Windows reports ICMP port-unreachable for the trigger as a recv error
        now = time.time()
        if pkt:
            head, le, re_, hits = parse(pkt.decode("utf-8", "replace"), w)
            if hits:
                if last_rx == 0.0 or now - last_rx > 2.0:
                    print(f"receiving from {addr[0]} ({hits} shapes per packet)")
                if phone != addr[0]:
                    if phone:
                        print(f"the phone is {addr[0]}, not {phone}: triggering {addr[0]} from now on")
                    phone = addr[0]
                last_rx = now
                seq += 1
                rx_count += 1
                pending = {"seq": seq, "w": [round(x, 4) for x in w],
                           "head": head, "le": le, "re": re_}
        # one write per packet: throttling here used to hold a packet back until the next one
        if pending:
            if write(json.dumps(pending, separators=(",", ":"))):
                writes += 1
            else:
                fails += 1
            pending = None
        if now - rx_window >= 5.0:
            hz = rx_count / (now - rx_window)
            idle = f"no data, re-triggering {phone} every 2 s (keep iFacialMocap open)" if phone else "no data"
            state = f"{hz:5.1f} packets/s, {writes / (now - rx_window):5.1f} writes/s, {fails} busy" if rx_count else idle
            print(f"[{time.strftime('%H:%M:%S')}] {state}")
            rx_count, rx_window, writes, fails = 0, now, 0, 0


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
