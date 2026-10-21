#!/usr/bin/env python3
"""Repair pathological self-refresh chains in a Chromium History database."""

from __future__ import annotations

import argparse
import datetime as dt
from pathlib import Path
import shutil
import sqlite3
import sys


CHAIN_START = 0x10000000
CLIENT_REDIRECT = 0x40000000

CANDIDATES_SQL = """
  SELECT child.url, urls.url, COUNT(*) AS links
  FROM visits AS child
  JOIN visits AS parent ON parent.id = child.from_visit
  JOIN urls ON urls.id = child.url
  WHERE {local_visit_filter}child.url = parent.url
    AND child.visit_time != parent.visit_time
    AND (child.transition & ?) != 0
    AND (child.transition & ?) = 0
  GROUP BY child.url, urls.url
  HAVING COUNT(*) >= ?
  ORDER BY links DESC
"""

UPDATE_SQL = """
  WITH pathological_urls AS (
    SELECT child.url
    FROM visits AS child
    JOIN visits AS parent ON parent.id = child.from_visit
    WHERE {local_visit_filter}child.url = parent.url
      AND child.visit_time != parent.visit_time
      AND (child.transition & ?) != 0
      AND (child.transition & ?) = 0
    GROUP BY child.url
    HAVING COUNT(*) >= ?
  )
  UPDATE visits
  SET transition = transition | ?
  WHERE id IN (
    SELECT child.id
    FROM visits AS child
    JOIN visits AS parent ON parent.id = child.from_visit
    JOIN pathological_urls ON pathological_urls.url = child.url
    WHERE {local_visit_filter}child.url = parent.url
      AND child.visit_time != parent.visit_time
      AND (child.transition & ?) != 0
      AND (child.transition & ?) = 0
  )
"""


