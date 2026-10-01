"""DIFI reference model: packetizer, checker and capture I/O (docs/m1-reference-model.md).

Standard library only, so the same code runs under the system Python, GNU Radio's
Python, the cocotb environment and on the board. Construct (for the DIFI-Certification
oracle) and numpy are test-side dependencies and must never be imported from here.
"""
