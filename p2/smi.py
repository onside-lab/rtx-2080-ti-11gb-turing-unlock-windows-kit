"""Parse driver output without accepting duplicate or missing fields."""
import re


def versions(text):
    driver = re.findall(r'^\s*Driver Version\s*:[ \t]*([^\r\n]*)', text, re.M)
    gsp = re.findall(r'^\s*GSP Firmware Version\s*:[ \t]*([^\r\n]*)', text, re.M)
    if len(driver) != 1 or len(gsp) != 1:
        raise ValueError('Driver/GSP fields unavailable or ambiguous')
    match = re.fullmatch(r'(\d+(?:\.\d+)+)(?:[ \t]+\[Deprecated;[^\]\r\n]*\])?[ \t]*', driver[0])
    firmware = gsp[0].strip()
    if not match or not firmware:
        raise ValueError('Driver/GSP fields unavailable or ambiguous')
    return match[1], firmware
