"""Stream settings: a stand-in for the active register set until iteration 4.

Field names follow the register map in docs/difi-streaming-architecture.md, so the
register set can replace this object without touching the packetizer. The defaults are
the example run in docs/m1-reference-model.md: 192 kS/s at 7.1 MHz.
"""
from dataclasses import dataclass
from fractions import Fraction

from . import fields

MIN_SAMPLES_PER_PKT = 18    # DIFI's 128-octet minimum Ethernet payload
MAX_SAMPLES_PER_PKT = 361   # 1500-byte MTU, no jumbo frames (the CAPS maximum)


@dataclass(frozen=True)
class StreamConfig:
    stream_id: int = 0                  # STREAM_ID
    fs_in_hz: int = 122_880_000         # FS_IN_HZ (build constant)
    ddc_decim: int = 640                # DDC_DECIM
    samples_per_pkt: int = 360          # SAMPLES_PER_PKT
    ctx_interval: int = 533             # CTX_INTERVAL: about one context packet per second at 192 kS/s
    payload_bits: int = 16              # PAYLOAD_FORMAT + 1
    ctx_ref_point_id: int = 75          # CTX_REF_POINT_ID: RF converter analog port
    ctx_bandwidth_hz: int = 153_600     # CTX_BANDWIDTH: placeholder until R4's context math
    ctx_if_ref_freq_hz: int = 0         # CTX_IF_REF_FREQ: no analog IF
    ctx_rf_ref_freq_hz: int = 7_100_000  # CTX_RF_REF_FREQ
    ctx_if_band_offset_hz: int = 0      # CTX_IF_BAND_OFFSET: zero-IF output
    ctx_ref_level_dbm: Fraction = Fraction(0)  # CTX_REF_LEVEL: placeholder until R4
    ctx_sample_rate_hz: int = 192_000   # CTX_SAMPLE_RATE
    ctx_ts_adjust_fs: int = 0           # CTX_TS_ADJUST: 0 for the test source
    ctx_ts_cal_time: int = 0            # CTX_TS_CAL_TIME: seconds of the last timebase seed
    ctx_state_event: int = fields.STATE_EVENT_UNLOCKED  # CTX_STATE_EVENT

    def __post_init__(self):
        errors = []
        if not 0 <= self.stream_id <= 0xFFFFFFFF:
            errors.append(f"stream ID {self.stream_id} does not fit 32 bits")
        if not MIN_SAMPLES_PER_PKT <= self.samples_per_pkt <= MAX_SAMPLES_PER_PKT:
            errors.append(f"{self.samples_per_pkt} samples per packet is outside "
                          f"{MIN_SAMPLES_PER_PKT} to {MAX_SAMPLES_PER_PKT}")
        if self.ddc_decim <= 0 or self.ddc_decim % 4:
            errors.append(f"decimation {self.ddc_decim} is not a positive multiple of 4")
        elif self.ctx_sample_rate_hz * self.ddc_decim != self.fs_in_hz:
            errors.append(f"sample rate {self.ctx_sample_rate_hz} Hz is not FS_IN_HZ / DDC_DECIM "
                          f"= {Fraction(self.fs_in_hz, self.ddc_decim)} Hz")
        if not 0 <= self.ctx_interval <= 0xFFFFFF:
            errors.append(f"context interval {self.ctx_interval} does not fit 24 bits")
        if self.payload_bits != 16:
            errors.append(f"{self.payload_bits}-bit samples: this build supports only 16-bit")
        if self.ctx_ref_point_id not in fields.REF_POINT_IDS:
            errors.append(f"reference point {self.ctx_ref_point_id} is not one of {fields.REF_POINT_IDS}")
        for name in ("ctx_bandwidth_hz", "ctx_sample_rate_hz"):
            if getattr(self, name) <= 0:
                errors.append(f"{name} must be positive")
        if errors:
            raise ValueError("; ".join(errors))
        # Encode once, so an unencodable value fails here rather than in the packetizer.
        for name in ("ctx_bandwidth_hz", "ctx_if_ref_freq_hz", "ctx_rf_ref_freq_hz",
                     "ctx_if_band_offset_hz", "ctx_sample_rate_hz"):
            fields.hz_to_q44_20(getattr(self, name))
        fields.ref_level_word(self.ctx_ref_level_dbm)
