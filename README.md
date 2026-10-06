# CyberArk Secure Workload Access (SWA) — Docker Lab (prod / dev)

Hands-on lab that runs the **SWA Server** and **SWA Agent** in plain containers (no Kubernetes) against a
CyberArk Secrets Manager SaaS tenant. Two isolated environments (`prod`, `dev`) show how a workload gets a
SPIFFE **JWT-SVID** without holding any secret, exchanges it for a Secrets Manager access token, and reads only
the secrets of its own environment.

| | |
|---|---|
| Author / contact | Huy Do — [hdo@paloaltonetworks.com](mailto:hdo@paloaltonetworks.com) |
| SWA version | 1.1.4 (release bundle `swa-release-v1.1.4.tgz`) |
| Runtime | `docker` CLI (Docker Engine, or podman with the `podman-docker` wrapper) |
| Purpose | Demo / learning lab — not hardened for production |

---

## 1. Components

Each environment is its own trust boundary: trust domain, server group, x509pop CA, SWA Server, node group and
authenticator. A workload container simulates one machine (agent + service account + client).

```text
                       CyberArk SaaS tenant
 +-------------------------------------------------------------------------------+
 |  Secrets Manager (SWA control plane + secrets)                                |
 |                                                                               |
 |   trust domain prod.swa.<domain>            trust domain dev.swa.<domain>     |
 |    +- server group sg-docker-prod            +- server group sg-docker-dev    |
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
 |                            |                             |                    |
 |   +------------------------+--+         +----------------+-----------+        |
 |   | swa-server-prod           |         | swa-server-dev             |        |
 |   |  api :18443  web :18080   |         |  api :18543  web :18180    |        |
 |   |  (signs JWT-SVIDs)        |         |  (signs JWT-SVIDs)         |        |
 |   +-------------^-------------+         +-------------^--------------+        |
 |                 | mTLS via host gateway               | mTLS via host gateway |
 |   +-------------+-------------+         +-------------+--------------+        |
 |   | wl-prod  (= one machine)  |         | wl-dev  (= one machine)    |        |
 |   |  swa-agent (root)         |         |  swa-agent (root)          |        |
 |   |   x509pop cert CN=ng-prod |         |   x509pop cert CN=ng-dev   |        |
 |   |   /run/swa-agent/api.sock |         |   /run/swa-agent/api.sock  |        |
 |   |  swa-demo-sa (nologin)    |         |  swa-demo-sa (nologin)     |        |
 |   |   swa-go-test, swa-test.sh|         |   swa-go-test, swa-test.sh |        |
 |   +---------------------------+         +----------------------------+        |
 |                                                                               |
 |   systemd timer swa-lab-token@<env>: re-signs the server JWT every 30 min     |
 +-------------------------------------------------------------------------------+
```

| | prod | dev |
|---|---|---|
| Trust domain | `prod.swa.<BASE_DOMAIN>` | `dev.swa.<BASE_DOMAIN>` |
| Server group / CA | `sg-docker-prod` / `state/prod/pki` | `sg-docker-dev` / `state/dev/pki` |
| Server container | `swa-server-prod` — API `:18443`, web `127.0.0.1:18080` | `swa-server-dev` — API `:18543`, web `127.0.0.1:18180` |
| Server JWT (to the tenant) | iss `https://swa-server-prod.<BASE_DOMAIN>`, sub `swa-server-prod` | iss `https://swa-server-dev.<BASE_DOMAIN>`, sub `swa-server-dev` |
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

### 2.1 Server bootstrap (once per start, then every `syncInterval`)

```text
 mint-token.sh / timer         swa-server-<env>                       Tenant
 ---------------------         ----------------                       ------
 sign RS256 JWT (state/<env>/signer/jwt.key)
   --> state/<env>/tokens/swa-token
                               reads token (tokenPath)
                               POST authn-jwt/swa-server-<env>-xxxx --> verifies against registered JWKS
                                                                   <-- access token
                               creates internal CA, uploads keys --> trust domain JWKS / CA bundle
                               pulls node groups + policies      <-- (sync every 5m)
```

