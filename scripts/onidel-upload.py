#!/usr/bin/env python3
"""Resumable multipart upload to Onidel S3 (Ceph).

- Uses AWS Signature Version 4.
- Records upload state in ~/.onidel-upload-state/<bucket>/<key>.json.
- On restart, lists already-uploaded parts and resumes from the first gap.
- Retries individual parts with exponential backoff.
- Leaves the multipart upload active on failure so progress survives.
"""

import argparse
import configparser
import base64
import hashlib
import json
import os
import re
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

import requests
from requests.adapters import HTTPAdapter
from requests_aws4auth import AWS4Auth

# Disable SSL warnings; Onidel uses its own CA.
requests.packages.urllib3.disable_warnings()

CHUNK_SIZE = 256 * 1024 * 1024  # 256 MiB parts
MAX_WORKERS = 2
MAX_RETRIES = 10
RETRY_BASE_SLEEP = 5.0


def load_rclone_config(remote_name="onidel"):
    cfg_path = Path.home() / ".config" / "rclone" / "rclone.conf"
    if not cfg_path.exists():
        raise FileNotFoundError(f"rclone config not found: {cfg_path}")
    cp = configparser.ConfigParser()
    cp.read(cfg_path)
    if remote_name not in cp:
        raise KeyError(f"remote '{remote_name}' not found in {cfg_path}")
    sec = cp[remote_name]
    endpoint = sec.get("endpoint", "").rstrip("/")
    if not endpoint:
        raise ValueError("endpoint missing in rclone config")
    access_key = sec.get("access_key_id", "")
    secret_key = sec.get("secret_access_key", "")
    if not access_key or not secret_key:
        raise ValueError("access/secret keys missing in rclone config")
    # Region is usually the second dot-separated segment, e.g. ap-southeast-2.
    m = re.search(r"s3\.([^.]+)\.onidel\.cloud", endpoint)
    region = m.group(1) if m else "default"
    return {
        "endpoint": endpoint,
        "access_key": access_key,
        "secret_key": secret_key,
        "region": region,
    }


