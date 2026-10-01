# difi-ref

Python reference model for the DIFI stream: packetizer, stream checker and capture I/O. It is the oracle that the cocotb benches (R1 to R5) and the HIL tests (from R2) compare the hardware against. The scope, iterations and design choices are in [`docs/m1-reference-model.md`](../../../docs/m1-reference-model.md).

```
difi_ref/
  fields.py      # DIFI constants and encoders: headers, class ID, Q44.20 Hz, Q9.7 dBm
  config.py      # StreamConfig: stand-in for the active register set (iteration 4 replaces it)
  timebase.py    # IdealTimebase: stand-in for the Q32.32 timebase (iteration 5)
  sources.py     # IdealTone: complex int16 tone, phase from the global sample index
  packetizer.py  # data and context packets; Packetizer emits the stream from ENABLE on
  pcap.py        # pcap writer with synthetic Ethernet, IPv4 and UDP headers
  replay.py      # UDP replay paced by packet timestamps; gr_difi_payload() for gr-difi#19
  __main__.py    # python3 -m difi_ref out.pcap | --udp HOST:PORT: write or send a generated stream
difi_rx/         # receiver side: GNU Radio and gr-difi, so kept out of difi_ref
  receiver.py    # gr-difi's DIFI Source in a headless flowgraph: record samples and tags, or listen
  __main__.py    # python3 -m difi_rx: hear the model's tone through gr-difi (make ref-listen)
tests/           # pytest suite (make ref-test; test_rx.py under make ref-rx-check)
  oracle.py      # adapter for the DIFI-Certification Construct definitions
pytest.ini
```

The model is built up in iterations (see the doc above). Iteration 1 generates the example run's stream, 192 kS/s at 7.1 MHz with a +12 kHz tone: a context packet with the change indicator, then data packets of 360 samples every 1.875 ms, with a periodic context packet about once a second. Every packet passes the oracle's `validate()`, and a generated capture passes `certify_source.py`.

To look at a stream by hand, from `sw/apps/difi-ref`:

```sh
python3 -m difi_ref /tmp/difi.pcap --seconds 2          # open in Wireshark, or:
(cd /tmp && python3 $OLDPWD/../../../third_party/DIFI-Certification/certify_source.py --pcap /tmp/difi.pcap)
```

`certify_source.py` writes a summary, a PSD plot and an error log into its working directory (so not the submodule, or it shows as modified), and exits 0 even on failure: read its `Overall Result` line.

Run the tests from the repository root:

```sh
git submodule update --init   # third_party/DIFI-Certification, once
make ref-test                 # PYTEST_ARGS=-v for the test names
```

## Receiver pre-check

`make ref-rx-check` replays the model's stream over UDP on the loopback interface, in real time, into `gr-difi`'s DIFI Source block. It runs two streams: the example run (192 kS/s, 7.1 MHz, +12 kHz tone) and 384 kS/s at 14.2 MHz with a −1.5 kHz tone. For each stream it checks that:

- every sample arrives, bit-exact against the model's source;
- the only gap tag is the one `gr-difi` puts on the first packet;
- each context packet's fields come back in a `context` tag at the right sample;
- the FFT peak is on the tone's bin, with every other bin at least 60 dB down.

It needs GNU Radio and `gr-difi` at `GR_DIFI_COMMIT` (`versions.env`), which `tests/hil/scripts/setup-host.sh` builds, unmodified, into `/opt/gr-difi-<commit>`. `GR_DIFI_PREFIX=` points the targets at another build. The tests carry the pytest marker `rx` and run only with pytest's `--rx` option, which `make ref-rx-check` passes; `make ref-test` leaves them out whatever `PYTEST_ARGS` says. If `gr-difi` stops (for example on a context packet it rejects), the run fails with the number of samples it did output, and its error is in pytest's captured output.

**`gr-difi` reads samples byte-swapped** on little-endian hosts: [gr-difi#19](https://github.com/DIFI-Consortium/gr-difi/issues/19), open at the pinned commit. The model stays DIFI (big-endian). The replay swaps each data packet's samples on the way into `gr-difi` (`replay(..., transform=gr_difi_payload)`, or `--gr-difi` on the command line). `test_gr_difi_issue_19_still_present` fails once a newer `gr-difi` fixes the bug; the swap goes then. Never write swapped packets to a capture.

To hear it:

```sh
make ref-listen                                          # 5 s of a +1.5 kHz tone through gr-difi to the speakers
make ref-listen LISTEN_ARGS="--tone-hz -440 --seconds 10"
make ref-listen LISTEN_ARGS="--external --port 50000"   # listen to another sender until Ctrl-C, e.g. from here:
python3 -m difi_ref --udp 127.0.0.1:50000 --gr-difi --seconds 10 --tone-hz 1000
```

Listen mode plays the real part at 48 kHz and prints each context and missed-packet tag as it arrives. Its tone is 1.5 kHz rather than the example run's 12 kHz, which is shrill. Occasional `aU` (audio underrun) messages come from the sender's clock and the sound card's drifting apart, and are harmless.

`difi_ref` must import nothing outside the standard library, so that it runs unchanged under the system Python, GNU Radio's Python, cocotb and on the board; `tests/test_package.py` enforces this. Construct and numpy are only for the tests.
