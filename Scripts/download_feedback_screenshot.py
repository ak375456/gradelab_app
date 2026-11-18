#!/usr/bin/env python3
"""Save a GradeLab feedback screenshot using the active gcloud admin login."""

import argparse
import base64
import json
from pathlib import Path
import subprocess
from urllib.error import HTTPError
from urllib.parse import quote
from urllib.request import Request, urlopen


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("document_id", help="Document ID from the Firestore feedback collection")
    parser.add_argument("output", type=Path, help="Path for the downloaded JPEG")
    args = parser.parse_args()

    token = subprocess.check_output(["gcloud", "auth", "print-access-token"], text=True).strip()
    document_id = quote(args.document_id, safe="")
    url = (
        "https://firestore.googleapis.com/v1/projects/gradelab-feedback/databases/"
        f"(default)/documents/feedback/{document_id}?mask.fieldPaths=screenshot"
    )
    request = Request(url, headers={
        "Authorization": f"Bearer {token}",
        "X-Goog-User-Project": "gradelab-feedback",
    })
    try:
        with urlopen(request, timeout=20) as response:
            document = json.load(response)
    except HTTPError as error:
        parser.exit(1, f"Could not read the feedback document (HTTP {error.code}).\n")

    value = document.get("fields", {}).get("screenshot", {}).get("bytesValue")
    if not value:
        parser.exit(1, "This report has no screenshot.\n")

    try:
        with args.output.open("xb") as output:
            output.write(base64.b64decode(value, validate=True))
    except FileExistsError:
        parser.exit(1, f"Output already exists: {args.output}\n")
    print(f"Saved {args.output}")


if __name__ == "__main__":
    main()
