# Baseline: srelab-dev

Dette dokumentet beskriver hvordan systemet ser ut **når alt er normalt**. Hvordan endringer gjøres, står i [operations.md](operations.md). Bruk det til å vurdere om en observasjon er et avvik, og hvor stort avviket er.

- **Målt:** 2026-10-06, 12:53–13:02 UTC (9 minutter med jevn trafikk) og 12:30–12:50 UTC (tomgang)
- **Versjon:** app-image `e4723c5`, infrastruktur fra `main` samme dag
- **Miljø:** `rg-srelab-dev` i `norwayeast`, Log Analytics-workspace `log-srelab-dev-vqn6gh`

## Systemet i korte trekk

```
Internett ─HTTP:80─> agw-srelab-dev ─HTTPS:443─> ca-srelab-dev ─TLS:5432─> psql-srelab-dev-vqn6gh
 (Application Gateway v2)  (Container App, internt miljø)  (PostgreSQL Flexible, B1ms)
                                         │
                                         ├─> kv-srelab-dev-vqn6gh (DB-passord, hentes av Container Apps-plattformen)
                                         └─> acrsrelabdevvqn6gh (image, hentes ved ny revisjon og ny replika)
```

| Ledd | Konfigurasjon som påvirker normalbildet |
|---|---|
| Application Gateway | Standard_v2, autoscale 0–2 instanser, helseprobe `GET /` hvert 30. sekund |
| Container App | 0,5 vCPU / 1 GiB, **min 1 og maks 3 replikaer**, skalerer på 50 samtidige requests per replika |
| App | FastAPI/uvicorn, connection pool mot Postgres med maks 5 tilkoblinger per replika |
| PostgreSQL | Burstable B1ms (1 vCore, 2 GiB), 32 GiB lagring, PG 16, kun privat tilgang |

## Trafikk under målingen

Syntetisk trafikk fra én klient, 4 parallelle brukere, **~3,9 requests/s (~230/min)**:

| Operasjon | Andel |
|---|---|
| `GET /api/items` | 70 % |
| `POST /api/items` | 15 % |
| `GET /` | 10 % |
| `GET /ready` | 5 % |

I tillegg kommer Application Gateway sin helseprobe (`GET /`, 2 per minutt).

## Feilrate

| Signal | Baseline |
|---|---|
| 5xx i Application Gateway | **0** av 2089 requests |
| 4xx i Application Gateway | 1 (`/favicon.ico` → 404, forventet fra nettlesere) |
| Skanning fra internett | Normalt. Sporadiske requests mot kjente sårbarhetsstier (for eksempel `/webui_wsma_Http`, `/robots.txt`), og HTTP 400 uten URI som kan ta flere sekunder. Det er ikke et problem med appen. |
| Feilede requests i App Insights (`Success == false`) | **0** |
| Feilede DB-kall (`AppDependencies`, postgresql) | **0** |
| `AppExceptions` | **0** |
| Container-restarter (`RestartCount`) | **0** |

Normaltilstanden er altså **null feil**. Enhver vedvarende 5xx-rate er et avvik.

## Latens

### Ende til ende (Application Gateway, `AGWAccessLogs.TimeTaken`)

| p50 | p95 | p99 |
|---|---|---|
| 10 ms | 26 ms | 73 ms |

Metrikken `ApplicationGatewayTotalTime` ligger på 1–18 ms i snitt per minutt under trafikk. Enkeltminutter i tomgang kan vise flere hundre ms, fordi da er det bare ett eller to kall per minutt.

### Per operasjon i appen (`AppRequests.DurationMs`)

| Operasjon | p50 | p95 | p99 |
|---|---|---|---|
| `GET /api/items` | 8 ms | 18 ms | 60 ms |
| `POST /api/items` | 9 ms | 58 ms | 104 ms |
| `GET /ready` | 7 ms | 10 ms | 51 ms |
| `GET /` | 1 ms | 2 ms | 3 ms |

### Database (`AppDependencies`, `DependencyType == "postgresql"`)

