# CyberArk Secure Workload Access (SWA) — k3s-in-Docker Lab (prod / dev)

Hands-on lab that runs the **SWA Server** with the vendor helm chart on a single-node **k3s cluster inside a Docker
container**, and the **SWA Agent** + workload in plain Docker containers (one per environment, simulating a machine),
against a CyberArk Secrets Manager SaaS tenant. Two isolated environments (`prod`, `dev`) show how a workload gets a
SPIFFE **JWT-SVID** without holding any secret, exchanges it for a Secrets Manager access token, and reads only
the secrets of its own environment.

How SWA works (components and the four flows): **https://huydd79.github.io/test-swa-docker/**

| | |
|---|---|
| Author / contact | Huy Do — [hdo@paloaltonetworks.com](mailto:hdo@paloaltonetworks.com) |
| SWA version | 1.1.4 (release bundle `swa-release-v1.1.4.tgz`) |
| Runtime | Docker (Docker Desktop on macOS, or Docker Engine on Linux) + `kubectl` + `helm`; k3s `v1.35` in container `swa-k3s` |
| Purpose | Demo / learning lab — not hardened for production |

---

## 1. Components

Each environment is its own trust boundary: trust domain, server group, x509pop CA, SWA Server, node group and
authenticator. Both SWA Servers run in one k3s cluster (namespaces `swa-prod`, `swa-dev`); a workload container
outside k3s simulates one machine (agent + service account + client).

```text
                       CyberArk SaaS tenant
 +-------------------------------------------------------------------------------+
 |  Secrets Manager (SWA control plane + secrets)                                |
 |                                                                               |
 |   trust domain prod.swa.<domain>            trust domain dev.swa.<domain>     |
 |    +- server group sg-k3s-prod               +- server group sg-k3s-dev       |
 |    |   +- x509pop CA (state/prod/pki)        |   +- x509pop CA (state/dev/pki)|
 |    |   +- component swa-server-prod          |   +- component swa-server-dev  |
 |    |   +- node group ng-prod (policy)        |   +- node group ng-dev (policy)|
 |    +- authn-jwt/swa-prod                     +- authn-jwt/swa-dev             |
 |                                                                               |
 |   SAFE_POLICY (e.g. data/vault/<safe>)  <-- !permit per variable per host     |
 |                                                                               |
 |  Identity (admin login + MFA -> .token, used by the setup scripts)            |
 +----------------------------^-----------------------------^--------------------+
                              | HTTPS 443                   | HTTPS 443
 +----------------------------|-----------------------------|--------------------+
 |  Docker host               |                             |                    |
 |   +------------------------|-----------------------------|----------------+   |
 |   | container swa-k3s (k3s v1.35, privileged, volume swa-k3s)             |   |
 |   |  +---------------------+-----+       +---------------+------------+   |   |
 |   |  | ns swa-prod               |       | ns swa-dev                 |   |   |
 |   |  |  deploy swa-server (helm) |       |  deploy swa-server (helm)  |   |   |
 |   |  |  SA token aud=conjur      |       |  SA token aud=conjur       |   |   |
 |   |  |  svc NodePort 30843       |       |  svc NodePort 30943        |   |   |
 |   |  +-------------^-------------+       +-------------^--------------+   |   |
 |   +----------------|------------------------------------|-----------------+   |
 |        published host :18443 (Mac: 127.0.0.1:28443)     host :18543 (28543)   |
 |                    | mTLS via host gateway              | mTLS via host gateway|
 |   +----------------+----------+         +---------------+------------+        |
 |   | wl-prod  (= one machine)  |         | wl-dev  (= one machine)    |        |
 |   |  swa-agent (root)         |         |  swa-agent (root)          |        |
 |   |   x509pop cert CN=ng-prod |         |   x509pop cert CN=ng-dev   |        |
 |   |   /run/swa-agent/api.sock |         |   /run/swa-agent/api.sock  |        |
 |   |  swa-demo-sa (nologin)    |         |  swa-demo-sa (nologin)     |        |
 |   |   swa-go-test, swa-test.sh|         |   swa-go-test, swa-test.sh |        |
 |   +---------------------------+         +----------------------------+        |
 +-------------------------------------------------------------------------------+
```

