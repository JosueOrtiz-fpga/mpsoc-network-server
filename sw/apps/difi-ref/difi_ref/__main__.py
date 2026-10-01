"""python3 -m difi_ref: write a generated DIFI stream to a pcap, or send it over UDP.

Examples, from sw/apps/difi-ref:
    python3 -m difi_ref out.pcap --seconds 2
    (cd /tmp && python3 $OLDPWD/../../../third_party/DIFI-Certification/certify_source.py --pcap $OLDPWD/out.pcap)
    python3 -m difi_ref --udp 127.0.0.1:50000 --gr-difi --seconds 10     # into gr-difi, in real time
"""
import argparse
import math
import time

from .config import StreamConfig
from .packetizer import Packetizer
from .pcap import write_pcap
from .replay import gr_difi_payload, parse_dest, replay, resolve
from .sources import IdealTone
from .timebase import IdealTimebase


def _dest(text: str) -> tuple[str, int]:
    try:
        return resolve(parse_dest(text))
    except ValueError as e:
        raise argparse.ArgumentTypeError(str(e)) from None
    except OSError as e:
        raise argparse.ArgumentTypeError(f"cannot resolve {text!r}: {e}") from None


def main(argv=None) -> None:
    p = argparse.ArgumentParser(prog="python3 -m difi_ref", description=__doc__.splitlines()[0])
    p.add_argument("pcap", nargs="?", help="output file")
    p.add_argument("--udp", type=_dest, metavar="HOST:PORT",
                   help="also send the stream there, paced by its timestamps")
    p.add_argument("--gr-difi", action="store_true",
                   help="with --udp: samples in the byte order gr-difi reads (gr-difi issue #19); not DIFI")
    p.add_argument("--seconds", type=float, default=2.0, help="stream length (default 2 s)")
    p.add_argument("--seed", type=int, help="timebase seed, POSIX seconds (default: now)")
    p.add_argument("--tone-hz", type=int, default=12_000, help="tone offset from the band center (default 12 kHz)")
    p.add_argument("--rf-hz", type=int, default=StreamConfig.ctx_rf_ref_freq_hz,
                   help="RF reference frequency (default 7.1 MHz)")
    args = p.parse_args(argv)
    if not args.pcap and not args.udp:
        p.error("give an output file, --udp HOST:PORT, or both")
    if args.gr_difi and not args.udp:
        p.error("--gr-difi applies only to --udp: a capture stays DIFI")
    if args.seconds <= 0:
        p.error("--seconds must be positive")

    seed = int(time.time()) if args.seed is None else args.seed
    cfg = StreamConfig(ctx_rf_ref_freq_hz=args.rf_hz, ctx_ts_cal_time=seed)
    source = IdealTone(args.tone_hz, cfg.ctx_sample_rate_hz)
    pkt = Packetizer(cfg, source, IdealTimebase(seed, cfg.fs_in_hz, cfg.ddc_decim))
    num_data = math.ceil(args.seconds * cfg.ctx_sample_rate_hz / cfg.samples_per_pkt)
    # Generated in full before a replay, so generation cannot hold up the pacing;
    # written as generated when there is only a capture.
    packets = list(pkt.packets(num_data)) if args.udp else pkt.packets(num_data)
    print(f"{num_data} data packets, {cfg.ctx_sample_rate_hz} S/s "
          f"at {cfg.ctx_rf_ref_freq_hz} Hz, tone {args.tone_hz:+d} Hz, seed {seed}")
    if args.pcap:
        with open(args.pcap, "wb") as f:
            n = write_pcap(f, packets)
        print(f"wrote {n} packets to {args.pcap}")
    if args.udp:
        host, port = args.udp
        stats = replay(packets, args.udp, transform=gr_difi_payload if args.gr_difi else None)
        print(f"sent {stats.packets} packets to {host}:{port}"
              f"{' (samples byte-swapped for gr-difi)' if args.gr_difi else ''}, "
              f"{stats.late} late (max {1000 * stats.max_late_s:.1f} ms)")


if __name__ == "__main__":
    main()
