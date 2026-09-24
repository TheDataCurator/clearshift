"""Database access.

Two auth paths. On Databricks Apps the password is a short-lived OAuth token
minted from the app's service principal, so it is fetched per connection rather
than held. Locally it falls back to PGPASSWORD.
"""

from __future__ import annotations

import logging
import uuid
from contextlib import contextmanager
from typing import Any

import psycopg2
import psycopg2.extras

from backend import config

logger = logging.getLogger(__name__)

_http = None


def _oauth_token() -> str:
    """Mint a Lakebase database credential for the app service principal.

    Autoscaling Lakebase issues a credential scoped to an endpoint, which is a
    different API from the legacy instance credential. The credential is
    short-lived, so it is fetched per connection rather than held.
    """
    global _http
    if _http is None:
        from databricks.sdk import WorkspaceClient

        _http = WorkspaceClient()

    res = _http.api_client.do(
        "POST",
        "/api/2.0/postgres/credentials",
        body={"endpoint": config.LAKEBASE_ENDPOINT},
    )
    return res["token"]


def _password() -> str:
    if config.DATABRICKS_CLIENT_ID:
        return _oauth_token()
    return config.LAKEBASE_PASSWORD


@contextmanager
def connection():
    conn = psycopg2.connect(
        host=config.LAKEBASE_HOST,
        port=config.LAKEBASE_PORT,
        dbname=config.LAKEBASE_DATABASE,
        user=config.LAKEBASE_USER,
        password=_password(),
        sslmode="require" if config.DATABRICKS_CLIENT_ID else "prefer",
        connect_timeout=10,
    )
    try:
        yield conn
    finally:
        conn.close()


def query(sql: str, params: tuple | dict | None = None) -> list[dict[str, Any]]:
    with connection() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(sql, params)
            return [dict(row) for row in cur.fetchall()]


def execute(sql: str, params: tuple | dict | None = None) -> int:
    with connection() as conn:
        with conn.cursor() as cur:
            cur.execute(sql, params)
            affected = cur.rowcount
        conn.commit()
        return affected


# ---------------------------------------------------------------------------
# Viewer scope
# ---------------------------------------------------------------------------
# Site and supervisor are the access model rather than a filter, so every read
# passes through here. In a real deployment this is enforced by row-level
# security in the database as well; doing it in one place in the application
# keeps the demo readable.


def scoped_query(sql: str, principal: str, extra: dict[str, Any] | None = None) -> list[dict[str, Any]]:
    """Run a query with the caller's scope applied.

    `sql` must contain `{scope}` where the predicate belongs. Going through here
    rather than assembling the predicate at each call site means a route cannot
    forget it, and forgetting it is the failure that widens visibility silently.
    """
    predicate, params = scope_clause(principal)
    params.update(extra or {})
    return query(sql.format(scope=predicate), params)


def scope_clause(principal: str) -> tuple[str, dict[str, Any]]:
    """Return a SQL predicate and params restricting rows to what this principal
    may see. Unknown principals see nothing rather than everything."""
    rows = query(
        "SELECT scope_type, scope_value FROM gate.viewer_scope WHERE principal = %(p)s",
        {"p": principal},
    )
    if not rows:
        return "false", {}

    scope_types = {r["scope_type"] for r in rows}
    if "ALL" in scope_types:
        return "true", {}

    predicates: list[str] = []
    params: dict[str, Any] = {}
    sites = [r["scope_value"] for r in rows if r["scope_type"] == "SITE"]
    crews = [r["scope_value"] for r in rows if r["scope_type"] == "CREW"]

    if sites:
        predicates.append("location = ANY(%(sites)s)")
        params["sites"] = sites
    if crews:
        predicates.append("supervisor_id = ANY(%(crews)s)")
        params["crews"] = crews

    return "(" + " OR ".join(predicates) + ")", params
