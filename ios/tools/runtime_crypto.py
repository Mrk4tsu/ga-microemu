#!/usr/bin/env python3
"""ChaCha20 (RFC 8439) encryption for bundled Java runtime archives."""
import os
import struct

MAGIC = b"GEMU01\x01\x00"
HEADER_LEN = 20

# Masked 256-bit key shares matching miniz_wrapper.c (key[i] = SHARE_A[i] ^ SHARE_B[i]).
_SHARE_A = bytes([
    0x73, 0x19, 0xA4, 0x5C, 0xE2, 0x0B, 0x67, 0x91,
    0x3D, 0x88, 0x4F, 0xC6, 0x12, 0xEA, 0x55, 0x70,
    0xB9, 0x24, 0x6E, 0xD3, 0x08, 0x9F, 0x41, 0xAC,
    0x57, 0xE0, 0x33, 0x8A, 0x1D, 0x64, 0xC9, 0x2F,
])
_SHARE_B = bytes([
    0xC4, 0xA2, 0x31, 0x8F, 0x59, 0x7E, 0xD0, 0x26,
    0x95, 0x41, 0xFA, 0x13, 0xA7, 0x3C, 0x8E, 0x19,
    0x0E, 0x77, 0xB5, 0x42, 0x6D, 0x28, 0xF4, 0x19,
    0x92, 0x5B, 0x86, 0x3F, 0xA4, 0xD1, 0x78, 0xE3,
])
_KEY = bytes(a ^ b for a, b in zip(_SHARE_A, _SHARE_B))


def _rotl32(v, n):
    return ((v << n) & 0xFFFFFFFF) | (v >> (32 - n))


def _quarter(s, a, b, c, d):
    s[a] = (s[a] + s[b]) & 0xFFFFFFFF
    s[d] = _rotl32(s[d] ^ s[a], 16)
    s[c] = (s[c] + s[d]) & 0xFFFFFFFF
    s[b] = _rotl32(s[b] ^ s[c], 12)
    s[a] = (s[a] + s[b]) & 0xFFFFFFFF
    s[d] = _rotl32(s[d] ^ s[a], 8)
    s[c] = (s[c] + s[d]) & 0xFFFFFFFF
    s[b] = _rotl32(s[b] ^ s[c], 7)


def _chacha20_block(key, counter, nonce):
    state = [
        0x61707865, 0x3320646E, 0x79622D32, 0x6B206574,
        *struct.unpack("<8I", key),
        counter & 0xFFFFFFFF,
        *struct.unpack("<3I", nonce),
    ]
    working = list(state)
    for _ in range(10):
        _quarter(working, 0, 4, 8, 12)
        _quarter(working, 1, 5, 9, 13)
        _quarter(working, 2, 6, 10, 14)
        _quarter(working, 3, 7, 11, 15)
        _quarter(working, 0, 5, 10, 15)
        _quarter(working, 1, 6, 11, 12)
        _quarter(working, 2, 7, 8, 13)
        _quarter(working, 3, 4, 9, 14)
    return struct.pack("<16I", *((w + s) & 0xFFFFFFFF for w, s in zip(working, state)))


def chacha20_xor(data, nonce, counter=1):
    out = bytearray(len(data))
    offset = 0
    block_counter = counter
    while offset < len(data):
        stream = _chacha20_block(_KEY, block_counter, nonce)
        chunk = min(64, len(data) - offset)
        for i in range(chunk):
            out[offset + i] = data[offset + i] ^ stream[i]
        offset += chunk
        block_counter += 1
    return bytes(out)


def encrypt_blob(plaintext, nonce=None):
    if plaintext.startswith(MAGIC):
        return plaintext
    if nonce is None:
        nonce = os.urandom(12)
    if len(nonce) != 12:
        raise ValueError("ChaCha20 nonce must be 12 bytes")
    return MAGIC + nonce + chacha20_xor(plaintext, nonce, counter=1)


def decrypt_blob(blob):
    if not blob.startswith(MAGIC) or len(blob) < HEADER_LEN:
        raise ValueError("Invalid encrypted runtime archive header")
    nonce = blob[len(MAGIC):HEADER_LEN]
    return chacha20_xor(blob[HEADER_LEN:], nonce, counter=1)
