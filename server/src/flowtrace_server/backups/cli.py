"""Local operator entry point. HTTP routes never accept shell commands/paths."""

import argparse
import json
from pathlib import Path
from uuid import UUID

from flowtrace_server.config import Settings

from .service import create_backup, restore_isolated, verify_backup_leased


def main():
    parser = argparse.ArgumentParser(description="FlowTrace maintenance backup / isolated restore")
    sub = parser.add_subparsers(dest="action", required=True)
    create = sub.add_parser("create")
    create.add_argument("--pg-dump", required=True, type=Path)
    verify = sub.add_parser("verify")
    verify.add_argument("backup_id", type=UUID)
    restore = sub.add_parser("restore-isolated")
    restore.add_argument("backup_id", type=UUID)
    restore.add_argument("--pg-restore", required=True, type=Path)
    restore.add_argument("--source-backup-root", required=True, type=Path)
    args = parser.parse_args()
    settings = Settings()
    root = settings.data_directory / "backups"
    try:
        if args.action == "create":
            result = create_backup(settings, root, pg_dump=args.pg_dump)
        elif args.action == "verify":
            manifest = verify_backup_leased(settings, args.backup_id)
            result = {
                "backup_id": str(args.backup_id),
                "status": "verified",
                "file_count": len(manifest["files"]) + 1,
            }
        else:
            result = restore_isolated(
                args.source_backup_root,
                args.backup_id,
                settings,
                pg_restore=args.pg_restore,
                attachment_directory=settings.data_directory / "attachments",
            )
        print(json.dumps(result, ensure_ascii=False))
    except Exception:
        # Native PostgreSQL/OS errors can contain connection strings and private
        # paths. Detailed operator debugging is separate from this safe receipt.
        raise SystemExit("backup_operation_failed") from None


if __name__ == "__main__":
    main()
