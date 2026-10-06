import sys; sys.path.insert(0, "/Users/marius.remman/Documents/srelab/srelabinfra/app")
from fastapi.testclient import TestClient
import main
with TestClient(main.app, raise_server_exceptions=False) as c:
    for path in ["/", "/health", "/ready", "/api/items", "/chaos/error", "/chaos/slow?ms=10", "/chaos/cpu?seconds=0.1", "/chaos/memory?mb=1"]:
        r = c.get(path); print(r.status_code, path, r.text[:80])
