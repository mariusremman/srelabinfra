# Drift og endringsstyring: srelab-dev

Gjelder for alle som gjør endringer i miljøet, både mennesker og Azure SRE Agent.

## Grunnregel

**All infrastruktur og applikasjonskode styres fra dette repoet. Endringer gjøres bare via pull request mot `main`.**

Det gjelder også under hendelser. Ingen ressurser i `rg-srelab-dev` skal endres direkte i portalen, med Azure CLI eller på andre måter, heller ikke som midlertidig tiltak.

Hvorfor:
- **Bicep er fasit.** Neste deploy fra `main` overskriver manuelle endringer. En direkte endring forsvinner altså uten spor, eller fjerner noen andres endring.
- **PR-en er godkjenningen.** Workflowen kjører `what-if` på PR-er, slik at endringen kan vurderes før den rulles ut, og historikken viser hvem som endret hva og hvorfor.

## Hvor ting ligger

| Hva | Hvor | Hvordan det rulles ut |
|---|---|---|
| Infrastruktur (nettverk, gateway, Container Apps, database, Key Vault, logging) | `infra/` (Bicep) | `.github/workflows/infra.yml` ved push til `main` |
| Alert-regler og action group | `infra/modules/alerts.bicep` | Samme som infrastruktur |
| Applikasjon | `app/` | `.github/workflows/app.yml` ved push til `main` |
| Miljøvariabler for appen | `infra/modules/containerapps.bicep` | Infra-workflowen |
| Normaltilstand og terskler | `docs/baseline.md` | |

Konfigurasjon som ikke står i Bicep, for eksempel en miljøvariabel satt manuelt på container appen, fjernes ved neste infra-deploy.

## Ved hendelser

1. **Undersøk og dokumenter.** Les logger, metrikker og kode, og sammenlign med `docs/baseline.md`.
2. **Anbefal tiltak.** Beskriv hva som bør gjøres, hvorfor, og hvordan det kan rulles tilbake.
3. **Lever tiltaket som pull request** mot `main` i dette repoet. Beskriv i PR-en:
   - hvilken alert eller hendelse PR-en gjelder, med lenke
   - rotårsaken, med data som underbygger den (for eksempel KQL-resultat for tidsvinduet)
   - hvordan endringen er validert
4. **Utrulling skjer når PR-en er godkjent og merget.** Workflowen deployer.

Tilbakerulling gjøres på samme måte: `git revert` av commiten i en ny PR. App-workflowen bygger og deployer da den forrige versjonen av koden.

### Nødendringer

Hvis en hendelse krever en endring raskere enn en PR kan gi, kan **bare et menneske** gjøre en direkte endring. Endringen må føres tilbake til repoet som en PR samme dag. Ellers overskrives den ved neste deploy.

## For Azure SRE Agent

- **Ikke endre Azure-ressurser direkte.** Skriveverktøy for Azure CLI og kubectl er sperret med en global policy på agenten. Foreslå tiltak som PR i stedet.
- **Jobb alltid på siste `main`.** Kjør `git fetch origin` før du leser kode eller lager en branch, og bygg all endring på `origin/main`. En lokal kopi av repoet kan være utdatert.
- **Bygg videre på det som finnes.** Utvid eksisterende moduler (for eksempel `infra/modules/alerts.bicep`) i stedet for å lage nye filer med samme formål.
- **Ikke innfør nye påkrevde variabler eller hemmeligheter** uten å si det tydelig i PR-beskrivelsen. Eksisterende GitHub-variabler er dokumentert i README.
- **Navngi brancher** `sre-agent/<kort-beskrivelse>`.