# URLs that reloaded themselves with a client redirect at least :minimum times.
# Deletion drops their client-redirect visits, keeping the newest visit of each
# local day. Synced visits can lack their parent, so they are matched by flag.
DELETE_STEPS = [
    """CREATE TEMP TABLE refresh_urls AS
      SELECT child.url AS url, COUNT(*) AS links
      FROM visits AS child
      JOIN visits AS parent ON parent.id = child.from_visit
      WHERE child.url = parent.url
        AND child.visit_time != parent.visit_time
        AND (child.transition & :redirect) != 0
      GROUP BY child.url HAVING COUNT(*) >= :minimum""",
    """CREATE TEMP TABLE doomed AS
      SELECT id FROM visits
      WHERE url IN (SELECT url FROM refresh_urls)
        AND (transition & :redirect) != 0
        AND id NOT IN (
          SELECT MAX(id) FROM visits WHERE url IN (SELECT url FROM refresh_urls)
          GROUP BY url, strftime('%Y-%m-%d', visit_time / 1000000 - 11644473600,
                                 'unixepoch', 'localtime'))""",
    # Visits that followed a deleted one become chain starts.
    """UPDATE visits SET from_visit = 0, transition = transition | :chain_start
      WHERE from_visit IN (SELECT id FROM doomed)""",
    "DELETE FROM visit_source WHERE id IN (SELECT id FROM doomed)",
    "DELETE FROM context_annotations WHERE visit_id IN (SELECT id FROM doomed)",
    "DELETE FROM content_annotations WHERE visit_id IN (SELECT id FROM doomed)",
    "DELETE FROM clusters_and_visits WHERE visit_id IN (SELECT id FROM doomed)",
    """DELETE FROM cluster_visit_duplicates
      WHERE visit_id IN (SELECT id FROM doomed)
      OR duplicate_visit_id IN (SELECT id FROM doomed)""",
    "DELETE FROM visits WHERE id IN (SELECT id FROM doomed)",
    """UPDATE urls SET visit_count = (
        SELECT COUNT(*) FROM visits
        WHERE visits.url = urls.id AND (visits.transition & 255) != 8)
      WHERE id IN (SELECT url FROM refresh_urls)""",
    "DELETE FROM clusters WHERE cluster_id NOT IN (SELECT cluster_id FROM clusters_and_visits)",
    "DELETE FROM cluster_keywords WHERE cluster_id NOT IN (SELECT cluster_id FROM clusters)",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("database", type=Path, help="path to a profile History file")
    parser.add_argument(
        "--minimum-links",
        type=int,
        default=100,
        help="minimum repeated self-refresh links per URL (default: 100)",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="apply the repair; otherwise only report candidates",
    )
    parser.add_argument(
        "--delete-self-refresh",
        action="store_true",
        help="delete the self-refresh visits instead of only marking them, keeping the "
        "newest visit of each day per URL",
    )
    parser.add_argument(
        "--backup",
        type=Path,
        help="backup path (default: History.backup-YYYYmmdd-HHMMSS)",
    )
    return parser.parse_args()


def check_database(db: sqlite3.Connection) -> None:
    problems = [row[0] for row in db.execute("PRAGMA quick_check") if row[0] != "ok"]
    if problems:
        raise RuntimeError("database quick_check failed: " + "; ".join(problems))


def local_visit_filter(db: sqlite3.Connection) -> str:
    columns = {row[1] for row in db.execute("PRAGMA table_info(visits)")}
    if "originator_cache_guid" in columns:
        return "child.originator_cache_guid = '' AND "
    return ""


def backup_database(args: argparse.Namespace) -> None:
    timestamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = args.backup or args.database.with_name(
        f"{args.database.name}.backup-{timestamp}"
    )
    if backup.exists():
        raise RuntimeError(f"backup already exists: {backup}")
    shutil.copy2(args.database, backup)
    print(f"Backup: {backup}")


def delete_self_refresh(db: sqlite3.Connection, args: argparse.Namespace) -> int:
    params = {
        "redirect": CLIENT_REDIRECT,
        "chain_start": CHAIN_START,
        "minimum": args.minimum_links,
    }
    for step in DELETE_STEPS[:2]:
        db.execute(step, params)
    urls = db.execute(
        "SELECT links, urls.url FROM refresh_urls JOIN urls ON urls.id = refresh_urls.url"
        " ORDER BY links DESC"
    ).fetchall()
    doomed = db.execute("SELECT COUNT(*) FROM doomed").fetchone()[0]
    for links, url in urls:
        print(f"  links={links:>8} {url}")
    print(f"{doomed} self-refresh visits would be deleted.")
    if not doomed or not args.apply:
        print("Dry run only. Re-run with --apply after reviewing the URLs.")
        db.rollback()
        return 0

    backup_database(args)
    for step in DELETE_STEPS[2:]:
        db.execute(step, params)
    check_database(db)
    db.commit()
    db.execute("VACUUM")
    print(f"Deleted {doomed} visits.")
    return 0


def main() -> int:
    args = parse_args()
    if args.minimum_links < 1:
        print("--minimum-links must be positive", file=sys.stderr)
        return 2
    if not args.database.is_file():
        print(f"History database not found: {args.database}", file=sys.stderr)
        return 2

    db = sqlite3.connect(args.database, timeout=0)
    try:
        db.execute("PRAGMA busy_timeout=0")
        try:
            db.execute("BEGIN EXCLUSIVE")
        except sqlite3.OperationalError as error:
            raise RuntimeError(
                "database is in use; close Alacrium completely before running this tool"
            ) from error

        check_database(db)
        if args.delete_self_refresh:
            return delete_self_refresh(db, args)

        query_filter = local_visit_filter(db)
        candidates = list(
            db.execute(
                CANDIDATES_SQL.format(local_visit_filter=query_filter),
                (CLIENT_REDIRECT, CHAIN_START, args.minimum_links),
            )
        )
        if not candidates:
            print("No pathological self-refresh chains found.")
            db.rollback()
            return 0

        print("Pathological self-refresh chains:")
        for url_id, url, links in candidates:
            print(f"  links={links:>8} url_id={url_id:<8} {url}")

        if not args.apply:
            print("Dry run only. Re-run with --apply after reviewing the URLs.")
            db.rollback()
            return 0

        backup_database(args)

        db.execute(
            UPDATE_SQL.format(local_visit_filter=query_filter),
            (
                CLIENT_REDIRECT,
                CHAIN_START,
                args.minimum_links,
                CHAIN_START,
                CLIENT_REDIRECT,
                CHAIN_START,
            ),
        )
        changed = db.execute("SELECT changes()").fetchone()[0]
        check_database(db)
        db.commit()
        print(f"Repaired {changed} visits.")
        return 0
    except (RuntimeError, sqlite3.DatabaseError, OSError) as error:
        db.rollback()
        print(f"error: {error}", file=sys.stderr)
        return 1
    finally:
        db.close()


if __name__ == "__main__":
    raise SystemExit(main())
