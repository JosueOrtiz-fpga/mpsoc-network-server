"""UDP replay: pacing, the gr-difi payload swap, and datagrams on a loopback socket."""
import socket
import struct

import pytest

from difi_ref import fields, replay
from difi_ref.__main__ import main


class FakeClock:
    """A monotonic clock that only moves when sleep() is called."""

    def __init__(self):
        self.now = 100.0

    def __call__(self):
        return self.now

    def sleep(self, s):
        self.now += s


@pytest.fixture
def receiver():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.bind(("127.0.0.1", 0))
        s.settimeout(2)
        yield s


def received(sock, n):
    return [sock.recv(9000) for _ in range(n)]


class FakeSocket:
    """Stands in for the UDP socket: records the clock time of each sendto()."""

    def __init__(self, clock):
        self.clock = clock
        self.times = []

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        pass

    def sendto(self, data, dest):
        self.times.append(self.clock.now)


def sent_at(monkeypatch, packets, **kw):
    """Clock times at which each packet is sent, and the replay's stats."""
    clock = FakeClock()
    sock = FakeSocket(clock)
    monkeypatch.setattr(replay.socket, "socket", lambda *a: sock)
    stats = replay.replay(packets, ("127.0.0.1", 9), clock=clock, sleep=clock.sleep, **kw)
    return sock.times, stats


def test_paced_by_timestamps(example, monkeypatch):
    cfg, _, packets = example
    times, stats = sent_at(monkeypatch, packets[:50])
    period = cfg.samples_per_pkt / cfg.ctx_sample_rate_hz      # 1.875 ms
    for t, p in zip(times, packets):
        stream_s = (p.sec - packets[0].sec) + (p.ps - packets[0].ps) / 10**12
        assert t - times[0] == pytest.approx(stream_s, abs=1e-9)
    # A context packet and the data packet after it share a timestamp, so go out together.
    assert times[1] == times[0] and times[2] - times[1] == pytest.approx(period)
    assert stats.packets == 50 and stats.late == 0


def test_speed_scales_and_none_does_not_wait(example, monkeypatch):
    _, _, packets = example
    normal, _ = sent_at(monkeypatch, packets[:20])
    double, _ = sent_at(monkeypatch, packets[:20], speed=2)
    assert double[-1] - double[0] == pytest.approx((normal[-1] - normal[0]) / 2)
    flat, _ = sent_at(monkeypatch, packets[:20], speed=None)
    assert len(set(flat)) == 1
    with pytest.raises(ValueError):
        sent_at(monkeypatch, packets[:2], speed=0)


def test_late_packets_counted(example, monkeypatch):
    _, _, packets = example
    clock = FakeClock()
    sock = FakeSocket(clock)
    monkeypatch.setattr(replay.socket, "socket", lambda *a: sock)
    stats = replay.replay(packets[:10], ("127.0.0.1", 9), clock=clock,
                          sleep=lambda s: clock.sleep(s + 0.005))      # oversleeps by 5 ms
    assert stats.late == 8      # the first two packets share t=0 and need no sleep
    assert stats.max_late_s == pytest.approx(0.005)


def test_datagrams_unchanged_and_in_order(example, receiver):
    _, _, packets = example
    stats = replay.replay(packets[:40], receiver.getsockname(), speed=None)
    assert stats.packets == 40
    assert received(receiver, 40) == [p.data for p in packets[:40]]


def test_gr_difi_payload_swaps_only_data_samples(example):
    _, _, packets = example
    ctx, data = packets[0], packets[1]
    assert ctx.is_context and not data.is_context
    assert replay.gr_difi_payload(ctx.data) == ctx.data
    swapped = replay.gr_difi_payload(data.data)
    start = 4 * fields.PROLOGUE_WORDS
    assert swapped[:start] == data.data[:start] and len(swapped) == len(data.data)
    n = (len(data.data) - start) // 2
    assert struct.unpack(f"<{n}h", swapped[start:]) == struct.unpack(f">{n}h", data.data[start:])
    assert replay.gr_difi_payload(swapped) == data.data


@pytest.mark.parametrize("text, dest", [("127.0.0.1:50000", ("127.0.0.1", 50000)),
                                        ("localhost:1", ("localhost", 1))])
def test_parse_dest(text, dest):
    assert replay.parse_dest(text) == dest


@pytest.mark.parametrize("text", ["127.0.0.1", ":50000", "host:", "host:0", "host:65536", "host:x"])
def test_parse_dest_rejects(text):
    with pytest.raises(ValueError):
        replay.parse_dest(text)


def test_cli_udp(receiver, capsys):
    host, port = receiver.getsockname()
    main([f"--udp={host}:{port}", "--gr-difi", "--seconds", "0.02", "--seed", "1790000000"])
    got = received(receiver, 12)        # a context packet and 11 data packets
    assert got[0][0] >> 4 == fields.PKT_TYPE_CONTEXT
    assert "sent 12 packets" in capsys.readouterr().out
    receiver.settimeout(0.2)
    with pytest.raises(socket.timeout):
        receiver.recv(9000)


def test_cli_capture_stays_difi_when_replay_is_swapped(receiver, tmp_path):
    # --gr-difi changes only what is sent: the capture written alongside is unswapped.
    from scapy.all import UDP, rdpcap
    host, port = receiver.getsockname()
    path = tmp_path / "out.pcap"
    main([str(path), f"--udp={host}:{port}", "--gr-difi", "--seconds", "0.02", "--seed", "1790000000"])
    sent = received(receiver, 12)
    captured = [bytes(f[UDP].payload) for f in rdpcap(str(path))]
    assert len(captured) == 12
    assert captured[0] == sent[0]                                   # context: never swapped
    assert [replay.gr_difi_payload(c) for c in captured[1:]] == sent[1:]
    assert captured[1:] != sent[1:]


@pytest.mark.parametrize("argv", [[], ["--gr-difi", "out.pcap"], ["out.pcap", "--seconds", "0"],
                                  ["--udp", "nosuchhost.invalid:9"]])
def test_cli_rejects(argv, capsys):
    with pytest.raises(SystemExit):
        main(argv)
    assert "error:" in capsys.readouterr().err
