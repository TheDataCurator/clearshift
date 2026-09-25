"""Genie hand-off.

The governed intent matcher in routes/ask.py is the fallback and the
specification of what a good answer looks like. On Databricks the same natural
question can go to a Genie space over the ClearShift gold tables, which widens
the question surface without giving up governance: Genie answers as the caller,
over Unity Catalog tables the caller is entitled to, and returns the SQL it ran
so the answer is inspectable rather than taken on trust.

This module is a thin wrapper over the Databricks SDK Genie API. It is optional:
if no space is configured, or the call fails, the caller falls back to the
governed intents so the assistant always answers.
"""

from __future__ import annotations

import logging

from backend import config

logger = logging.getLogger(__name__)

_client = None


def enabled() -> bool:
    return bool(config.GENIE_SPACE_ID)


def _workspace():
    global _client
    if _client is None:
        from databricks.sdk import WorkspaceClient

        # In Databricks Apps the app service principal authenticates from the
        # environment. Locally, GENIE_PROFILE selects a CLI profile.
        _client = (WorkspaceClient(profile=config.GENIE_PROFILE)
                   if config.GENIE_PROFILE else WorkspaceClient())
    return _client


def _rows_from(res):
    sr = getattr(res, "statement_response", None) or res
    manifest = getattr(sr, "manifest", None)
    result = getattr(sr, "result", None)
    if not manifest or not result:
        return [], []
    columns = [c.name for c in manifest.schema.columns]
    rows = [list(r) for r in (result.data_array or [])]
    return columns, rows


def _fetch_rows(w, space, msg, attachment):
    """Fetch the query result, trying the attachment API first (the query is
    executed on attach), then the message API, then an explicit execute."""
    attempts = []
    aid = getattr(attachment, "attachment_id", None)
    if aid:
        attempts.append(lambda: w.genie.get_message_attachment_query_result(
            space, msg.conversation_id, msg.id, aid))
        attempts.append(lambda: w.genie.execute_message_attachment_query(
            space, msg.conversation_id, msg.id, aid))
    attempts.append(lambda: w.genie.get_message_query_result(space, msg.conversation_id, msg.id))
    for call in attempts:
        try:
            cols, rows = _rows_from(call())
            if rows:
                return cols, rows
            last = (cols, rows)
        except Exception as exc:  # noqa: BLE001
            logger.warning("genie result fetch attempt failed: %s", exc)
            last = ([], [])
    return last


def ask(question: str) -> dict:
    """Send a question to the Genie space and return answer, SQL and rows.

    Raises on any failure so the caller can fall back to the governed intents.
    """
    space = config.GENIE_SPACE_ID
    w = _workspace()
    msg = w.genie.start_conversation_and_wait(space, question)

    answer, sql, description = None, None, None
    columns: list[str] = []
    rows: list[list] = []

    for a in (msg.attachments or []):
        if a.text and a.text.content:
            answer = a.text.content
        if a.query:
            sql = a.query.query
            description = a.query.description
            columns, rows = _fetch_rows(w, space, msg, a)

    if answer is None and description:
        answer = description
    if answer is None:
        answer = "Genie could not answer that from the ClearShift tables."

    return {
        "answer": answer,
        "engine": "genie",
        "sql": sql,
        "query_description": description,
        "columns": columns,
        "rows": rows[:50],
        "row_count": len(rows),
        "space_id": space,
    }
