# difi-ref

Python reference model for the DIFI stream: packetizer, stream checker and capture I/O. It is the oracle that the cocotb benches (R1 to R5) and the HIL tests (from R2) compare the hardware against. The scope, iterations and design choices are in [`docs/m1-reference-model.md`](../../../docs/m1-reference-model.md).

```
difi_ref/        # the model; Python standard library only
tests/           # pytest suite (make ref-test)
  oracle.py      # adapter for the DIFI-Certification Construct definitions
pytest.ini
```

Run the tests from the repository root:

```sh
git submodule update --init   # third_party/DIFI-Certification, once
make ref-test                 # PYTEST_ARGS=-v for the test names
```

`difi_ref` must import nothing outside the standard library, so that it runs unchanged under the system Python, GNU Radio's Python, cocotb and on the board; `tests/test_package.py` enforces this. Construct and numpy are only for the tests.
