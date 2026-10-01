"""python3 -m difi_ref: write a generated DIFI stream to a pcap.

Example, from sw/apps/difi-ref:
    python3 -m difi_ref out.pcap --seconds 2
    (cd /tmp && python3 $OLDPWD/../../../third_party/DIFI-Certification/certify_source.py --pcap $OLDPWD/out.pcap)
"""
import argparse
import math
import time

from .config import StreamConfig
from .packetizer import Packetizer
from .pcap import write_pcap
from .sources import IdealTone
from .timebase import IdealTimebase


def main(argv=None) -> None:
    p = argparse.ArgumentParser(prog="python3 -m difi_ref", description=__doc__.splitlines()[0])
    p.add_argument("pcap", help="output file")
    p.add_argument("--seconds", type=float, default=2.0, help="stream length (default 2 s)")
    p.add_argument("--seed", type=int, help="timebase seed, POSIX seconds (default: now)")
    p.add_argument("--tone-hz", type=int, default=12_000, help="tone offset from the band center (default 12 kHz)")
    p.add_argument("--rf-hz", type=int, default=StreamConfig.ctx_rf_ref_freq_hz,
                   help="RF reference frequency (default 7.1 MHz)")
    args = p.parse_args(argv)

    seed = int(time.time()) if args.seed is None else args.seed
    cfg = StreamConfig(ctx_rf_ref_freq_hz=args.rf_hz, ctx_ts_cal_time=seed)
    source = IdealTone(args.tone_hz, cfg.ctx_sample_rate_hz)
    pkt = Packetizer(cfg, source, IdealTimebase(seed, cfg.fs_in_hz, cfg.ddc_decim))
    num_data = math.ceil(args.seconds * cfg.ctx_sample_rate_hz / cfg.samples_per_pkt)
    with open(args.pcap, "wb") as f:
        n = write_pcap(f, pkt.packets(num_data))
    print(f"{args.pcap}: {n} packets ({num_data} data), {cfg.ctx_sample_rate_hz} S/s "
          f"at {cfg.ctx_rf_ref_freq_hz} Hz, tone {args.tone_hz:+d} Hz, seed {seed}")


if __name__ == "__main__":
    main()