| | prod | dev |
|---|---|---|
| Trust domain | `prod.swa.<BASE_DOMAIN>` | `dev.swa.<BASE_DOMAIN>` |
| Server group / CA | `sg-k3s-prod` / `state/prod/pki` | `sg-k3s-dev` / `state/dev/pki` |
| SWA Server (k3s) | ns `swa-prod`, component `swa-server-prod`, NodePort 30843 → host `:18443` | ns `swa-dev`, component `swa-server-dev`, NodePort 30943 → host `:18543` |
| Server JWT (to the tenant) | k3s SA token: iss `https://kubernetes.default.svc.cluster.local`, sub `system:serviceaccount:swa-prod:swa-server` | same iss, sub `system:serviceaccount:swa-dev:swa-server` |
| Node group (= CN of agent cert) | `ng-prod` | `ng-dev` |
| Workload container | `wl-prod` | `wl-dev` |
| SPIFFE ID | `spiffe://prod.swa.<BASE_DOMAIN>/ng-prod/workload/swa-demo-sa` | `spiffe://dev.swa.<BASE_DOMAIN>/ng-dev/workload/swa-demo-sa` |
| Workload authenticator | `authn-jwt/swa-prod` | `authn-jwt/swa-dev` |
| Secrets allowed | `PROD_SECRETS` | `DEV_SECRETS` |

