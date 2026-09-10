#!/usr/bin/env python3
"""Build the interactive image and optionally publish it to Docker Hub."""

import argparse
import subprocess
from pathlib import Path


CONTEXT = Path(__file__).resolve().parent


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--image",
        required=True,
        help="Docker image repository, for example docker.io/arashsm79/mlruntime",
    )
    parser.add_argument("--tag", default="latest")
    parser.add_argument("--context", type=Path, default=CONTEXT)
    parser.add_argument(
        "--push",
        action="store_true",
        help="Push the tagged image after building",
    )
    args = parser.parse_args()
    image = f"{args.image}:{args.tag}"
    print(f"Building {image}")
    subprocess.run(
        ["docker", "build", "-t", image, str(args.context)],
        check=True,
    )

    if args.push:
        print(f"Pushing {image}")
        subprocess.run(["docker", "push", image], check=True)


if __name__ == "__main__":
    main()
