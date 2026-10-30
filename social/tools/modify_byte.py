"""Write seed/server_modified.pem: seed/server.pem with one byte changed.

  cert  a letter of the certificate's subject name ("SEEDPKILab2020"). The
        file still parses and the server starts, but the CA's signature no
        longer matches the certificate's content.
  key   a byte of the encrypted private key. The passphrase no longer
        decrypts it, so the server cannot start.
"""
import base64
import re
import sys

mode = sys.argv[1] if len(sys.argv) > 1 else "cert"
if mode not in ("cert", "key"):
    sys.exit("usage: modify_byte.py [cert|key]")

text = open("seed/server.pem").read()
blocks = list(re.finditer(r"-----BEGIN ([A-Z ]+)-----\n(.*?)\n-----END \1-----", text, re.S))
wanted = "CERTIFICATE" if mode == "cert" else "PRIVATE KEY"
block = next(b for b in blocks if b.group(1).endswith(wanted))
der = bytearray(base64.b64decode(block.group(2)))

if mode == "cert":
    offset = der.find(b"SEEDPKILab2020")
    old, new = chr(der[offset]), "Z"
    der[offset] = ord(new)
    print(f"certificate byte {offset}: '{old}' -> '{new}'  (subject now reads ZEEDPKILab2020)")
else:
    offset = len(der) - 20
    old = der[offset]
    der[offset] ^= 0xFF
    print(f"private key byte {offset}: 0x{old:02x} -> 0x{der[offset]:02x}")

body = base64.b64encode(bytes(der)).decode()
lines = "\n".join(body[i:i + 64] for i in range(0, len(body), 64))
pem = f"-----BEGIN {block.group(1)}-----\n{lines}\n-----END {block.group(1)}-----"
open("seed/server_modified.pem", "w").write(text[:block.start()] + pem + text[block.end():])
print("written: seed/server_modified.pem  (seed/server.pem unchanged)")