| p50 | p95 | p99 |
|---|---|---|
| 4 ms | 6 ms | 9 ms |

De fleste API-kall gjør 1–2 SQL-kall. DB-tid utgjør derfor typisk under halvparten av request-tiden.

## Ressursbruk

### Container App (`ca-srelab-dev`)

| Metrikk | Tomgang | Under trafikk |
|---|---|---|
| CPU (`UsageNanoCores`) | ~0,003 kjerner | ~0,02 kjerner (maks 0,024) |
| `CpuPercentage` | 0 % | 3–4 % |
| Minne (`WorkingSetBytes`) | ~135 MB | ~137 MB, **flatt** |
| `Replicas` | 1 | 1 |
| `RestartCount` | 0 | 0 |

Minnet skal være stabilt. En jevn økning over tid uten tilsvarende økning i trafikk er et avvik. Ved denne trafikken skal det ikke skaleres ut. Flere enn 1 replika betyr at trafikken eller ressursbruken er langt over normalen.

### PostgreSQL (`psql-srelab-dev-vqn6gh`)

| Metrikk | Tomgang | Under trafikk |
|---|---|---|
| `cpu_percent` | 6–12 % (snitt 8 %) | 8–11 % (snitt 9 %) |
| `memory_percent` | ~58 % | ~58 % |
| `active_connections` | 9–11 | 9–11 |
| `storage_percent` | 13 % | 13 % |
| `cpu_credits_remaining` | 38–40 | 40–41 (svakt stigende) |

PostgreSQL har en del faste kostnader som ikke kommer fra appen:
- **CPU på ~8 % i tomgang er normalt.** Det er bakgrunnsprosesser i Azure og Postgres.
- **Minne på ~58 % er normalt.** Postgres reserverer `shared_buffers` og cache.
- **~9–11 tilkoblinger er normalt, også i tomgang.** Tallet inkluderer Azure sine egne system- og overvåkingstilkoblinger i tillegg til appens pool (maks 5 per replika).

**Burstable-kreditter:** B1ms har en garantert CPU-andel og bruker kreditter for å gå over den. Går `cpu_credits_remaining` mot 0, struper Azure CPU-en, og da øker DB-latensen kraftig uten at noe er endret i appen. Kredittene øker sakte ved normal last.

### Application Gateway (`agw-srelab-dev`)

| Metrikk | Baseline |
|---|---|
| `HealthyHostCount` | 1 |
| `UnhealthyHostCount` | 0 |
| `CapacityUnits` | 3–6 |

## Logger

| Tabell | Normalt innhold |
|---|---|
| `ContainerAppConsoleLogs` | Én `INFO`-linje per opprettet item, oppstartslinjer ved ny revisjon. Ingen `ERROR`/`CRITICAL`. |
| `ContainerAppSystemLogs` | Hendelser ved deploy og ny revisjon, ellers stille. **Normalt ved deploy:** `ProbeFailed` («Probe of StartUp failed») mens ny container starter, og `ContainerTerminated` med reason `ManuallyStopped` når gammel revisjon stoppes. Utenom deploy: ingen `BackOff`, `ProbeFailed`, `OOMKilled` eller `ContainerTerminated`. |
| `AppTraces` | Samme applogger som konsollen, via OpenTelemetry |
| `AzureActivity` | Skriveoperasjoner fra GitHub Actions ved deploy av infra eller app |

## Foreslåtte SLO-er

Målt i Application Gateway, altså slik brukeren opplever det:

| SLO | Mål | Målevindu |
|---|---|---|
| Tilgjengelighet | ≥ 99,5 % av requests uten 5xx | 30 dager |
| Latens | ≥ 95 % av `/api/*`-requests under 300 ms | 30 dager |

Baseline (0 % feil, p95 26 ms) ligger godt innenfor. Det gir rom for normal variasjon uten at SLO-en brytes.

## Når er det et avvik?

