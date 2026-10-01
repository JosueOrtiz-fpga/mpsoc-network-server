"""python3 -m difi_rx: listen to a DIFI stream through gr-difi.

By default it also plays the model's stream into gr-difi, so the tone is heard; with
--external it only listens, for another sender. Run through make ref-listen, which
puts the pinned gr-difi on PYTHONPATH:
    make ref-listen LISTEN_ARGS="--tone-hz 1500 --seconds 10"
    make ref-listen LISTEN_ARGS="--external --port 50000"     # until Ctrl-C
"""
import argparse
import math
import time

from difi_ref.config import StreamConfig
from difi_ref.packetizer import Packetizer
from difi_ref.replay import gr_difi_payload, replay
from difi_ref.sources import IdealTone
from difi_ref.timebase import IdealTimebase

from .receiver import Receiver

STALL_S = 3     # --external: report a silent stream after this long


def main(argv=None) -> None:
    p = argparse.ArgumentParser(prog="python3 -m difi_rx", description=__doc__.splitlines()[0])
    p.add_argument("--port", type=int, default=50000, help="UDP port to listen on (default 50000)")
    p.add_argument("--external", action="store_true", help="only listen, for another sender")
    p.add_argument("--stream-id", type=int, default=StreamConfig.stream_id,
                   help="with --external: the stream's ID (default 0)")
    p.add_argument("--sample-rate", type=int, default=StreamConfig.ctx_sample_rate_hz,
                   help="with --external: the stream's sample rate (default 192000)")
    p.add_argument("--seconds", type=float, default=5.0, help="length of the model's stream (default 5 s)")
    p.add_argument("--tone-hz", type=int, default=1_500,
                   help="the model's tone offset from the band center (default 1.5 kHz)")
    p.add_argument("--rf-hz", type=int, default=StreamConfig.ctx_rf_ref_freq_hz,
                   help="the model's RF reference frequency (default 7.1 MHz)")
    args = p.parse_args(argv)

    if args.external:
        rx = Receiver(args.port, args.stream_id, args.sample_rate, record=False, listen=True)
        rx.start()
        print(f"listening on UDP {args.port} for stream {args.stream_id} at {args.sample_rate} S/s; Ctrl-C ends")
        try:
            last, quiet = 0, 0
            while True:
                time.sleep(1)
                now = rx.received()
                quiet = quiet + 1 if now == last else 0
                last = now
                if quiet == STALL_S:
                    print(f"no samples for {STALL_S} s: no sender, or gr-difi stopped (see any error above)",
                          flush=True)
        except KeyboardInterrupt:
            pass
        finally:
            rx.stop()
        return

    seed = int(time.time())
    cfg = StreamConfig(ctx_rf_ref_freq_hz=args.rf_hz, ctx_ts_cal_time=seed)
    pkt = Packetizer(cfg, IdealTone(args.tone_hz, cfg.ctx_sample_rate_hz),
                     IdealTimebase(seed, cfg.fs_in_hz, cfg.ddc_decim))
    packets = list(pkt.packets(math.ceil(args.seconds * cfg.ctx_sample_rate_hz / cfg.samples_per_pkt)))
    rx = Receiver(args.port, cfg.stream_id, cfg.ctx_sample_rate_hz, record=False, listen=True)
    rx.start()
    print(f"playing {args.seconds:g} s of a {args.tone_hz:+d} Hz tone at {cfg.ctx_rf_ref_freq_hz} Hz "
          f"through gr-difi on UDP {args.port}")
    try:
        stats = replay(packets, ("127.0.0.1", args.port), transform=gr_difi_payload)
        time.sleep(0.5)     # let the audio buffer drain: a heuristic, at worst the tone's end is cut
        print(f"sent {stats.packets} packets, {stats.late} late (max {1000 * stats.max_late_s:.1f} ms)")
    except KeyboardInterrupt:
        pass
    finally:
        rx.stop()


if __name__ == "__main__":
    main()
