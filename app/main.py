"""srelab demo-app.

En liten FastAPI-app med PostgreSQL-backend og innebygde "chaos"-endepunkter, laget for å
gi Azure SRE Agent og Azure Monitor noe realistisk å undersøke.
"""

import logging
import os
import random
import time
from contextlib import asynccontextmanager, contextmanager

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

# Telemetri må konfigureres før app-instansen og DB-poolen opprettes, slik at
# auto-instrumenteringen (requests, dependencies, logger) kobles på.
if os.getenv("APPLICATIONINSIGHTS_CONNECTION_STRING"):
    from azure.monitor.opentelemetry import configure_azure_monitor

    configure_azure_monitor(logger_name="srelab")

import psycopg2  # noqa: E402
from psycopg2.pool import ThreadedConnectionPool  # noqa: E402

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("srelab")
# Telemetri-eksporten logger hver HTTP-forespørsel på INFO, som ellers drukner applogene.
logging.getLogger("azure").setLevel(logging.WARNING)

APP_VERSION = os.getenv("APP_VERSION", "local")
CHAOS_ENABLED = os.getenv("CHAOS_ENABLED", "true").lower() == "true"
# Andel av /api-kall som feiler. Sett via miljøvariabel for å simulere en dårlig release.
ERROR_RATE = float(os.getenv("CHAOS_ERROR_RATE", "0"))

pool: ThreadedConnectionPool | None = None
memory_hog: list[bytearray] = []


def create_pool() -> ThreadedConnectionPool | None:
    if not os.getenv("DB_HOST"):
        log.warning("DB_HOST er ikke satt, kjører uten database")
        return None
    return ThreadedConnectionPool(
        minconn=1,
        maxconn=int(os.getenv("DB_POOL_SIZE", "5")),
        host=os.environ["DB_HOST"],
        port=int(os.getenv("DB_PORT", "5432")),
        dbname=os.getenv("DB_NAME", "appdb"),
        user=os.getenv("DB_USER", "pgadmin"),
        password=os.getenv("DB_PASSWORD", ""),
        sslmode=os.getenv("DB_SSLMODE", "prefer"),
        connect_timeout=5,
    )


@contextmanager
def db():
    if pool is None:
        raise HTTPException(503, "Database er ikke konfigurert")
    conn = pool.getconn()
    try:
        with conn, conn.cursor() as cur:
            yield cur
    finally:
        pool.putconn(conn)


@asynccontextmanager
async def lifespan(_: FastAPI):
    global pool
    try:
        pool = create_pool()
        if pool:
            with db() as cur:
                cur.execute(
                    """
                    CREATE TABLE IF NOT EXISTS items (
                        id SERIAL PRIMARY KEY,
                        name TEXT NOT NULL,
                        created_at TIMESTAMPTZ NOT NULL DEFAULT now()
                    )
                    """
                )
            log.info("Database klar")
    except Exception:
        # Appen starter likevel, slik at /health svarer og /ready viser feilen.
        log.exception("Klarte ikke å koble til databasen ved oppstart")
    log.info("srelab-app %s startet (chaos=%s, error_rate=%s)", APP_VERSION, CHAOS_ENABLED, ERROR_RATE)
    yield
    if pool:
        pool.closeall()


app = FastAPI(title="srelab demo-app", version=APP_VERSION, lifespan=lifespan)


class ItemIn(BaseModel):
    name: str


def maybe_fail() -> None:
    if ERROR_RATE and random.random() < ERROR_RATE:
        raise RuntimeError(f"Simulert feil (CHAOS_ERROR_RATE={ERROR_RATE})")


@app.get("/")
def index():
    return {"app": "srelab", "version": APP_VERSION, "docs": "/docs"}


@app.get("/health")
def health():
    """Liveness: prosessen lever. Sjekker ikke avhengigheter."""
    return {"status": "ok"}


@app.get("/ready")
def ready():
    """Readiness: kan appen nå databasen?"""
    try:
        with db() as cur:
            cur.execute("SELECT 1")
    except HTTPException:
        raise
    except Exception as exc:
        log.error("Readiness feilet: %s", exc)
        raise HTTPException(503, "Database utilgjengelig") from exc
    return {"status": "ready"}


