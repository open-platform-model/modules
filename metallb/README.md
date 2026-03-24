# metallb

MetalLB bare metal load-balancer for Kubernetes.

Deploys the MetalLB controller and speaker alongside all required CRDs and cluster-wide RBAC. After deployment, configure MetalLB by creating `IPAddressPool` and advertisement CRs in the same namespace.

- **Upstream**: https://metallb.io
- **GitHub**: https://github.com/metallb/metallb
- **API reference**: https://metallb.universe.tf/apis/
- **Default version**: `v0.15.3`

---

## What this module deploys

| Component | Kind | Description |
|---|---|---|
| `crds` | 9 × CustomResourceDefinition | All MetalLB CRD types (see below) |
| `controller` | Deployment | IP address assignment controller |
| `speaker` | DaemonSet | Per-node L2/BGP announcement daemon |
| `controller-rbac` | ClusterRole + ClusterRoleBinding | Permissions for the controller |
| `speaker-rbac` | ClusterRole + ClusterRoleBinding | Permissions for the speaker |

### CRDs deployed

| CRD | API Group / Version | Scope |
|---|---|---|
| `IPAddressPool` | `metallb.io/v1beta1` | Namespaced |
| `L2Advertisement` | `metallb.io/v1beta1` | Namespaced |
| `BGPAdvertisement` | `metallb.io/v1beta1` | Namespaced |
| `BGPPeer` | `metallb.io/v1beta2` | Namespaced |
| `BFDProfile` | `metallb.io/v1beta1` | Namespaced |
| `Community` | `metallb.io/v1beta1` | Namespaced |
| `ConfigurationState` | `metallb.io/v1beta1` | Namespaced |
| `ServiceBGPStatus` | `metallb.io/v1beta1` | Namespaced |
| `ServiceL2Status` | `metallb.io/v1beta1` | Namespaced |

---

## Configuration

| Field | Type | Default | Description |
|---|---|---|---|
| `image.tag` | `string` | `"v0.15.3"` | MetalLB release tag for both controller and speaker |
| `image.pullPolicy` | `string` | `"IfNotPresent"` | Image pull policy |
| `controller.logLevel` | `"debug"\|"info"\|"warn"\|"error"` | `"info"` | Controller log level |
| `controller.replicas` | `int >=1` | `1` | Number of controller replicas |
| `controller.resources` | `#ResourceRequirementsSchema` | _(unset)_ | Controller CPU/memory requests and limits |
| `speaker.logLevel` | `"debug"\|"info"\|"warn"\|"error"` | `"info"` | Speaker log level |
| `speaker.resources` | `#ResourceRequirementsSchema` | _(unset)_ | Speaker CPU/memory requests and limits |

---

## Minimal release

```cue
package my_release

import r "opmodel.dev/core/v1alpha1/modulerelease@v1"

r.#ModuleRelease

metadata: {
    name:      "metallb"
    namespace: "metallb-system"
}

module: path: "opmodel.dev/modules/metallb"

values: {}
```

All fields have sensible defaults; an empty `values: {}` deploys MetalLB v0.15.3 with `info` log level and no explicit resource limits.

---

## Production release (with resource limits)

```cue
values: {
    image: tag: "v0.15.3"

    controller: {
        logLevel: "info"
        replicas: 1
        resources: {
            requests: { cpu: "100m", memory: "64Mi" }
            limits:   { cpu: "300m", memory: "128Mi" }
        }
    }

    speaker: {
        logLevel: "info"
        resources: {
            requests: { cpu: "100m", memory: "64Mi" }
            limits:   { cpu: "300m", memory: "128Mi" }
        }
    }
}
```

---

## Configuring L2 mode (post-deploy)

After this module is deployed, create the following CRs in the same namespace (`metallb-system`) to enable L2 load-balancing:

**1. Create an IPAddressPool** — defines the IP range MetalLB may assign:

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
    - 192.168.1.200-192.168.1.250   # or CIDR: "192.168.1.200/29"
```

**2. Create an L2Advertisement** — tells MetalLB to announce these IPs via L2 (ARP/NDP):

```yaml
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - default-pool
  # Optional: restrict to specific network interfaces
  # interfaces:
  #   - eth0
```

> **Note on L2 and hostNetwork**: The MetalLB speaker ideally runs with `hostNetwork: true`
> to respond to ARP requests directly on node interfaces. This is not yet a supported field
> in the OPM DaemonSet transformer. In most CNI setups (Flannel, Calico, Cilium) the speaker
> works without it; if your environment requires `hostNetwork`, apply a patch or configure it
> at the provider level.

---

## Preparation (IPVS clusters)

If your cluster uses kube-proxy in IPVS mode, enable strict ARP mode before deploying:

```bash
kubectl get configmap kube-proxy -n kube-system -o yaml \
  | sed -e "s/strictARP: false/strictARP: true/" \
  | kubectl apply -f - -n kube-system
```

---

## Architecture

```
                   metallb-system namespace
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  controller (Deployment)          speaker (DaemonSet)           │
│  ┌──────────────────────┐         ┌────────────────────────┐   │
│  │ Watches Services of  │         │ Runs on every node.    │   │
│  │ type LoadBalancer.   │         │ Announces IPs via      │   │
│  │ Assigns IPs from     │◄───────►│ L2 (ARP/NDP) or BGP.  │   │
│  │ IPAddressPools.      │         │ Requires NET_RAW cap.  │   │
│  └──────────────────────┘         └────────────────────────┘   │
│           │                                  │                  │
│           └──────────┬───────────────────────┘                  │
│                      │  watch / update                          │
│           ┌──────────▼────────────────────────────┐            │
│           │  MetalLB CRDs (deployed by this module)│            │
│           │  IPAddressPool  │  L2Advertisement     │            │
│           │  BGPPeer        │  BGPAdvertisement    │            │
│           └─────────────────────────────────────────┘           │
└─────────────────────────────────────────────────────────────────┘
```

---

## Links

- [MetalLB installation guide](https://metallb.universe.tf/installation/)
- [MetalLB L2 mode concepts](https://metallb.universe.tf/concepts/layer2/)
- [MetalLB BGP mode concepts](https://metallb.universe.tf/concepts/bgp/)
- [MetalLB API reference](https://metallb.universe.tf/apis/)
- [MetalLB release notes](https://metallb.universe.tf/release-notes/)
