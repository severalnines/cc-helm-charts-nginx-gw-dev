# Maintainer scripts

Tooling for the third-party dependency mirror.
Upstream registries keep pruning artifacts we depend on (Oracle removed the
mysql-operator 2.0.21 chart *and* its images), so charts and images are cached
in our public Google Artifact Registry:

| What | Where |
|------|-------|
| Charts (OCI) | `oci://europe-docker.pkg.dev/severalnines-public/clustercontrol/helm-charts/<name>:<version>` |
| Images | `europe-docker.pkg.dev/severalnines-public/clustercontrol/mirror/<upstream-path>:<tag>` |

Pulls are anonymous (public repo); only pushing needs credentials.
Currently only `charts/clustercontrol` uses the mirror.

## mirror-to-gar.sh — seed / update the mirror

```bash
./scripts/mirror-to-gar.sh                  # mirror everything the chart needs
./scripts/mirror-to-gar.sh --dry-run        # show what would be mirrored
./scripts/mirror-to-gar.sh --seed-from DIR  # take chart tgz from DIR (versions pruned upstream)
```

No version list in the script — chart versions are read from `Chart.yaml`,
image tags from the rendered chart. Idempotent: anything already in GAR is
skipped, so the mirror keeps every version forever.
Rendered `tag@sha256` image refs are mirrored and checked by digest, so the
mirror must contain the exact manifest the chart asks Kubernetes to pull.

**Bumping a dependency:** edit the version in `Chart.yaml` → run the script →
verify with `build-charts.sh` → commit. If upstream already pruned the version,
recover the tgz from git history and pass `--seed-from`.

**Extending to another chart** (ccxdeps, observability, …): add its directory
to `CHART_DIRS` and extend the two upstream maps at the top as needed.

**Requirements:** `helm` >= 3.8, `yq` v4, `crane` (or `skopeo`). Push access =
Artifact Registry Writer on `severalnines-public/clustercontrol`:

```bash
ACCOUNT=<sa-with-writer-role>
gcloud auth print-access-token "$ACCOUNT" | helm registry login -u oauth2accesstoken --password-stdin europe-docker.pkg.dev
gcloud auth print-access-token "$ACCOUNT" | crane auth login europe-docker.pkg.dev -u oauth2accesstoken --password-stdin
```

Tokens expire after ~1 h. If `~/.docker/config.json` routes the registry
through the `gcloud` credential helper, crane uses the *active* gcloud account —
point `DOCKER_CONFIG` at a clean dir before `crane auth login` to avoid that.
Run large seeds from a machine with good bandwidth (CI / cloud VM); the full
image set is ~1 GB and weak uplinks stall painfully.

## build-charts.sh — pre-PR build check

```bash
./scripts/build-charts.sh                  # default: clustercontrol
./scripts/build-charts.sh ccx observability
```

Runs what CI runs: `helm lint` (lint.yaml) and `cr package` (release.yaml).
`cr` re-downloads dependencies from `Chart.yaml` repositories — vendored tgz
are ignored — so this verifies the GAR mirror serves every dependency.
Output lands in `.cr-release-packages/` (gitignored).
