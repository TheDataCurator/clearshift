"""ClearShift crew optimizer — OR-lab entry point.

The canonical implementation lives in ``app/backend/optimizer.py`` so it ships
with the deployed Databricks App and the What-if studio imports it directly.
This shim keeps ``python model/optimizer.py`` working for local OR-Tools
experiments and for the committed solver-evidence run, without a second copy of
the logic to drift out of sync.
"""

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "app"))

from backend.optimizer import Job, Worker, assign, _demo  # noqa: E402,F401

if __name__ == "__main__":
    _demo()
