# Acknowledgments and provenance

HostHop's Logitech design was informed by the HID++ 2.0 feature model and by the open-source InputSwitch and SwiGi projects. Feature `0x1814` is resolved dynamically; device-specific feature indices are not copied or embedded.

The Apple-Silicon DDC transport began from the small MIT-licensed m1ddc approach. The final LG-only route was established through bounded, clean-room observation of IOKit call boundaries on hardware owned by the project author. HostHop does not include Lunar or BetterDisplay binaries, inject into installed copies, bypass licensing, or copy their proprietary backends.

Lunar's public source documented the distinction between standard VCP input selection and LG's alternate `0xF4` command. BetterDisplay and Lunar were used as behavioral compatibility references while diagnosing Apple-Silicon display routes.

Trademarks belong to their respective owners. Project references do not imply endorsement or affiliation.
