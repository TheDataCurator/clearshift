"""Configuration. Everything comes from the environment so the same image runs
locally against a plain Postgres and on Databricks Apps against Lakebase."""

from __future__ import annotations

import os

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------
# On Databricks Apps, LAKEBASE_HOST is the Postgres endpoint and the password is
# a short-lived OAuth token minted per connection. Locally, PGPASSWORD is used.
LAKEBASE_HOST = os.getenv("LAKEBASE_HOST", "localhost")
LAKEBASE_PORT = int(os.getenv("LAKEBASE_PORT", "5432"))
LAKEBASE_DATABASE = os.getenv("LAKEBASE_DATABASE", "clearshift")
# On Databricks Apps the Postgres user is the app's service principal id, supplied
# as DATABRICKS_CLIENT_ID. Locally it falls back to the OS user.
LAKEBASE_USER = os.getenv(
    "LAKEBASE_USER",
    os.getenv("DATABRICKS_CLIENT_ID") or os.getenv("USER", "postgres"),
)
LAKEBASE_PASSWORD = os.getenv("PGPASSWORD", "")

# Set when running on Databricks Apps; triggers OAuth token auth
DATABRICKS_CLIENT_ID = os.getenv("DATABRICKS_CLIENT_ID", "")

GATE_SCHEMA = os.getenv("GATE_SCHEMA", "gate")

# The Lakebase endpoint the app authenticates against, in the autoscaling
# resource form: projects/<id>/branches/<id>/endpoints/<id>.
LAKEBASE_ENDPOINT = os.getenv(
    "LAKEBASE_ENDPOINT",
    "projects/clearshift/branches/production/endpoints/primary",
)

# ---------------------------------------------------------------------------
# Genie
# ---------------------------------------------------------------------------
# The Genie space over the ClearShift gold tables. When set, the assistant can
# hand a natural-language question to Genie and return the SQL it ran. When
# empty, the assistant answers from the governed intents only.
GENIE_SPACE_ID = os.getenv("GENIE_SPACE_ID", "")
# CLI profile for local runs. In Databricks Apps the app service principal
# authenticates from the environment, so this stays empty there.
GENIE_PROFILE = os.getenv("GENIE_PROFILE", "")

# ---------------------------------------------------------------------------
# Demo behavior
# ---------------------------------------------------------------------------
# Which viewer scope the UI opens as. Real deployments derive this from the
# authenticated principal; the demo lets you switch to show the access model.
DEFAULT_PRINCIPAL = os.getenv("DEFAULT_PRINCIPAL", "manager.whitlock")
