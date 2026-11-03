"""Fixture launcher: all native registry calls use an in-memory substitute."""
import os
import sys
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import test_p2 as fixtures
from p2 import gsp

args = sys.argv[1:]
position = args.index('p2.gsp')
registry = fixtures.MemoryRegistry(admin=False)
with patch.object(gsp, 'WindowsRegistry', return_value=registry):
    raise SystemExit(gsp.main(args[position + 1:]))
