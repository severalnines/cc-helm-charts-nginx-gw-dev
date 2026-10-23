# 5. Day-2 operations

[← Inside the chart](04-inside-the-chart.md) · Next: [Troubleshooting →](06-troubleshooting.md)

Installing is day 1. Everything after — looking, changing, upgrading, undoing, rebuilding — is
day 2. Commands run on the node (`ssh` in; reference lab: `vagrant ssh pupnode100`). "Re-run the
install script" means running it again with the same settings you used the first time:

```bash
sudo env CC_FQDN=cc.example.com bash docs/scripts/install_clustercontrol_kubeadm-cc-helm-dev.sh
# reference lab, on the KVM host: vagrant provision pupnode100
```

To save typing:

```bash
alias k='kubectl -n clustercontrol'
alias h='helm -n clustercontrol'
```

---

## First login

On first visit ClusterControl v2 asks you to **create the first admin user** — `config.js` is
rendered with `USER_REGISTRATION: 1`. There is no pre-made admin password to look up.

The chart does generate two passwords, both kept stable across upgrades:

```bash
# cmon RPC user (ccrpc) — what the UI and s9s CLI use to talk to cmon
k get secret cmon-credentials -o jsonpath='{.data.cmon-password}' | base64 -d; echo

# setup key, passed to the UI as INITIAL_PASSWORD in config.js
k get secret cmon-ccsetup -o jsonpath='{.data.ccsetup-password}' | base64 -d; echo
```

The install script's closing banner prints these same two commands.

## Looking around

```bash
h list                                   # release, revision, chart version, status
h status clustercontrol                  # plus NOTES.txt
h history clustercontrol                 # every install/upgrade/rollback
h get values clustercontrol              # values YOU supplied (fqdn, backendTLS…)
h get values clustercontrol --all        # merged with defaults
h get manifest clustercontrol | less     # the YAML actually applied

k get pods -o wide
k get pvc
k get gateway,httproute,tcproute,backendtlspolicy
k get events --sort-by=.lastTimestamp | tail -30

k logs cmon-master-0 -c cmon-master --tail=100     # pick a container with -c
k logs cmon-master-0 -c ccmgr -f
k exec -it cmon-master-0 -c cmon-master -- bash     # a shell inside cmon
k exec cmon-master-0 -c cmon-master -- s9s cluster --list --long
```

`kubectl get pods` shows `READY 8/8`-style counts for `cmon-master-0` because the pod has that many
containers; any number short of the total tells you which to inspect with `-c`.

## Changing a value

The pattern is always **upgrade with the new value, keeping the old ones**:

```bash
h upgrade clustercontrol s9s-ngf/clustercontrol --devel --version 0.1.2 \
  --reuse-values \
  --no-hooks \
  --set cmon.sshKeysSecretName=my-ssh-keys
```

* `--reuse-values` starts from the previous release's values. Without it, everything you set before
  (`fqdn`, backend TLS) silently reverts to the defaults.