Node group registration policy (both environments; array elements are OR'ed):

```text
1. unix.user == "swa-demo-sa" && unix.sha256 == "<sha256 of swa-go-test>"
2. unix.user == "swa-demo-sa" && unix.path  == "/opt/swa/bin/swa-agent"   # only for the swa-test.sh demo; remove afterwards
```

Note: the tenant appends a short id to the server authenticator name (e.g. `swa-server-prod-01a111da`). It is the
first 8 hex characters of the component UUID (UUIDv7) generated at registration; the scripts read the full URL from
the API response into `state/<env>/authn_id`, so you never type it.

## 2. Communication flows

### 2.1 Server bootstrap (once per start, then every `syncInterval` = 15m in the chart)

```text
 k3s (kubelet)                 swa-server (ns swa-<env>)              Tenant
 -------------                 -------------------------              ------
 projected SA token aud=conjur,
 1h, auto-rotated
   --> /var/run/secrets/tokens/swa-token
                               reads token (tokenPath)
                               POST authn-jwt/swa-server-<env>-xxxx --> verifies against the k3s JWKS
                                                                        registered inline by 10-tenant-setup.sh
                                                                   <-- access token
                               creates internal CA, uploads keys --> trust domain JWKS / CA bundle
                               pulls node groups + policies      <-- (sync every 15m)
```

### 2.2 Agent attestation (container start)

```text
 swa-agent (wl-<env>)                                  swa-server-<env>          Tenant
 --------------------                                  ----------------          ------
 GET .well-known/ca-bundles  ------------------------------------------------->  trust bundle
 connect host-gw:<API_PORT> -> k3s NodePort (TLS, server cert checked against bundle)
 x509pop: present cert CN=<node group> + prove key --> verify chain to the
                                                       server group CA, map CN
                                                       to node group
                                                   <-- agent SVID (mTLS from now on)
```

### 2.3 Workload gets a secret

```text
 swa-go-test (uid swa-demo-sa)      swa-agent              swa-server            Secrets Manager
 -----------------------------      ---------              ----------            ---------------
 1 FetchJWTSVID(aud=conjur) ------> socket peer -> PID
                                    /proc: user, uid, gid,
                                    path, sha256
                                    --- attributes -----> evaluate node group
                                                          CEL policy
                                    <-- JWT-SVID (RS512, 5 min) or
                                        "no matching registration policy"
   <-- JWT-SVID
 2 POST authn-jwt/swa-<env>/conjur/host%2F...%2F<SPIFFE ID>/authenticate (jwt=...) ------>
                                                       verify JWT with trust domain JWKS,
                                                       sub == host annotation, host in group apps
   <------------------------------------------------------------------------ access token
 3 GET secrets/conjur/variable/<SAFE_POLICY>/<account>/password ------------>
                                                       !permit read,execute on this host?
   <------------------------------------------------------------------------ value | 404
```

The workload holds no credential. Identity = which process (user + binary hash) talks to the local agent on an
attested node.

## 3. Prerequisites

The lab needs three things from CyberArk / Idira plus a Docker host (macOS or Linux). `./00-check-prereq.sh` verifies all of them
(it reports only and never installs anything).

### 3.1 Idira tenant with Secrets Manager

- An Idira (CyberArk Identity Security Platform) tenant with **Secrets Manager SaaS** and **Secure Workload Access**
  enabled: `https://<subdomain>.secretsmgr.cyberark.cloud` and its Identity tenant `https://<tenant-id>.id.cyberark.cloud`.
- An admin user (Identity login with MFA) who can manage SWA trust domains / server groups / node groups and load
  Secrets Manager policies (e.g. member of the Secrets Manager admin group).
- A safe synced to Secrets Manager (`data/vault/<safe>`) holding the test accounts used as prod and dev secrets
  (`<account>/username`, `<account>/password`). Use test accounts only — the demo can print their values.
- Set `SWA_API_BASE`, `IDENTITY_URL`, `SM_USER`, `SAFE_POLICY`, `PROD_SECRETS`, `DEV_SECRETS` in `config.env`.

### 3.2 Secrets Manager CLI (`conjur`)

- Install the Idira Secrets Manager CLI (`conjur`, v9.x) from the CyberArk / Idira download portal, e.g.
  `install -m 0755 conjur /usr/local/bin/conjur`.
- Initialise it for the SaaS tenant and log in (used by `10`, `40`, `99` for policy loads):

  ```bash
  conjur init      # Secrets Manager SaaS, URL https://<subdomain>.secretsmgr.cyberark.cloud
  conjur login     # admin user + MFA
  conjur whoami
  ```

### 3.3 SWA release bundle

- Download `swa-release-v<ver>.tgz` (this lab is tested with **1.1.4**) from the CyberArk / Idira download portal
  and extract it to `SWA_BUNDLE_DIR` (default `./release`, git-ignored):

  ```bash
  mkdir -p release && tar -xzf swa-release-v1.1.4.tgz -C release
  ```

- The scripts take everything from there:
  `binaries/swa-agent_<ver>_linux_<arch>/swa-agent` (copied into the workload image),
  `container-images/swa-server-<ver>-<amd64|arm64v8>.tar` (imported into k3s containerd) and
  `helm/swa-server-0.1.0.tgz` (vendor chart). The arch follows `uname -m`.
  The image `docker.io/library/swa-server` is **not** on Docker Hub; the pod uses `imagePullPolicy: Never`.

### 3.4 Lab host

- **macOS** (Apple silicon or Intel) with Docker Desktop, or **Linux** with Docker Engine (podman untested for the
  privileged k3s container). Tools: `docker`, `kubectl`, `helm`, `curl`, `jq`, `openssl`, `python3`, `conjur`.
  Stock macOS `/bin/bash` 3.2 is fine. No root needed on macOS.
- Docker resources: k3s uses about 0.6 GB RAM, plus two small workload containers.
- Outbound HTTPS to the tenant (`*.secretsmgr.cyberark.cloud`, `*.id.cyberark.cloud`) and to `docker.io`
  (`rancher/k3s`, `busybox` for the chart init container, `alpine:3.20`, `golang:1.24`).
- Ports: `127.0.0.1:16443` (kube-apiserver for kubectl/helm) and the server API ports (default 18443/18543).
  On macOS set `API_BIND="127.0.0.1"` (agents use `host.docker.internal`) and move the ports if taken, e.g.
  `PROD_API_PORT=28443` (VS Code may hold 18443). The port mappings are fixed when `05-k3s-up.sh` creates the container.
- Linux firewall: containers must reach the server ports on the host gateway (firewalld: put `docker0` in the
  `trusted` or `docker` zone; UFW: `ufw allow in on docker0 to any port 18443,18543 proto tcp`).

## 4. Files

| Script | Purpose |
|---|---|
| `config.env.example` → `config.env` | Lab settings (tenant, domain, safe, secrets, bundle). `config.env` is git-ignored |
| `lib.sh` | Shared helpers: `env_load`, API calls, conjur policy loads, k3s helpers + image import, host gateway detection |
| `00-check-prereq.sh` | Checks config, tools, bundle, network, ports, conjur login, token. Reports only, never installs |
| `01-get-token.sh` | Admin login (Identity + MFA, push approval supported) → `./.token` (mode 600) |
| `05-k3s-up.sh` | Run k3s container `swa-k3s` (volume `swa-k3s`, port mappings), write `state/k3s.kubeconfig`, import the server image |
| `10-tenant-setup.sh <env>` | x509pop CA → trust domain → server group → server component (k3s JWKS inline; re-registers if the k3s key changed) → node group (policy) → `authn-jwt/swa-<env>` |
| `20-server-install.sh <env>` | `helm upgrade --install` the vendor chart in ns `swa-<env>`, pin NodePort, wait Ready |
| `30-build-image.sh` | Build `localhost/swa-lab-workload:1.0` (alpine + swa-agent + swa-go-test + swa-test.sh) |
| `31-workload-run.sh <env>` | Issue agent x509pop cert (CN = node group) and run `wl-<env>` |
| `40-grant.sh <env>` | First fetch (tenant creates the workload host) → annotation → group `apps` → `!permit` on the env secrets |
| `51-lab-start.sh [env]` | Start k3s, scale swa-server to 1 and wait Ready, start the workload |
| `52-lab-stop.sh [env]` | With env: stop `wl-<env>` + scale its server to 0. Without: stop workloads and the k3s container. Deletes nothing |
| `53-lab-status.sh [env]` | k3s node, server deployments, workload containers, JWT-SVID + access token check |
| `54-show-policies.sh [env]` | Show trust domain, server group/CA, components, node group template and policies |
| `55-full-test.sh` | 9-case allow/deny test matrix |
| `56-script-test.sh [env]` | Run the step-by-step demo `swa-test.sh` inside `wl-<env>` |
| `99-cleanup.sh [local\|tenant\|all]` | Remove workload containers, k3s container + volume, image and/or every tenant object of this lab |
| `swa-go-test/` | Go client source + `build.sh` (builds in `golang:1.24`; `VERSION=x.y ./build.sh`) |
| `image/` | `Dockerfile`, `entrypoint.sh` (agent restart loop), `swa-test.sh` (demo script) |

Runtime data lives in `state/` (`k3s.kubeconfig`; per env: x509pop CA, registered JWKS, `authn_id`, agent cert) — git-ignored.
Cluster data (incl. the service-account signing key) lives in the docker volume `swa-k3s`.

## 5. Build the lab

### 5.1 Prepare (interactive, once per host)

Steps 1-3 need your input (editing, password, MFA), so run them one by one:

```bash
# 1. Configure: fill every <placeholder> in the EDIT sections (set LAB_ID if another lab host uses the same tenant)
cp config.env.example config.env && chmod 600 config.env
vi config.env

# 2. Check the host: fix every MISS and rerun until "All required items OK" (nothing is installed for you)
./00-check-prereq.sh

# 3. Log in (admin user + MFA)
conjur init                           # first time only: Secrets Manager SaaS, https://<subdomain>.secretsmgr.cyberark.cloud
conjur login                          # conjur CLI session, used by 10/40/99 for policy loads
./01-get-token.sh                     # admin API token -> ./.token (short-lived: run it right before 5.2)
```

### 5.2 Deploy and verify (copy and paste)

Non-interactive; the whole block runs in a few minutes (the first run also pulls `rancher/k3s`, `busybox`, `golang` and `alpine`).
It stops at the first failing step — fix it, then paste the block again (every step is safe to rerun).

```bash
./05-k3s-up.sh \
&& ./10-tenant-setup.sh prod && ./10-tenant-setup.sh dev \
&& ./20-server-install.sh prod && ./20-server-install.sh dev \
&& ./30-build-image.sh && ./31-workload-run.sh prod && ./31-workload-run.sh dev \
&& ./40-grant.sh prod && ./40-grant.sh dev \
&& ./53-lab-status.sh && ./55-full-test.sh
```

| Step | What it does |
|---|---|
| `05-k3s-up.sh` | k3s cluster in Docker + SWA Server image import |
| `10-tenant-setup.sh <env>` | Tenant objects: CA, trust domain, server group, server component (k3s JWKS), node group (pins the `swa-go-test` sha256, building it first if needed), `authn-jwt/swa-<env>` |
| `20-server-install.sh <env>` | SWA Server via helm in ns `swa-<env>` |
| `30-build-image.sh`, `31-workload-run.sh <env>` | Workload image, agent certificate and workload containers |
| `40-grant.sh <env>` | Workload host annotation, group `apps`, permissions on the environment's own secrets |
| `53-lab-status.sh`, `55-full-test.sh` | Verify: every environment gets a JWT-SVID and an access token; matrix shows 9/9 PASS |

## 6. Run the demo

```bash
./51-lab-start.sh                     # if the lab was stopped
./54-show-policies.sh                 # what the tenant enforces per environment
./56-script-test.sh prod              # step by step: caller, JWT-SVID, JWKS, authn-jwt, secret read
SHOW_JWT=1 ./56-script-test.sh dev    # also print the raw JWT-SVID (bearer token, ~5 min)
SHOW=1 ./56-script-test.sh prod       # print secret values in full (masked by default)
./55-full-test.sh                     # allow/deny matrix
./52-lab-stop.sh                      # stop when not in use
```

Manual calls inside a workload container:

```bash
docker exec --user swa-demo-sa wl-prod swa-go-test -sm "$SWA_API_BASE/api" -authn swa-prod <SAFE_POLICY>/<account>/username
docker exec --user swa-demo-sa wl-prod /opt/swa/bin/swa-agent api fetch jwt -a conjur -s /run/swa-agent/api.sock
```

Expected test matrix (`55-full-test.sh`):

| Case | Expected | Reason when denied |
|---|---|---|
| wl-prod / swa-demo-sa / client / prod secret | OK | |
| wl-prod / swa-demo-sa / client / dev secret | DENY | HTTP 404 — no permission on the variable |
| wl-dev / swa-demo-sa / client / dev secret | OK | |
| wl-dev / swa-demo-sa / client / prod secret | DENY | HTTP 404 |
| prod JWT sent to `authn-jwt/swa-dev` | DENY | authenticate 401 — other trust domain/issuer |
| wl-prod / root / client | DENY | no matching registration policy (user) |
| wl-prod / swa-demo-sa / `swa-agent` CLI | OK | allowed by policy element 2 (demo); DENY once element 2 is removed |
| wl-prod / root / `swa-agent` CLI | DENY | no matching registration policy (user) |
| wl-prod / swa-demo-sa / client copy with 1 byte changed | DENY | no matching registration policy (sha256) |

## 7. Operations and notes

- **Rebuilding `swa-go-test` changes its hash.** Re-run `./10-tenant-setup.sh <env>` (it PATCHes the policy),
  `./30-build-image.sh`, `./31-workload-run.sh <env>` (10 restarts the server deployment so the policy applies at once).
- **Server restart** regenerates the server's internal CA; agents re-establish trust by themselves
  (the entrypoint restarts the agent if it exits).
- **Server authentication**: the server presents its projected k3s service-account token (aud `conjur`, 1 h,
  rotated by k3s). The tenant cannot reach the k3s API, so `10` registers the k3s JWKS inline. The signing key is
  kept in the `swa-k3s` volume; if the volume is recreated (`99-cleanup.sh local`), rerun `10` (re-registers the
  component, new `authn_id`) and `20`.
- **kubectl / helm**: `export KUBECONFIG=$PWD/state/k3s.kubeconfig` (config.env does this for the scripts), e.g.
  `kubectl -n swa-prod logs deploy/swa-server`. Or `docker exec swa-k3s kubectl ...`.
- **Host gateway**: auto-detected (Docker `bridge` gateway, else podman network gateway); set `HOST_GW` to override.
- **Secret permissions** are granted per variable with `!permit` in `SAFE_POLICY`, not via the safe's consumers group.
- **Several lab hosts on one tenant**: set a different `LAB_ID` in each host's `config.env` (e.g. `lab2`).
  Trust domains become `prod.lab2.swa.<BASE_DOMAIN>` and workload authenticators `authn-jwt/swa-prod-lab2`, so
  setup, tests and cleanup on one host never touch the other. Leave it empty for a single lab.
- **Move the lab to another host**: copy this directory (without `state/`, `.token`, `config.env`), extract the bundle,
  create `config.env` and follow section 5. The client is rebuilt from source, so its hash may differ — the policy
  always uses the hash of the binary just built.
- **Security limits (demo)**: x509pop CA keys sit in `state/`, the k3s signing key in the `swa-k3s` volume, and
  k3s runs as a privileged container; root on a node can alter binaries
  (a new hash is denied unless the tenant policy is changed too); policy element 2 lets any script of
  `swa-demo-sa` that calls the agent CLI get a JWT — remove it after the demo.

## 8. Clean up

```bash
./99-cleanup.sh local     # workload containers, k3s container + volume, workload image
./99-cleanup.sh tenant    # permissions, authenticators, node groups, components, server groups, trust domains
./99-cleanup.sh all       # both + shred keys and remove state/
```
