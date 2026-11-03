"""Ordinary temporary directories under the workspace, with inherited Windows ACLs."""
import shutil
import uuid
from pathlib import Path


class TemporaryDirectory:
    def __init__(self, prefix='fixture-', dir=None):
        base = Path(dir) if dir else Path(__file__).resolve().parents[1] / '.test-scratch'
        base.mkdir(exist_ok=True)
        self.path = base / (prefix + uuid.uuid4().hex)
        self.path.mkdir()
        self.name = str(self.path)

    def cleanup(self):
        if self.path.exists():
            shutil.rmtree(self.path)

    def __enter__(self):
        return self.name

    def __exit__(self, *args):
        self.cleanup()
