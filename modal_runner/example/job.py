"""Tiny example; replace this file with your own training or inference script."""

import json
import os
from pathlib import Path
import platform


def main():
    output = Path(os.environ["MODAL_RUN_OUTPUT_DIR"])
    output.mkdir(parents=True, exist_ok=True)
    result = {"message": "Hello from Modal", "python": platform.python_version(),
              "hostname": platform.node()}
    print(json.dumps(result), flush=True)
    (output / "example_result.json").write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    main()