class OnidelUploader:
    def __init__(self, creds, bucket, key, local_path, chunk_size=CHUNK_SIZE, workers=MAX_WORKERS):
        self.endpoint = creds["endpoint"]
        self.access_key = creds["access_key"]
        self.secret_key = creds["secret_key"]
        self.region = creds.get("region", "default")
        self.bucket = bucket
        self.key = key
        self.local_path = Path(local_path)
        self.chunk_size = chunk_size
        self.workers = workers
        self.session = requests.Session()
        self.session.mount("https://", HTTPAdapter(max_retries=0))
        self.total_size = self.local_path.stat().st_size
        self.state_dir = Path.home() / ".onidel-upload-state" / bucket
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.state_file = self.state_dir / (key.replace("/", "_") + ".json")
        self.lock = threading.Lock()

    def _auth(self):
        return AWS4Auth(self.access_key, self.secret_key, self.region, "s3")

    def _request(self, method, path, headers=None, data=None, params=None):
        url = f"https://{self.endpoint}/{self.bucket}/{path}"
        headers = dict(headers or {})
        resp = self.session.request(
            method, url, headers=headers, data=data, params=params,
            auth=self._auth(), verify=False, timeout=300,
        )
        return resp

    def init_multipart(self):
        resp = self._request("POST", quote(self.key, safe="/"), {"Content-Type": "application/octet-stream"}, params={"uploads": ""})
        if resp.status_code != 200:
            raise RuntimeError(f"InitiateMultipartUpload failed: {resp.status_code} {resp.text[:500]}")
        m = re.search(r"<UploadId>([^<]+)</UploadId>", resp.text)
        if not m:
            raise RuntimeError(f"No UploadId in response: {resp.text[:500]}")
        return m.group(1)

    def list_parts(self, upload_id):
        parts = {}
        marker = ""
        while True:
            params = {"uploadId": upload_id}
            if marker:
                params["part-number-marker"] = marker
            resp = self._request("GET", quote(self.key, safe="/"), params=params)
            if resp.status_code != 200:
                raise RuntimeError(f"ListParts failed: {resp.status_code} {resp.text[:500]}")
            for m in re.finditer(r"<Part>.*?<PartNumber>(\d+)</PartNumber>.*?<ETag>([^<]+)</ETag>.*?</Part>", resp.text, re.DOTALL):
                etag = m.group(2).replace("&quot;", '"').strip()
                parts[int(m.group(1))] = etag
            next_marker = re.search(r"<NextPartNumberMarker>([^<]+)</NextPartNumberMarker>", resp.text)
            is_truncated = "<IsTruncated>true</IsTruncated>" in resp.text
            if not is_truncated:
                break
            marker = next_marker.group(1) if next_marker else ""
        return parts

    def complete_multipart(self, upload_id, parts):
        parts_xml = "".join(f"<Part><PartNumber>{n}</PartNumber><ETag>{etag}</ETag></Part>" for n, etag in sorted(parts.items()))
        body = f"<CompleteMultipartUpload>{parts_xml}</CompleteMultipartUpload>"
        resp = self._request("POST", quote(self.key, safe="/"), {"Content-Type": "application/xml"}, data=body.encode(), params={"uploadId": upload_id})
        if resp.status_code not in (200, 201):
            raise RuntimeError(f"CompleteMultipartUpload failed: {resp.status_code} {resp.text[:500]}")

    def abort_multipart(self, upload_id):
        self._request("DELETE", quote(self.key, safe="/"), params={"uploadId": upload_id})

    def _upload_part(self, upload_id, part_number, start, existing_etags):
        etag = existing_etags.get(part_number)
        if etag:
            with self.lock:
                self._save_state(upload_id, existing_etags)
            return part_number, etag
        end = min(start + self.chunk_size, self.total_size)
        size = end - start
        with open(self.local_path, "rb") as f:
            f.seek(start)
            data = f.read(size)
        for attempt in range(MAX_RETRIES):
            try:
                headers = {"Content-Type": "application/octet-stream"}
                resp = self._request("PUT", quote(self.key, safe="/"), headers, data=data, params={"partNumber": str(part_number), "uploadId": upload_id})
                if resp.status_code == 200:
                    etag = resp.headers.get("ETag", "").strip('"')
                    with self.lock:
                        existing_etags[part_number] = etag
                        self._save_state(upload_id, existing_etags)
                    return part_number, etag
                elif resp.status_code == 403 and "QuotaExceeded" in resp.text:
                    sleep = RETRY_BASE_SLEEP * (2 ** attempt) + (attempt * 5)
                    print(f"  part {part_number}: QuotaExceeded, backing off {sleep:.0f}s (attempt {attempt+1}/{MAX_RETRIES})", flush=True)
                    time.sleep(sleep)
                else:
                    raise RuntimeError(f"status {resp.status_code}: {resp.text[:300]}")
            except Exception as e:
                if attempt == MAX_RETRIES - 1:
                    raise RuntimeError(f"part {part_number} failed after {MAX_RETRIES} attempts: {e}")
                time.sleep(RETRY_BASE_SLEEP * (2 ** attempt))
        raise RuntimeError(f"part {part_number} failed")

    def _save_state(self, upload_id, parts):
        state = {
            "upload_id": upload_id,
            "key": self.key,
            "local_path": str(self.local_path),
            "chunk_size": self.chunk_size,
            "total_size": self.total_size,
            "parts": parts,
            "updated": datetime.now(timezone.utc).isoformat(),
        }
        tmp = self.state_file.with_suffix(".tmp")
        tmp.write_text(json.dumps(state, indent=2))
        tmp.replace(self.state_file)

    def _load_state(self):
        if not self.state_file.exists():
            return None
        try:
            return json.loads(self.state_file.read_text())
        except Exception:
            return None

    def run(self):
        num_parts = (self.total_size + self.chunk_size - 1) // self.chunk_size
        print(f"Uploading {self.local_path} ({self.total_size} bytes) as {self.key} in {num_parts} parts")

        state = self._load_state()
        upload_id = None
        existing_etags = {}
        if state and state.get("upload_id") and state.get("chunk_size") == self.chunk_size:
            upload_id = state["upload_id"]
            try:
                existing_etags = self.list_parts(upload_id)
                print(f"Resuming upload {upload_id}; {len(existing_etags)}/{num_parts} parts already on server")
            except Exception as e:
                print(f"Could not resume previous upload: {e}; starting fresh")
                upload_id = None
                existing_etags = {}

        if not upload_id:
            upload_id = self.init_multipart()
            print(f"Started new multipart upload {upload_id}")
            self._save_state(upload_id, {})

        # Verify local file size matches state.
        if state and state.get("total_size") != self.total_size:
            print("WARNING: local file size changed since last run; aborting old upload and restarting")
            try:
                self.abort_multipart(upload_id)
            except Exception:
                pass
            upload_id = self.init_multipart()
            existing_etags = {}
            self._save_state(upload_id, {})

        parts_to_upload = [p for p in range(1, num_parts + 1) if p not in existing_etags]
        completed = len(existing_etags)

        start_time = time.time()
        uploaded_bytes = completed * self.chunk_size
        uploaded_bytes = min(uploaded_bytes, self.total_size)

        def progress_update():
            elapsed = time.time() - start_time
            speed = uploaded_bytes / elapsed if elapsed > 0 else 0
            remaining = self.total_size - uploaded_bytes
            eta = remaining / speed if speed > 0 else 0
            pct = uploaded_bytes * 100 / self.total_size
            print(f"{pct:.1f}% | {uploaded_bytes}/{self.total_size} bytes | {speed/1024/1024:.1f} MiB/s | ETA {eta/60:.0f}m", flush=True)

        with ThreadPoolExecutor(max_workers=self.workers) as ex:
            futures = {
                ex.submit(self._upload_part, upload_id, p, (p - 1) * self.chunk_size, existing_etags): p
                for p in parts_to_upload
            }
            for fut in as_completed(futures):
                p = futures[fut]
                try:
                    fut.result()
                    with self.lock:
                        uploaded_bytes += self.chunk_size if p < num_parts else (self.total_size - (p - 1) * self.chunk_size)
                    progress_update()
                except Exception as e:
                    print(f"ERROR uploading part {p}: {e}", flush=True)
                    ex.shutdown(wait=False)
                    raise

        # Refresh etags from server to be safe.
        existing_etags = self.list_parts(upload_id)
        missing = set(range(1, num_parts + 1)) - set(existing_etags)
        if missing:
            raise RuntimeError(f"parts still missing after upload: {missing}")

        print("Completing multipart upload...")
        self.complete_multipart(upload_id, existing_etags)
        self.state_file.unlink(missing_ok=True)
        print("DONE")


def main():
    parser = argparse.ArgumentParser(description="Resumable upload to Onidel S3")
    parser.add_argument("local_path")
    parser.add_argument("--key", "-k", help="S3 object key (default: basename)")
    parser.add_argument("--bucket", "-b", default="swiftmaestro-releases")
    parser.add_argument("--chunk-size", type=int, default=CHUNK_SIZE, help="part size in bytes")
    parser.add_argument("--workers", type=int, default=MAX_WORKERS)
    parser.add_argument("--remote", default="onidel")
    args = parser.parse_args()

    creds = load_rclone_config(args.remote)
    key = args.key or os.path.basename(args.local_path)
    uploader = OnidelUploader(creds, args.bucket, key, args.local_path, args.chunk_size, args.workers)
    try:
        uploader.run()
    except Exception as e:
        print(f"Upload failed but state is preserved: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