* `--no-hooks` avoids NGF's cert-generator hanging on upgrade (see
  [step 13](03-install-script-walkthrough.md#13-backend-tls--cc_enable_backend_tls)). Alternatively
  use [scripts/install-clustercontrol.sh](../../scripts/install-clustercontrol.sh), which creates
  the missing RBAC and runs hooks normally.
* Pin `--version`. Otherwise "change one value" also becomes "upgrade the chart".

For more than a couple of values, keep them in a file and pass `-f`:

```yaml
# my-values.yaml
fqdn: cc.example.com
cmon:
  sshKeysSecretName: my-ssh-keys
  gateway:
    backendTLS:
      enabled: true
      caCertificateRef: cmon-backend-ca
```

```bash
h upgrade clustercontrol s9s-ngf/clustercontrol --devel --version 0.1.2 --no-hooks -f my-values.yaml
```

Preview any upgrade first with `--dry-run` (or `helm diff`, if you install that plugin).

## Upgrading the chart

```bash
helm repo update
helm search repo s9s-ngf/clustercontrol --devel --versions
h upgrade clustercontrol s9s-ngf/clustercontrol --devel --version <new> --reuse-values --no-hooks
```

If the new chart moves to a newer NGF, apply the matching Gateway API CRDs first (the script's
`kubectl kustomize …?ref=v<NGF_VERSION> | kubectl apply --server-side` line), because Helm never
upgrades CRDs. `install-clustercontrol.sh` does this for you.

The install script picks the newest chart only for a **new** install (or a pinned
`CC_CHART_VERSION`). It **skips** `helm install` when a release is already `deployed`, so on an
existing node run the `helm upgrade` above by hand, or rebuild the machine.

## Rolling back

```bash
h history clustercontrol
h rollback clustercontrol <REVISION>
```

Rollback re-applies the manifests of an older revision. It does not roll back data in PVCs or
CRDs.

## Install from your local checkout

Test chart edits without publishing them, from a clone of this repository on the node (in the
reference lab, the repository is already visible at `/vagrant/…` through the synced folder):

```bash
cd cc-helm-charts-nginx-gw-dev
helm dependency update charts/clustercontrol          # fetch subcharts into charts/clustercontrol/charts/
helm lint charts/clustercontrol --set fqdn=cc.example.com
helm template clustercontrol charts/clustercontrol -n clustercontrol --set fqdn=cc.example.com | less
h upgrade clustercontrol charts/clustercontrol --reuse-values --no-hooks
```

For a fresh install from the checkout, point the install script at it — the chart reference is just
a variable:

```bash
sudo env CC_FQDN=cc.example.com CC_CHART_REF="$PWD/charts/clustercontrol" \
  bash docs/scripts/install_clustercontrol_kubeadm-cc-helm-dev.sh
```

(In the reference lab, add `CC_CHART_REF` to the Vagrantfile's `env:` block.)

## Running `helm test`

```bash
h test clustercontrol
```

Runs the `wget` pod from `templates/tests/test-connection.yaml` and reports pass/fail.

## Starting over

From least to most drastic:

```bash
# 1. restart ClusterControl's pod (StatefulSet recreates it; PVCs and data stay)
k delete pod cmon-master-0
#    cmon regenerates its 9501 certificate -> refresh the backend CA bundle afterwards:
k delete cm cmon-backend-ca          # then re-run the install script

# 2. remove the release, keep the cluster, reinstall by re-running the script
h uninstall clustercontrol --wait
k delete pvc --all                   # optional: also throw away data
k delete cm cmon-backend-ca --ignore-not-found
#    then re-run the install script

# 3. throw the whole machine away: delete the VM (or reinstall the OS), then run the script again
#    reference lab: vagrant destroy -f pupnode100 && vagrant up pupnode100
```

After option 2, the LoadBalancer address comes back as `LB_IP` because the script re-applies the
`metallb.universe.tf/loadBalancerIPs` annotation.

## Adding database hosts

ClusterControl manages databases on *other* machines over SSH: VMs in the same VPC or LAN, or any
host the node can reach on port 22 (in the reference lab, other pupnodes such as
`vagrant up pupnode130`). For cmon to log in, its pod needs a key those hosts accept:

1. The script creates Secret `my-ssh-keys` from `CC_SSH_KEY` (default: `~/.ssh/id_rsa` of the user
   who ran `sudo`; the Vagrant user's key in the reference lab) and installs the chart with
   `--set cmon.sshKeysSecretName=my-ssh-keys`, so the key is in the pod at
   `/root/.ssh-keys-user/key1`. Check: `k exec cmon-master-0 -c cmon-master -- ls /root/.ssh-keys-user`.
2. A release installed by an older version of the script lacks the setting (the script never
   re-installs a `deployed` release). Add it with the upgrade shown in "Changing a value".
3. Put the matching public key in `~/.ssh/authorized_keys` on each database host.
4. In the UI, deploy or import a cluster with that SSH user (`vagrant` in the reference lab,
   `ubuntu`/`root`/… elsewhere) and key path `/root/.ssh-keys-user/key1`.

---

## Try it

1. Change `cmon.gateway.ssl.selfSigned.extraIPs` to include your node's IP with an upgrade. Did the
   served certificate change? Why not? (Hint: `lookup` in `certs.yaml` — delete Secret `cmon-cert`
   and upgrade again.)
2. Upgrade *without* `--reuse-values` in a dry run and compare `fqdn` in the output. What would have
   broken?
3. Roll back to revision 1. What happens to `https://<CC_FQDN>/` and why? Roll forward again.

[← Inside the chart](04-inside-the-chart.md) · Next: [Troubleshooting →](06-troubleshooting.md)