@app.get("/api/items")
def list_items():
    maybe_fail()
    with db() as cur:
        cur.execute(
            """
            WITH recent_items AS (
                SELECT id, name, created_at
                FROM items
                ORDER BY id DESC
                LIMIT 100
            ),
            name_counts AS (
                SELECT name, count(*) AS same_name
                FROM items
                WHERE name IN (SELECT DISTINCT name FROM recent_items)
                GROUP BY name
            )
            SELECT i.id, i.name, i.created_at, c.same_name
            FROM recent_items i
            JOIN name_counts c ON c.name = i.name
            ORDER BY i.id DESC
            """
        )
        rows = cur.fetchall()
    return [
        {"id": r[0], "name": r[1], "created_at": r[2].isoformat(), "same_name_count": r[3]}
        for r in rows
    ]


@app.post("/api/items", status_code=201)
def create_item(item: ItemIn):
    maybe_fail()
    with db() as cur:
        cur.execute("INSERT INTO items (name) VALUES (%s) RETURNING id", (item.name,))
        item_id = cur.fetchone()[0]
    log.info("Opprettet item %s", item_id)
    return {"id": item_id, "name": item.name}


# --- Chaos-endepunkter -------------------------------------------------------------


def require_chaos() -> None:
    if not CHAOS_ENABLED:
        raise HTTPException(404)


@app.get("/chaos/error")
def chaos_error():
    """Kaster en uhåndtert exception -> 500 og en rad i AppExceptions."""
    require_chaos()
    raise RuntimeError("Simulert uhåndtert feil fra /chaos/error")


@app.get("/chaos/slow")
def chaos_slow(ms: int = 3000):
    """Treg respons i selve appen."""
    require_chaos()
    time.sleep(min(ms, 60_000) / 1000)
    return {"slept_ms": ms}


@app.get("/chaos/db-slow")
def chaos_db_slow(seconds: float = 5):
    """Treg database-spørring -> treg dependency i Application Insights."""
    require_chaos()
    with db() as cur:
        cur.execute("SELECT pg_sleep(%s)", (min(seconds, 60),))
    return {"db_slept_s": seconds}


@app.get("/chaos/db-exhaust")
def chaos_db_exhaust(seconds: float = 30):
    """Holder alle tilkoblinger i poolen opptatt -> andre DB-kall feiler."""
    require_chaos()
    if pool is None:
        raise HTTPException(503, "Database er ikke konfigurert")
    held = []
    try:
        while True:
            held.append(pool.getconn())
    except psycopg2.pool.PoolError:
        log.warning("Connection pool tom, holder %d tilkoblinger i %ss", len(held), seconds)
    time.sleep(min(seconds, 120))
    for conn in held:
        pool.putconn(conn)
    return {"held_connections": len(held), "seconds": seconds}


@app.get("/chaos/cpu")
def chaos_cpu(seconds: float = 10):
    """Brenner CPU -> CPU-metrikker og eventuell skalering."""
    require_chaos()
    end = time.monotonic() + min(seconds, 120)
    n = 0
    while time.monotonic() < end:
        n += sum(i * i for i in range(10_000))
    return {"burned_s": seconds}


@app.get("/chaos/memory")
def chaos_memory(mb: int = 100):
    """Lekker minne som aldri frigis -> til slutt OOMKilled og restart."""
    require_chaos()
    memory_hog.append(bytearray(min(mb, 1024) * 1024 * 1024))
    total = sum(len(b) for b in memory_hog) // (1024 * 1024)
    log.warning("Minnelekkasje: holder nå %d MB", total)
    return {"leaked_total_mb": total}


@app.get("/chaos/crash")
def chaos_crash():
    """Dreper prosessen -> container restart i ContainerAppSystemLogs."""
    require_chaos()
    log.critical("Simulert krasj fra /chaos/crash")
    logging.shutdown()
    os._exit(1)
