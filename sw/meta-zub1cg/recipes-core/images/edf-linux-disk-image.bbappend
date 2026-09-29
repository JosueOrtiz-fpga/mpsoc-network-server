# ZU1CG is a CG part with no VCU, so Xilinx's GStreamer/OMX stack has no
# hardware to drive. Dropping it also avoids the commercial-flagged
# gstreamer1.0-omx and gstd from meta-multimedia.
AMD_CORTEXA53_COMMON_INSTALL:remove = "packagegroup-xilinx-gstreamer"