| Signal | Normalt | Undersøk | Alvorlig |
|---|---|---|---|
| 5xx-andel (AGW), 5 min | 0 % | > 0,5 % | > 2 % |
| p95 latens (AGW), 5 min | ~26 ms | > 150 ms | > 300 ms |
| p95 DB-kall | ~6 ms | > 50 ms | > 200 ms |
| `UnhealthyHostCount` | 0 | ≥ 1 i 2 min | ≥ 1 i 5 min |
| `RestartCount` | 0 | ≥ 1 | ≥ 3 per time |
| Container-minne (`WorkingSetBytes`) | ~135 MB, flatt | > 300 MB eller jevn økning | > 700 MB (grensen er 1 GiB) |
| Container-CPU | < 0,03 kjerner | > 0,2 kjerner over tid | > 0,4 kjerner (grensen er 0,5) |
| `Replicas` | 1 | 2 | 3 (maks) |
| Postgres `cpu_percent` | ~8 % | > 40 % over tid | > 80 % |
| Postgres `active_connections` | 9–11 | > 20 | > 40 |
| Postgres `cpu_credits_remaining` | ~40, stigende | synkende trend | < 10 |
| Postgres `storage_percent` | 13 % | > 70 % | > 85 % |

Tersklene er implementert som alert-regler i [`infra/modules/alerts.bicep`](../infra/modules/alerts.bicep).

## Viktig ved tolking av data

- **Application Insights sampler.** Hver rad i `AppRequests`, `AppDependencies` og `AppTraces` kan representere flere hendelser. Feltet `ItemCount` sier hvor mange. Tell med `sum(ItemCount)`, ikke `count()`. Under målingen representerte 1285 rader 2060 requests.
- **`AGWAccessLogs` samples ikke.** Bruk den for eksakte tall på volum og statuskoder.
- **Lite trafikk gir støyete persentiler.** Ved et par requests per minutt kan ett enkelt tregt kall dominere p95 og p99. Se alltid på volumet samtidig, og se bare på requests som er rutet til appen (`isnotempty(BackendPoolName)`) før du vurderer latens.
- **Trafikken over er syntetisk** og kommer fra én klient. Ekte trafikk vil ha mer variasjon. Mål på nytt etter større endringer.

## Mål baseline på nytt

Sett vinduet til en periode med normal trafikk:

```kusto
let start = datetime(2026-10-06T12:53:00Z);
let stop  = datetime(2026-10-06T13:02:00Z);
// Ende til ende, eksakt (ikke samplet)
AGWAccessLogs
| where TimeGenerated between (start .. stop)
| summarize requests = count(),
            err5xx = countif(HttpStatus >= 500),
            p50_ms = percentile(TimeTaken, 50) * 1000,
            p95_ms = percentile(TimeTaken, 95) * 1000,
            p99_ms = percentile(TimeTaken, 99) * 1000
```

```kusto
// Per operasjon i appen (samplet: bruk ItemCount)
AppRequests
| where TimeGenerated between (start .. stop)
| summarize requests = sum(ItemCount),
            failed = sumif(ItemCount, Success == false),
            p50 = percentile(DurationMs, 50),
            p95 = percentile(DurationMs, 95),
            p99 = percentile(DurationMs, 99)
  by Name
```

```kusto
// Databasekall
AppDependencies
| where TimeGenerated between (start .. stop) and DependencyType == "postgresql"
| summarize calls = sum(ItemCount),
            failed = sumif(ItemCount, Success == false),
            p50 = percentile(DurationMs, 50),
            p95 = percentile(DurationMs, 95)
```

```kusto
// Restarter og helseproblemer i Container Apps
ContainerAppSystemLogs
| where TimeGenerated between (start .. stop)
| where Reason in ("BackOff", "ProbeFailed", "OOMKilled", "ContainerTerminated")
| summarize count() by Reason, bin(TimeGenerated, 5m)
```

Ressursmetrikkene (CPU, minne, replikaer, Postgres-kreditter og -tilkoblinger) hentes fra Azure Monitor-metrikker på ressursene, for eksempel:

```bash
az monitor metrics list --resource <ressurs-id> --metrics WorkingSetBytes Replicas \
  --aggregation Average Maximum --interval PT1M --start-time <start> --end-time <slutt>
```
