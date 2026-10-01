"""UDP replay: DIFI packets sent as datagrams, paced by their own timestamps.

Feeds a receiver as the board will: one packet per datagram, at the stream's rate.
Also holds gr_difi_payload(), the one deliberate departure from DIFI in this package,
which compensates for a gr-difi bug on the way into gr-difi and nowhere else.
"""
import socket
import time
from array import array
from dataclasses import dataclass
from typing import Callable, Iterable, Optional

from . import fields
from .fields import PS_PER_S

LATE_S = 0.001      # a packet sent later than this after its due time counts as late


def gr_difi_payload(data: bytes) -> bytes:
    """A data packet with its 16-bit samples little-endian, for gr-difi; others unchanged.

    gr-difi at the pinned commit parses headers and context fields in network byte
    order but copies samples in its host's order (gr-difi issue #19, open), so on a
    little-endian host (x86-64, AArch64) it reads DIFI's big-endian samples
    byte-swapped. Swapping them here, before they reach it, makes it output the
    samples the model generated. The prologue and context packets are already right.

    The result is not DIFI: never write it to a capture or check it with the oracle.
    """
    if data[0] >> 4 != fields.PKT_TYPE_DATA:
        return data
    start = 4 * fields.PROLOGUE_WORDS
    payload = array("H", data[start:])
    payload.byteswap()      # the same swap whatever this host's order: gr-difi's host is little-endian
    return data[:start] + payload.tobytes()


@dataclass
class ReplayStats:
    packets: int = 0
    late: int = 0               # packets sent more than LATE_S after their due time
    max_late_s: float = 0.0


def parse_dest(text: str) -> tuple[str, int]:
    """'HOST:PORT' as (host, port)."""
    host, sep, port = text.rpartition(":")
    if not sep or not host or not port.isdigit() or not 0 < int(port) < 65536:
        raise ValueError(f"{text!r} is not HOST:PORT")
    return host, int(port)


def resolve(dest: tuple[str, int]) -> tuple[str, int]:
    """(IPv4 address, port) for (host, port); raises OSError if the host has none.

    Resolved once, so that sending a packet never waits for a name lookup.
    """
    return socket.getaddrinfo(*dest, socket.AF_INET, socket.SOCK_DGRAM)[0][4]


def replay(packets: Iterable[tuple[bytes, int, int]], dest: tuple[str, int], *,
           transform: Optional[Callable[[bytes], bytes]] = None, speed: Optional[float] = 1.0,
           clock: Callable[[], float] = time.monotonic,
           sleep: Callable[[float], None] = time.sleep) -> ReplayStats:
    """Send (payload, seconds, picoseconds) tuples to dest, one UDP datagram each.

    The first packet goes out at once and each later one when its timestamp's distance
    from the first has passed on the monotonic clock, divided by speed; speed None
    sends as fast as possible. transform, if given, rewrites each payload just before
    it is sent. difi_ref.packetizer.Packet is such a tuple.
    """
    if speed is not None and speed <= 0:
        raise ValueError(f"speed {speed} must be positive")
    stats = ReplayStats()
    dest = resolve(dest)
    first_ps = start = None
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        for payload, sec, ps in packets:
            t_ps = sec * PS_PER_S + ps
            if first_ps is None:
                first_ps, start = t_ps, clock()
            if speed is not None:
                # Integer picoseconds until here: only the offset from the first packet,
                # small enough for a double, is converted to seconds.
                due = start + (t_ps - first_ps) / PS_PER_S / speed
                wait = due - clock()
                if wait > 0:
                    sleep(wait)
                late = clock() - due
                if late > LATE_S:
                    stats.late += 1
                stats.max_late_s = max(stats.max_late_s, late)
            sock.sendto(transform(payload) if transform else payload, dest)
            stats.packets += 1
    return stats
