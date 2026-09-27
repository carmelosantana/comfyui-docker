#!/usr/bin/env python3
"""Reproduce pixeloe's platform marker on suffixed Linux runner kernels."""

from pip._vendor.packaging.markers import Marker


marker = Marker(
    '(sys_platform == "win32" and platform_machine == "AMD64") or '
    '(sys_platform == "linux" and (platform_machine == "x86_64" or '
    'platform_machine == "aarch64")) or '
    '(sys_platform == "darwin" and platform_machine == "arm64" and '
    'platform_release >= "25")'
)
for system, machine, release, expected in [
    ("linux", "x86_64", "6.17.0-1022-azure", True),
    ("linux", "aarch64", "6.8.0-1041-aws", True),
    ("darwin", "arm64", "24.0.0", False),
    ("darwin", "arm64", "25.0.0", True),
]:
    actual = marker.evaluate({
        "sys_platform": system,
        "platform_machine": machine,
        "platform_release": release,
    })
    assert actual == expected, (system, machine, release, actual)
print("pip platform markers: 4 checks passed (including Azure kernel suffix)")
