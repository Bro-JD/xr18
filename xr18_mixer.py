import socket
import struct
import binascii
import time

LISTEN_IP = "0.0.0.0"
PORT = 10024


def decode_osc_string(data, start=0):
    """Decode OSC null-padded string"""
    end = data.find(b'\x00', start)
    if end == -1:
        return None, start
    s = data[start:end].decode("utf-8", errors="ignore")
    next_pos = (end + 4) & ~0x03
    return s, next_pos


def build_osc_string(s):
    b = s.encode("utf-8") + b"\x00"
    while len(b) % 4 != 0:
        b += b"\x00"
    return b


def build_info_reply():
    payload = (
        build_osc_string("/info") +
        build_osc_string(",ssss") +
        build_osc_string("XR18") +
        build_osc_string("Fake XR18") +
        build_osc_string("FW 1.0") +
        build_osc_string("DEBUG")
    )
    return payload


sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind((LISTEN_IP, PORT))

print(f"Fake XR18 listening on UDP {PORT}\n")

last_xremote = {}

while True:
    data, addr = sock.recvfrom(4096)
    ip, src_port = addr

    print(f"\n--- Packet from {ip}:{src_port} ---")
    print(f"Raw ({len(data)} bytes): {binascii.hexlify(data)}")

    # ===== Decode OSC address =====
    address, pos = decode_osc_string(data)
    if not address:
        print("Invalid OSC packet")
        continue

    print(f"OSC Address: {address}")

    # ===== Decode OSC type tags =====
    types, pos = decode_osc_string(data, pos)
    if not types or not types.startswith(","):
        print("⚠ No OSC arguments")
        types = ","

    print(f"OSC Types: {types}")

    # ===== Decode arguments =====
    for t in types[1:]:  # skip comma
        if t == "f":
            value = struct.unpack(">f", data[pos:pos + 4])[0]
            pos += 4
            print(f"  float = {value}")

        elif t == "i":
            value = struct.unpack(">i", data[pos:pos + 4])[0]
            pos += 4
            print(f"  int = {value}")

        elif t == "s":
            value, pos = decode_osc_string(data, pos)
            print(f"  string = {value}")

        else:
            print(f"  unsupported OSC type: {t}")

    # ===== XR18 command handling =====
    if address == "/xremote":
        last_xremote[ip] = time.time()
        print("✔ /xremote received (keep-alive)")

    elif address == "/info":
        print("✔ /info received")
        reply = build_info_reply()
        sock.sendto(reply, addr)
        print("↩ sent /info reply")

    else:
        print("✔ Other OSC command received")

    # ===== XR18-like timeout =====
    for client, t in list(last_xremote.items()):
        if time.time() - t > 10:
            print(f"⚠ XR18 timeout: {client}")
            del last_xremote[client]
