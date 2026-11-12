# broker

The message broker of **Chance**: one NATS server with JetStream (ADR-030). The services publish their business events
to it (each publisher creates its own stream) and read each other's events from it. There is no code here: the repository
is a Helm chart that wraps the official NATS chart, a NetworkPolicy, a smoke test, a compose file for local runs and the
checks that keep them honest. Dominik owns the broker setup (plan Q-16).

## What this repository holds

| Path | What |
|---|---|
| [`helm/Chart.yaml`](helm/Chart.yaml), [`helm/Chart.lock`](helm/Chart.lock) | The chart `broker` and its one dependency, the official NATS chart (`nats`, exactly version 2.15.2, which runs NATS server 2.15.2) |
| [`helm/charts/nats-2.15.2.tgz`](helm/charts/) | The packaged dependency, committed, so the pipeline needs no network for it (its sha256 equals the digest in the NATS chart repository's index) |
| [`helm/values.yaml`](helm/values.yaml), [`values-dev.yaml`](helm/values-dev.yaml), [`values-prod.yaml`](helm/values-prod.yaml) | The settings, each with its reason in a comment |
| [`helm/values.schema.json`](helm/values.schema.json) | Refuses a value that would break the contract with the services (see below) |
| [`helm/templates/networkpolicy.yaml`](helm/templates/networkpolicy.yaml) | Who may connect |
| [`helm/templates/tests/smoke-test.yaml`](helm/templates/tests/smoke-test.yaml) | The `helm test` smoke test |
| [`compose.yaml`](compose.yaml) | The same NATS version for local runs |
| [`.github/`](.github/) | Pipeline (the shared workflow with `build-image: false`, plus the broker's own checks), CODEOWNERS, Dependabot |

## What the chart deploys

`helm template` with the prod values renders six objects: a ConfigMap (the server's configuration), a **StatefulSet**
with one replica and a 2 GiB PersistentVolumeClaim for the streams, two **Services** (`nats`, a ClusterIP, and the
headless `nats-headless` the StatefulSet needs), the **NetworkPolicy** and the smoke-test Pod (only created by
`helm test`). No Ingress, no LoadBalancer, no NodePort, no always-on nats-box, no metrics sidecar.

## The values in plain words

| Value | Setting | Why |
|---|---|---|
| Service name | `nats` (`nats.fullnameOverride`; the schema refuses any other name) | Every service chart already carries `NATS_URL=nats://nats:4222`; this keeps that true whatever the Helm release is called |
| Replicas | 1 | One small node (plan INF-03, ADR-039); a second replica would need a NATS cluster and three servers for a useful quorum |
| JetStream | on, file storage on a PersistentVolumeClaim of **2 GiB**, server limit **1 GiB** | Sizing below; the schema refuses JetStream off and a missing claim |
| Memory store | on, capped at **64 MiB** | No stream uses memory storage; a small cap keeps the server from reserving more |
| Memory | request 96 Mi, limit 256 Mi, soft Go limit 200 MiB | Measured below |
| CPU | request 50m, no limit | Like the service charts: a CPU limit only throttles |
| Client port | 4222 on the `nats` Service | The only port the services use |
| Monitoring port | 8222 on the `nats` Service, inside the cluster only (`/healthz`, `/varz`, `/jsz`) | The probes use it; a scraper can read it later |
| Exposure | ClusterIP only; the schema refuses a service type other than ClusterIP and the pipeline fails on any LoadBalancer, NodePort or host port in the render | The broker has no authentication yet (follow-up 1): it must never be reachable from outside |
| Cluster, leaf nodes, gateway, WebSocket, MQTT | off | One server; nothing else open |
| Config reloader sidecar | off; a changed configuration restarts the pod (checksum annotation) | With one server a reload saves nothing, and the sidecar is one more container to run and pin |
| Security | pod runs as user 1000 (the image itself runs as root), read-only root file system, no capabilities, no privilege escalation, default seccomp profile, no service account token | The server writes only to its volume and a pid file; proven by running exactly this below |
| Images | server by digest (`nats:2.15.2-alpine`, the version of the services' compose files), nats-box 0.20.0 by tag and digest | A tag can move; a digest cannot |
| PodDisruptionBudget | none | Below |
| NetworkPolicy | off by default, **on in the prod values** | Below |

### Why no PodDisruptionBudget

A PodDisruptionBudget limits how many pods of a set a voluntary disruption (a node drain, a cluster upgrade) may take
down at once. With one replica there are only two budgets: `maxUnavailable: 1` (the NATS chart's own default), which
lets the one pod be evicted, so it protects nothing, and `minAvailable: 1`, which forbids evicting the one pod, so
every node drain and AKS upgrade would hang on the broker until someone deletes the budget. Neither helps, so the
chart turns it off. If the broker ever runs three servers (follow-up 6), the budget comes back with them.

### The NetworkPolicy

Only on the client port 4222, only the Pods whose label `app.kubernetes.io/name` is one of `markets`, `trading`,
`market-maker`, `market-data`, `tenants`, `payments` and `audit` (the chart names, which their charts set as the Pod
label; `networkPolicy.clientApps`; read from each service's `helm/Chart.yaml` and `_helpers.tpl`) and the smoke-test
Pod of the release. Only on the monitoring port 8222, every Pod of the namespace. Nothing from another namespace, and
no egress rule (the server calls nothing). The services' own egress policies (off by default in their charts) already
select the broker by `app.kubernetes.io/name: nats`, which is the label this chart's Pods carry (checked in the
render). `audit` is not in the task list of services but its chart has `NATS_URL` and it consumes all four streams, so
it is admitted.

It does something only if the cluster has a network policy engine, which is chosen when the cluster is created (plan
section 9); without one the object is ignored, which is why the prod values switch it on: the broker's rule costs
nothing there and holds the day an engine exists. Whether `rso-cluster` has one is not known (follow-up 2).

## Storage and memory (the reasoning)

**What the services ask of the broker** (read from the code of the publishers and consumers, not guessed):

- JetStream, with **file storage**; each publisher creates its own stream on every connection (`MARKETS`, `TRADING`,
  `TENANTS`, `PAYMENTS`: four streams), subject `chance.<service>.>`, limits retention, **`max_age` 30 days by
  default** (each publisher's `STREAM_MAX_AGE_DAYS`, 1 to 365: long on purpose, so that a service started later still
  sees the older events; lowered again once every consumer is live), duplicate window 2 minutes, no byte or message limit. `Nats-Msg-Id` is the event id.
- Durable **pull consumers**, one per service and stream (about 15 in all: audit 4, market-data 3, trading 3,
  market-maker 2, payments 2, markets 1), delivery from the first message, explicit acknowledgement, a small limit of
  unacknowledged messages (market-data: 10), created by the consuming service. Their positions live in the broker's storage.
- The events are small: CloudEvents in JSON that carry ids, never names or e-mail addresses (DM-14).

**Storage: a 2 GiB claim, a 1 GiB server limit.** Measured here (2026-11-11, the chart's NATS image and
configuration, run in Docker as user 1000 with a read-only root and a 256 MiB limit; `nats bench` from nats-box):
200 000 messages of 800 bytes of payload took 160 MiB in the stream and 167 601 384 bytes on disk, which is **838
bytes a message**: the overhead of JetStream's records is about 5 %. A CloudEvent of these services is about 0.5 to 1
KB `[assumed: model knowledge; not measured on the real services]`, so **1 GiB holds about a million events**.
**For the streams' 30 days** (computed 2026-11-11 from the measurement above; the event sizes and rates are
assumptions): a generous event of 2 KB costs 2 195 bytes in the stream (2 000 x 838/800, plus about 100 bytes for the
`Nats-Msg-Id` header `[assumed]`), so the 1 GiB limit holds about 489 000 of them, 16 300 a day, 0.19 a second around the
clock, for the full 30 days before the limit is reached (with a 1 KB event: 935 700 events, 31 200 a day). A generous
30 days of a class demo is 210 000 events: three load tests of 100 events a second for 10 minutes (3 x 60 000) and 30 000
events of demos and ordinary use (about 6 000 market events, 20 000 trades, 4 000 tenant and payment events), 7 000 a
day on average. They take 461 MB (43 % of the limit) as 2 KB events and 241 MB (22 %) as 1 KB events. So the limit and
the claim stay as they are, 1 GiB and 2 GiB: 30 days fit with more than twice that volume to spare, and the claim is
as small as it can usefully be. A load test now stays in the stream for a month, not a week. Why the server limit is
half the claim: the limit is a safety valve, and the claim must also hold the file system's own space and the blocks
JetStream rewrites when it removes old messages. Tested (the same run with a 64 MiB limit and 160 MiB of events pushed
in): when the limit is reached the broker answers every further publish with `503 insufficient resources` (error code
10023), the stream keeps what it has, the disk use stays at the limit (67 110 149 bytes for 64 MiB) and the server stays
healthy. The publishers then fail and the events wait in the services' outboxes, which is the broker-outage behaviour
of the plan's failure table, instead of the volume filling up and the server stopping.

The volume scales with the streams' `max_age`: the numbers above hold for the default of 30 days. At 7 000 events a day
(the generous demo above) with 2 KB events the 1 GiB limit lasts about 70 days, so a `STREAM_MAX_AGE_DAYS` above about
60 needs the limit and the claim checked again (the setting goes up to 365). The memory figures below were measured
with 80 000 stored messages; the 210 000 events of the demo above are more, and the memory at that count was not
measured `[UNVERIFIED]`.

The claim uses the cluster's default storage class (AKS: an Azure disk). Azure bills a disk by size tier and the
smallest tier may be larger than 2 GiB, so the cost is read in the cost view (ADR-039 already says the same for the OS
disks), not from this number. The disk stays when the cluster is stopped, so the streams survive an idle stop.

**Memory: request 96 Mi, limit 256 Mi.** Measured in the same runs: the container used 5 to 9 MiB idle, and the server
process had **42 MiB resident with 80 000 stored messages** (peak 48 MiB). The request is the same 96 Mi the service charts ask for; the
limit is a ceiling that costs nothing until used, with the Go runtime's soft limit (`GOMEMLIMIT` 200 MiB) set below it
so it frees memory before the kernel kills the container. The 64 MiB memory store fits under the limit even when full.
At M1 the real requests of every component are measured (ADR-039); the broker is the smallest item of the stack.

## How the services connect

Every service reads **`NATS_URL=nats://nats:4222`** (already the default in each service chart's values) and connects
from its Pod in the same namespace. There is no user name and no password, no TLS: the broker is reachable inside the
cluster only, and the NetworkPolicy decides who. The services start without the broker (they connect on demand and
retry), so the deploy order does not matter; until the broker is up their events wait in the outboxes and consumers log
and retry.

| Stream | Published by | Read by |
|---|---|---|
| `MARKETS` | markets | trading, market-maker, market-data, audit |
| `TRADING` | trading | market-maker, market-data, payments, audit |
| `TENANTS` | tenants | markets, trading, payments, market-data, audit |
| `PAYMENTS` | payments | trading, audit |

(The "read by" column follows the services' READMEs and contracts at the time of writing; a service's own README is the
authority.) A stream that does not exist yet is created by its publisher on the first connection; a consumer of a
stream that does not exist yet logs and retries.

## Run locally

```bash
docker compose up -d --wait      # nats://localhost:4222, monitoring at http://localhost:8222/healthz
docker compose down -v           # stop and delete the stored streams
```

It is the same server version and flags as the `nats` service in the compose files of the services, so a service can
also use its own compose file; start one or the other (both publish 127.0.0.1:4222 and 8222).

## Checks

Run on 2026-11-11 with Helm 4.3.1 and kubeconform 0.8.0; nothing was installed into a cluster.

```bash
helm dependency list helm                                   # status "ok": the vendored chart matches Chart.yaml
helm lint helm --namespace prod --strict [-f helm/values-dev.yaml | -f helm/values-prod.yaml]
helm template broker helm --namespace prod -f helm/values-prod.yaml > render-prod.yaml
kubeconform -strict -summary -kubernetes-version 1.35.0 render-prod.yaml     # the same for the dev values
```

The pull-request check `chart-rules / test` ([`chart-ci.yml`](.github/workflows/chart-ci.yml)) runs exactly these, plus
actionlint, a check that the NATS chart is one exact version and vendored, and the rules of the broker on both
renders: a Service called `nats`, ClusterIP only (no LoadBalancer, NodePort or host port anywhere), JetStream file storage
on a claim, one replica, a `helm test` hook, and a NetworkPolicy in the prod render. The schema is tested with four
values it must refuse (another service name, a LoadBalancer, a misspelled key, JetStream off).

The runtime claims above (non-root, read-only root file system, `1Gi` and `64Mi` parsed by the server, health on the
probe paths, the smoke-test script passing twice in a row and leaving no stream behind, the full-store behaviour) were
checked by running the chart's exact image digest, configuration and security settings in Docker, and the smoke-test
script in nats-box with its own restricted settings. What was **not** run: anything in a cluster (Kubernetes' handling
of `fsGroup` on the claim, the probes, the NetworkPolicy, `helm test` itself).

## Deploy

The cluster work is approved when it is run (plan INF-03, ADR-039); the pipeline below has not run yet.

**The path** is the organization's shared workflow (ADR-051, `RSO-ekipa10/.github`, `service-ci-cd.yml`), like every
service, called by [`ci-cd.yml`](.github/workflows/ci-cd.yml) with the input `build-image: false`: the broker has no
code and no image, so the workflow skips the npm steps and the image build, push and digest, and passes the chart no
`image.repository`, `image.tag` or `image.digest` (this chart's schema refuses them on purpose). On a push to `main` it
runs the chart checks, logs in to Azure with OIDC, installs the chart with Helm 4 as release `broker` into the namespace
`prod` with `values-prod.yaml`, runs `helm test` (this chart's smoke test) and rolls the release back when it fails
(ADR-047, ADR-048). A manual run (input `sha`) redeploys or rolls back to the chart of an earlier commit of `main`. The
chart is ready for that: the NATS chart is vendored, so Helm needs no `helm dependency build` and no network; the
release name does not matter (the objects are called `nats`); no Secret is needed (the caller passes no `app-env`, and
no Docker Hub variable or token). The rules of the broker that the shared workflow does not know stay in
[`chart-ci.yml`](.github/workflows/chart-ci.yml), a second job `chart-rules` of the same caller (check `chart-rules / test`).

**After `org-github` is pushed (not done yet).** `build-image` is an input of the shared workflow that exists only in
the commit that adds it (local copy `org-github/`, branch `ci/shared-pipeline`, to be committed and pushed by a team
member and merged to `main` after review). Until then GitHub refuses `ci-cd.yml` ("Invalid input, build-image is not
defined in the referenced workflow") and no check of this repository runs. So:

1. Push `org-github` and merge it to `main` of `RSO-ekipa10/.github`.
2. The caller uses `@main`, like the services until the first release tag exists, so it needs no change once that
   commit is on `main`. When the services are pinned to a commit SHA of a release tag (`gh api
   repos/RSO-ekipa10/.github/commits/<tag> --jq .sha`), pin this caller the same way, to that commit or a later one
   (never to a commit before the input existed), and let Dependabot keep the pin current.
3. Open a pull request in this repository and check that `pipeline / test` and `chart-rules / test` pass, then add
   `chart-rules / test` to the required checks of the branch ruleset next to `pipeline / test` (organization settings
   are kept as code in the infrastructure repository).
4. The first deploy (a push to `main`) needs the organization variable `AZURE_CLIENT_ID`, the secrets
   `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID`, the environment `production` limited to `main` and the namespace
   `prod`, as for the services, and the approval the cluster work needs. In the infrastructure repository
   ("Adding the next service repository" in its README) that means:
   - one line `broker = "production"` in `local.deploy_repositories` (`envs/prod/azure.tf`): it creates the
     federated credential that lets this repository log in to Azure, and it makes `AZURE_CLIENT_ID` and the two
     `AZURE_*` secrets visible to this repository. Without the line `vars.AZURE_CLIENT_ID` is empty here and the
     deploy stops at "Check the inputs" ("azure-client-id is empty"); a variable set by hand instead fails at the
     Azure login, because no federated credential matches. Both fail before anything changes in the cluster;
   - the `production` environment (limited to `main`) and, optionally, a ruleset for this repository, in `github.tf`
     like `markets`. Until the ruleset exists nothing requires the checks before a merge, which is why the job
     `pipeline` in [`ci-cd.yml`](.github/workflows/ci-cd.yml) waits for `chart-rules` on a push to `main`.

By hand, with the same approval, the deploy is the two commands the workflow runs (`--rollback-on-failure` is the Helm 4
name of `--atomic`):

```bash
helm upgrade --install broker ./helm -n prod -f helm/values-prod.yaml --rollback-on-failure --wait --timeout 5m
helm test broker -n prod --timeout 2m --logs
```

The broker should be the first thing installed in the namespace after PostgreSQL, but nothing breaks if it is not: see
"How the services connect".

## Update the NATS chart

Dependabot is not set up for the dependency (a bump must also replace the packaged chart in `helm/charts/`, which only
`helm dependency update` does), so the chart is updated by hand when a new stable version appears: find it in the repository index
(`https://nats-io.github.io/k8s/helm/charts/index.yaml`, newest `nats` entry that is not a pre-release), set the exact
version in `helm/Chart.yaml`, run `helm dependency update helm` once, commit `helm/charts/` and `helm/Chart.lock`,
raise `appVersion` and the chart `version`, and move the image digest and tag in `helm/values.yaml` (and the compose
file) to the server version of the new chart. Read the chart's `UPGRADING.md` in the tarball first. The pipeline fails
when the vendored chart does not match `Chart.yaml` or the lock.

## Follow-ups and open questions

1. **Per-service NATS users (not built).** Proposal: one NATS user per service in the server's `authorization` block,
   with permissions limited to what the service does (publish on `chance.<its service>.>` and manage its own stream,
   read the streams it consumes, manage only its own durable consumers), the password in a Kubernetes Secret next to
   the service's `<service>-env`, `NATS_URL` unchanged (market-data's README says the URL carries no user name or
   password, so the client would take them from two new settings). Why not now: every one of the seven services needs a credential and a
   code change in its NATS connection, plus a Secret, its rotation and a coordinated rollout across seven
   repositories, none of which the broker repository can do alone. Until then the NetworkPolicy is the only control,
   and it is weaker than a credential: a Pod admitted by label can publish to any stream, forged events included (a
   label is set by whoever creates the Pod), and with no engine in the cluster there is no control at all. **Open
   question for the team:** accept that for the demo, or build the users after the first end-to-end run?
2. **Does `rso-cluster` have a network policy engine?** (Chosen at cluster creation, plan section 9.) Check at M1; if
   it has none, the policy here and in every service chart does nothing.
3. **Metrics.** The monitoring port serves `/varz` and `/jsz`; no one scrapes them. When a metrics stack exists, turn
   on the NATS chart's exporter (`nats.promExporter.enabled`, one more container).
4. **Deploy through the shared workflow** (see "Deploy"): built, not yet live. The input `build-image` of
   `service-ci-cd.yml` is written in the local copy `org-github/` and the caller file of this repository uses it; both
   take effect after `org-github` is pushed and merged (the steps are in "Deploy").
5. **One server is a single point of failure.** A restart of the pod (a node upgrade, a crash) is a short outage during
   which the services keep working and their events wait in the outboxes (the broker row of the plan's failure table). Losing the volume loses the streams and the consumer positions: the services create both again,
   market-data rebuilds from its own copy of the events (ADR-032), and the outboxes keep rows for as long as the streams keep messages (30 days by default), but a
   consumer without its own inbox history may see events again (every consumer deduplicates by event id, DM-06).
   There is no backup of the claim; add one only if the demo needs it.
6. **A high-availability demo** (plan INF-03, two nodes for one day) would need a three-server NATS cluster with
   replicated streams (`replicas: 3` in the services' stream settings, a code change) and the PodDisruptionBudget back;
   not planned.
7. **No TLS inside the cluster.** Fine for traffic that never leaves the cluster network; revisit with the users in
   follow-up 1.
