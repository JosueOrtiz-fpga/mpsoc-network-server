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
  __main__.py    # python3 -m difi_ref out.pcap: write a generated stream
tests/           # pytest suite (make ref-test)
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

`difi_ref` must import nothing outside the standard library, so that it runs unchanged under the system Python, GNU Radio's Python, cocotb and on the board; `tests/test_package.py` enforces this. Construct and numpy are only for the tests.
