# difi-ref

Python reference model for the DIFI stream: packetizer, stream checker and capture I/O. It is the oracle that the cocotb benches (R1 to R5) and the HIL tests (from R2) compare the hardware against. The scope, iterations and design choices are in [`docs/m1-reference-model.md`](../../../docs/m1-reference-model.md).

```
difi_ref/
  fields.py      # DIFI constants and encoders: headers, class ID, Q44.20 Hz, Q9.7 dBm
  config.py      # StreamConfig: stand-in for the active register set (iteration 4 replaces it)
  timebase.py    # IdealTimebase: stand-in for the Q32.32 timebase (iteration 5)
  sources.py     # IdealTone and CounterRamp: complex int16 samples by global sample index
  packetizer.py  # data and context packets; Packetizer emits the stream from ENABLE on
  decode.py      # packets back into their fields: the packetizer in reverse
  checker.py     # stream checker, strict or lenient; python3 -m difi_ref.checker CAPTURE
  pcap.py        # pcap writer (synthetic Ethernet, IPv4, UDP); pcap and pcapng reader
  replay.py      # UDP replay paced by packet timestamps; gr_difi_payload() for gr-difi#19
  __main__.py    # python3 -m difi_ref out.pcap | --udp HOST:PORT: write or send a generated stream
difi_rx/         # receiver side: GNU Radio and gr-difi, so kept out of difi_ref
  receiver.py    # gr-difi's DIFI Source in a headless flowgraph: record samples and tags, or listen
  __main__.py    # python3 -m difi_rx: hear the model's tone through gr-difi (make ref-listen)
tests/           # pytest suite (make ref-test; test_rx.py under make ref-rx-check)
  oracle.py      # adapter for the DIFI-Certification Construct definitions
  reference_captures.py  # the DIFI-Certification captures the tests read
pytest.ini
```

The model is built up in iterations (see the doc above). Iteration 1 generates the example run's stream, 192 kS/s at 7.1 MHz with a +12 kHz tone: a context packet with the change indicator, then data packets of 360 samples every 1.875 ms, with a periodic context packet about once a second. Every packet passes the oracle's `validate()`, and a generated capture passes `certify_source.py`. Iteration 3 adds the stream checker, the counter ramp and the capture reader (below).

To look at a stream by hand, from `sw/apps/difi-ref`:

```sh
python3 -m difi_ref /tmp/difi.pcap --seconds 2          # open in Wireshark, or:
(cd /tmp && python3 $OLDPWD/../../../third_party/DIFI-Certification/certify_source.py --pcap /tmp/difi.pcap)
```

`certify_source.py` writes a summary, a PSD plot and an error log into its working directory (so not the submodule, or it shows as modified), and exits 0 even on failure: read its `Overall Result` line.

## Stream checker

`difi_ref.checker` checks each packet and the stream rules that the DIFI tools do not: context first, change-indicator placement, separate continuous counts, data timestamps stepping by the packet period (within 1 ps), each context packet carrying the next data packet's timestamp, gaps sized from timestamps, and, given the source, every sample. It takes the packet period from the stream's own context packets, so it needs no settings. `--rules` lists the rules.

```sh
python3 -m difi_ref /tmp/ramp.pcap --ramp --seconds 3
python3 -m difi_ref.checker /tmp/ramp.pcap --ramp            # strict; --ramp also checks every sample
python3 -m difi_ref.checker ../../../third_party/DIFI-Certification/example_pcaps/Example1_1Msps_8bits.pcapng --lenient
```

It exits 0 on a pass, 1 on any finding and 2 if the capture cannot be read, and lists the rules that never applied as "not checked". **Lenient mode** is for the DIFI-Certification reference captures: it checks context packets in full and data packets' prologues only, skips version packets, and accepts the Gain word, 8- to 16-bit samples and the change indicator on every context packet. The reader takes classic pcap and pcapng, decided by content (the reference captures are classic pcap named `.pcapng`), strips VLAN tags, and stops on anything that would lose a datagram silently: a truncated record, an IPv4 fragment, a link type other than Ethernet.

In Python, `check(packets, source=CounterRamp())` returns a report whose `findings` are (rule, packet index, message); `Checker().feed(packet)` takes one packet at a time.

## Tests

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
