"""Use the existing BT DNS order for one domain; private output stays on host."""

import hashlib
import json
import os
import shutil
import subprocess
from datetime import UTC, datetime
from pathlib import Path

DOMAIN = "home.ruibin-ningh.top"
PANEL = Path("/www/server/panel")
CERTIFICATE = PANEL / "vhost/letsencrypt" / DOMAIN / "fullchain.pem"
METADATA = PANEL / "config/letsencrypt_v2.json"
NGINX = "/www/server/nginx/sbin/nginx"


def checked(args, **kwargs):
    return subprocess.run(args, check=True, timeout=300, **kwargs)


def main():
    os.umask(0o077)
    checked(["/usr/bin/openssl", "x509", "-in", str(CERTIFICATE), "-noout", "-checkhost", DOMAIN], stdout=subprocess.DEVNULL)
    due = subprocess.run(
        ["/usr/bin/openssl", "x509", "-in", str(CERTIFICATE), "-noout", "-checkend", "2592000"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10,
    )
    if due.returncode == 0:
        print(json.dumps({"domain": DOMAIN, "status": "valid_more_than_30_days"}))
        return
    if due.returncode != 1:
        raise RuntimeError("certificate_check_failed")
    metadata = json.loads(METADATA.read_text())
    matching = [
        key for key, value in metadata.get("orders", {}).items()
        if value.get("domains") == [DOMAIN]
        and value.get("save_path") == "vhost/letsencrypt/" + DOMAIN
        and value.get("auth_type") == "dns"
    ]
    if len(matching) != 1:
        raise RuntimeError("exact_existing_home_order_required")
    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    backup = Path("/root/workspace/backups") / ("flowtrace-tls-" + stamp)
    backup.mkdir(mode=0o700)
    shutil.copytree(CERTIFICATE.parent, backup / "certificate")
    shutil.copy2(METADATA, backup / "letsencrypt_v2.json")
    before = hashlib.sha256(CERTIFICATE.read_bytes()).hexdigest()
    with (backup / "renew.log").open("wb") as log:
        checked(
            [str(PANEL / "pyenv/bin/python3"), "-u", "class/acme_v2.py", "--renew=1", "--index=" + matching[0], "--cycle=30"],
            cwd=PANEL, stdout=log, stderr=subprocess.STDOUT,
        )
    checked(["/usr/bin/openssl", "x509", "-in", str(CERTIFICATE), "-noout", "-checkhost", DOMAIN], stdout=subprocess.DEVNULL)
    checked(["/usr/bin/openssl", "x509", "-in", str(CERTIFICATE), "-noout", "-checkend", "2592000"], stdout=subprocess.DEVNULL)
    changed = hashlib.sha256(CERTIFICATE.read_bytes()).hexdigest() != before
    if not changed:
        raise RuntimeError("renewal_did_not_replace_certificate")
    checked([NGINX, "-t"], stdout=subprocess.DEVNULL)
    checked([NGINX, "-s", "reload"], stdout=subprocess.DEVNULL)
    print(json.dumps({"domain": DOMAIN, "status": "renewed", "backup": str(backup)}))


if __name__ == "__main__":
    main()