### 2.2 Agent attestation (container start)

```text
 swa-agent (wl-<env>)                                  swa-server-<env>          Tenant
 --------------------                                  ----------------          ------
 GET .well-known/ca-bundles  ------------------------------------------------->  trust bundle
 connect host-gw:<API_PORT> (TLS, server cert checked against bundle)
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

The lab needs three things from CyberArk / Idira plus a Linux host. `./00-check-prereq.sh` verifies all of them
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
  and extract it to `SWA_BUNDLE_DIR` (default `/opt/download/swa`):

  ```bash
  mkdir -p /opt/download/swa
  tar -xzf swa-release-v1.1.4.tgz -C /opt/download/swa
  ```

- The scripts take everything from there:
  `binaries/swa-agent_<ver>_linux_amd64/swa-agent` (copied into the workload image) and
  `container-images/swa-server-<ver>-amd64.tar` (loaded with `docker load`).
  The image `docker.io/library/swa-server` is **not** on Docker Hub; containers always run with `--pull=never`.

### 3.4 Lab host

- Linux x86_64, **root**, systemd, `docker` (Docker Engine, or podman + podman-docker), `curl`, `jq`, `openssl`,
  `python3`, GNU `coreutils`/`date`, `git`. Tested on RHEL 9 (podman 4.6) and Ubuntu 24.04 (Docker 29).
- Outbound HTTPS to the tenant (`*.secretsmgr.cyberark.cloud`, `*.id.cyberark.cloud`) and to `docker.io`
  (base images `alpine:3.20`, `golang:1.24`).
- Firewall: containers must reach the server ports on the host gateway (with firewalld put `docker0`/`podman0`
  in the `trusted` or `docker` zone; with UFW on Ubuntu run
  `ufw allow in on docker0 to any port 18443,18543 proto tcp`). Ports 18443/18543 do not need to be open to the outside.

## 4. Files

| Script | Purpose |
|---|---|
| `config.env.example` → `config.env` | Lab settings (tenant, domain, safe, secrets, bundle). `config.env` is git-ignored |
| `lib.sh` | Shared helpers: `env_load`, API calls, conjur policy loads, host gateway detection |
| `00-check-prereq.sh` | Checks config, tools, bundle, network, ports, conjur login, token. Reports only, never installs |
| `01-get-token.sh` | Admin login (Identity + MFA, push approval supported) → `./.token` (mode 600) |
| `10-tenant-setup.sh <env>` | x509pop CA → trust domain → server group → server signing key + component → node group (policy) → `authn-jwt/swa-<env>` |
| `20-server-run.sh <env>` | Mint server JWT, write `bootstrapConfig.yaml`, run `swa-server-<env>` |
| `21-token-timer.sh` | Install systemd timer `swa-lab-token@<env>` (re-mint server JWT every 30 min) |
| `mint-token.sh <env>` | Sign the server JWT (called by 20, 51 and the timer) |
| `30-build-image.sh` | Build `localhost/swa-lab-workload:1.0` (alpine + swa-agent + swa-go-test + swa-test.sh) |
| `31-workload-run.sh <env>` | Issue agent x509pop cert (CN = node group) and run `wl-<env>` |
| `40-grant.sh <env>` | First fetch (tenant creates the workload host) → annotation → group `apps` → `!permit` on the env secrets |
| `51-lab-start.sh [env]` | Start server + workload + timer (fresh server JWT) |
| `52-lab-stop.sh [env]` | Stop containers and timer; deletes nothing |
| `53-lab-status.sh [env]` | Containers, readyz, server JWT expiry, timer, JWT-SVID + access token check |
| `54-show-policies.sh [env]` | Show trust domain, server group/CA, components, node group template and policies |
| `55-full-test.sh` | 8-case allow/deny test matrix |
| `56-script-test.sh [env]` | Run the step-by-step demo `swa-test.sh` inside `wl-<env>` |
| `99-cleanup.sh [local\|tenant\|all]` | Remove containers/timer/image and/or every tenant object of this lab |
| `swa-go-test/` | Go client source + `build.sh` (builds in `golang:1.24`; `VERSION=x.y ./build.sh`) |
| `image/` | `Dockerfile`, `entrypoint.sh` (agent restart loop), `swa-test.sh` (demo script) |

Runtime data lives in `state/<env>/` (CA, signing key, server config, tokens, agent cert) — git-ignored.

## 5. Build the lab

```bash
# 1. Configure
cp config.env.example config.env && chmod 600 config.env
vi config.env                         # fill every <placeholder> in the EDIT sections

