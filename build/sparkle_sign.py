#!/usr/bin/env python3
"""Ed25519 signing + Sparkle appcast generation for LumaControl.

Self-contained on purpose: no third-party Python packages are needed, so this
runs unchanged on a stock GitHub Actions macOS runner.

Ed25519 follows RFC 8032. Sparkle 2's `SUPublicEDKey` is base64 of the raw
32-byte public key, and each enclosure's `sparkle:edSignature` is base64 of the
64-byte detached signature over the update archive.

Usage:
  sparkle_sign.py genkeys
  sparkle_sign.py sign <private-key-base64> <file>
  sparkle_sign.py appcast --dmg <path> --url <download-url> \
      --version <build> --short-version <marketing> \
      --notes <xml-file> [--key <private-key-base64>] [--out <appcast.xml>]
"""

import base64
import hashlib
import os
import sys

# ---------------------------------------------------------------- Ed25519

Q = 2**255 - 19
L = 2**252 + 27742317777372353535851937790883648493
D = -121665 * pow(121666, Q - 2, Q) % Q
I = pow(2, (Q - 1) // 4, Q)


def _inv(a):
    return pow(a, Q - 2, Q) if a else 0


def _add(p, r):
    x1, y1 = p
    x2, y2 = r
    k = D * x1 * x2 * y1 * y2 % Q
    x3 = (x1 * y2 + x2 * y1) * _inv(1 + k) % Q
    y3 = (y1 * y2 + x1 * x2) * _inv(1 - k) % Q
    return (x3, y3)


def _mul(p, e):
    """Iterative double-and-add (avoids recursion limits on 255-bit scalars)."""
    if e == 0:
        return (0, 1)
    acc = (0, 1)
    for bit in bin(e)[2:]:
        acc = _add(acc, acc)
        if bit == "1":
            acc = _add(acc, p)
    return acc


def _encode_point(p):
    x, y = p
    out = bytearray(y.to_bytes(32, "little"))
    if x & 1:
        out[31] |= 0x80
    return bytes(out)


# Curve25519 base point: y = 4/5, x the positive square root.
_BY = 4 * _inv(5) % Q
_BX = pow((_BY * _BY - 1) * _inv((D * _BY * _BY + 1) % Q) % Q, (Q + 3) // 8, Q)
if (_BX * _BX - (_BY * _BY - 1) * _inv((D * _BY * _BY + 1) % Q) % Q) % Q != 0:
    _BX = _BX * I % Q
if _BX % 2:
    _BX = Q - _BX
B = (_BX, _BY)


def _scalar(seed):
    h = hashlib.sha512(seed).digest()
    a = bytearray(h[:32])
    a[0] &= 248
    a[31] &= 127
    a[31] |= 64
    return int.from_bytes(bytes(a), "little"), h[32:]


def public_key(seed):
    a, _ = _scalar(seed)
    return _encode_point(_mul(B, a))


def sign(seed, message):
    a, prefix = _scalar(seed)
    pub = _encode_point(_mul(B, a))
    r = int.from_bytes(hashlib.sha512(prefix + message).digest(), "little") % L
    enc_r = _encode_point(_mul(B, r))
    k = int.from_bytes(hashlib.sha512(enc_r + pub + message).digest(), "little") % L
    s = (r + k * a) % L
    return enc_r + s.to_bytes(32, "little")


# ---------------------------------------------------------------- appcast

APPCAST_TEMPLATE = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>LumaControl</title>
    <link>https://github.com/shay2000/LumaControl</link>
    <description>Most recent release of LumaControl</description>
    <language>en</language>
{items}  </channel>
</rss>
"""

ITEM_TEMPLATE = """    <item>
      <title>Version {short_version}</title>
      <pubDate>{pub_date}</pubDate>
      <sparkle:version>{version}</sparkle:version>
      <sparkle:shortVersionString>{short_version}</sparkle:shortVersionString>
      <enclosure url="{url}" length="{length}" type="application/x-apple-diskimage"{sig_attr}/>
    </item>
"""


def _esc(value):
    return (
        str(value)
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def build_item(url, length, version, short_version, pub_date, signature=None):
    if signature:
        sig_attr = f'\n              sparkle:edSignature="{_esc(signature)}"'
    else:
        sig_attr = ""
    return ITEM_TEMPLATE.format(
        url=_esc(url),
        length=_esc(length),
        version=_esc(version),
        short_version=_esc(short_version),
        pub_date=_esc(pub_date),
        sig_attr=sig_attr,
    )


# ---------------------------------------------------------------- CLI


def cmd_genkeys(_args):
    seed = os.urandom(32)
    print("SUPublicEDKey (put this in Info.plist):")
    print(base64.b64encode(public_key(seed)).decode())
    print()
    print("SPARKLE_PRIVATE_KEY (GitHub Actions secret - never commit this):")
    print(base64.b64encode(seed).decode())


def cmd_sign(args):
    seed = base64.b64decode(args.key)
    with open(args.file, "rb") as handle:
        print(base64.b64encode(sign(seed, handle.read())).decode())


def cmd_appcast(args):
    length = os.path.getsize(args.dmg)
    signature = None
    if args.key:
        with open(args.dmg, "rb") as handle:
            signature = base64.b64encode(sign(base64.b64decode(args.key), handle.read())).decode()
    item = build_item(args.url, length, args.version, args.short_version, args.pub_date, signature)
    with open(args.out, "w") as handle:
        handle.write(APPCAST_TEMPLATE.format(items=item))
    print(f"wrote {args.out} (version {args.short_version} / build {args.version})")


def _selftest():
    """RFC 8032 section 7.1 test vector 1."""
    seed = bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
    pub = bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
    sig = bytes.fromhex(
        "e5564300c360ac729086e2cc806e828a"
        "84877f1eb8e5d974d873e06522490155"
        "5fb8821590a33bacc61e39701cf9b46b"
        "d25bf5f0595bbe24655141438e7a100b"
    )
    ok = public_key(seed) == pub and sign(seed, b"") == sig
    print("RFC 8032 self-test:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def main():
    import argparse

    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("genkeys", help="print a fresh Ed25519 keypair").set_defaults(func=cmd_genkeys)
    sub.add_parser("selftest", help="verify the Ed25519 code against RFC 8032").set_defaults(func=lambda _a: _selftest())

    p_sign = sub.add_parser("sign")
    p_sign.add_argument("key")
    p_sign.add_argument("file")
    p_sign.set_defaults(func=cmd_sign)

    p_app = sub.add_parser("appcast")
    p_app.add_argument("--dmg", required=True)
    p_app.add_argument("--url", required=True)
    p_app.add_argument("--version", required=True)
    p_app.add_argument("--short-version", required=True)
    p_app.add_argument("--pub-date", default="")
    p_app.add_argument("--key")
    p_app.add_argument("--out", default="appcast.xml")
    p_app.set_defaults(func=cmd_appcast)

    args = parser.parse_args()
    args.func(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
