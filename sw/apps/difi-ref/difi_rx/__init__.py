"""The receiver side of the pre-check: gr-difi in a headless GNU Radio flowgraph.

Kept out of difi_ref, which must stay standard library only. Needs GNU Radio and the
pinned gr-difi build on PYTHONPATH (make ref-rx-check and make ref-listen set it).
"""