# 2. Check the host (fix every MISS, nothing is installed for you)
./00-check-prereq.sh

# 3. Log in
./01-get-token.sh                     # admin token -> ./.token (re-run when it expires)
conjur login                          # conjur CLI, used by 40/99 for policy loads

# 4. Tenant objects (builds swa-go-test first if needed; pins its sha256 in the policy)
./10-tenant-setup.sh prod
./10-tenant-setup.sh dev

# 5. SWA Servers + JWT refresh timer
./20-server-run.sh prod
./20-server-run.sh dev
./21-token-timer.sh

# 6. Workload image and containers
./30-build-image.sh
./31-workload-run.sh prod
./31-workload-run.sh dev

# 7. Authorise the workloads on their own secrets
./40-grant.sh prod
./40-grant.sh dev

# 8. Verify
./53-lab-status.sh
./55-full-test.sh
```

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
| wl-prod / swa-demo-sa / `swa-agent` CLI | DENY | no matching registration policy — only meaningful after removing policy element 2 |
| wl-prod / swa-demo-sa / client copy with 1 byte changed | DENY | no matching registration policy (sha256) |

## 7. Operations and notes

- **Rebuilding `swa-go-test` changes its hash.** Re-run `./10-tenant-setup.sh <env>` (it PATCHes the policy),
  `./30-build-image.sh`, `./31-workload-run.sh <env>`, then restart the server or wait for the 5 min sync.
- **Server restart** regenerates the server's internal CA; agents re-establish trust by themselves
  (the entrypoint restarts the agent if it exits).
- **Server authentication** outside Kubernetes uses a self-signed RS256 JWT registered with a JWKS; if the lab
  was stopped longer than the JWT lifetime, `51-lab-start.sh` mints a new one first.
- **Host gateway**: auto-detected (Docker `bridge` gateway, else podman network gateway); set `HOST_GW` to override.
- **Secret permissions** are granted per variable with `!permit` in `SAFE_POLICY`, not via the safe's consumers group.
- **Several lab hosts on one tenant**: set a different `LAB_ID` in each host's `config.env` (e.g. `lab2`).
  Trust domains become `prod.lab2.swa.<BASE_DOMAIN>` and workload authenticators `authn-jwt/swa-prod-lab2`, so
  setup, tests and cleanup on one host never touch the other. Leave it empty for a single lab.
- **Move the lab to another host**: copy this directory (without `state/`, `.token`, `config.env`), extract the bundle,
  create `config.env` and follow section 5. The client is rebuilt from source, so its hash may differ — the policy
  always uses the hash of the binary just built.
- **Security limits (demo)**: CA and signing keys sit in `state/` on the host; root on a node can alter binaries
  (a new hash is denied unless the tenant policy is changed too); policy element 2 lets any script of
  `swa-demo-sa` that calls the agent CLI get a JWT — remove it after the demo.

## 8. Clean up

```bash
./99-cleanup.sh local     # containers, timers, workload image
./99-cleanup.sh tenant    # permissions, authenticators, node groups, components, server groups, trust domains
./99-cleanup.sh all       # both + shred keys and remove state/
```
