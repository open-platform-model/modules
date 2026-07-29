// Package sabnzbd defines the SABnzbd Usenet download client module.
// A single-container stateful application on the home-operations image:
// - module.cue:     metadata and config schema
// - components.cue: component definitions (catalog_opm blueprints/traits)
//
// Shares the identity model of the radarr/sonarr modules — `USER nobody:nogroup`,
// no PUID/PGID, no s6-overlay, so identity is set with runAsUser/runAsGroup/
// fsGroup and no root init container is needed.
//
// Unlike the Servarr apps, this image's entrypoint does real work: it seeds
// /config/sabnzbd.ini from /defaults on first boot, generates an api_key and an
// nzb_key, and then rewrites four settings from the environment on EVERY start.
// Those four rewrites are this module's interface, and `hostWhitelist` in
// particular is what makes SABnzbd reachable through an ingress at all.
package sabnzbd

import (
	m "opmodel.dev/core@v1"
	res "opmodel.dev/catalogs/opm/resources"
	tr "opmodel.dev/catalogs/opm/traits"
)

// Module definition
m.#Module

// Module metadata
metadata: {
	modulePath:  "opmodel.dev/modules"
	name:        "sabnzbd"
	version:     "1.0.2"
	description: "SABnzbd - binary newsreader and Usenet download client"
}

// #storageVolume is the shared schema for all storage entries.
#storageVolume: {
	mountPath:     string
	type:          "pvc" | "emptyDir" | "nfs"
	size?:         string // required when type == "pvc"
	storageClass?: string // optional, only used when type == "pvc"
	server?:       string // required when type == "nfs"
	path?:         string // required when type == "nfs"

	// Mount read-only. SABnzbd writes everything it touches, so this exists for
	// schema symmetry with the sibling modules rather than as a useful setting.
	readOnly: bool | *false
}

// Schema only - constraints for users, no defaults beyond sensible image/port.
#config: {
	// Container image
	image: res.#Image & {
		repository: string | *"ghcr.io/home-operations/sabnzbd"
		tag:        string | *"4.5.2"
		digest:     string | *""
	}

	// Exposed service port for the web UI and API.
	// Passed to the process as SABNZBD__PORT, which the entrypoint uses to build
	// its --server argument, so this is the real listen port and not just a
	// Service-level rename.
	port: int & >0 & <=65535 | *8080

	// Listen address, passed as SABNZBD__ADDRESS. The image default binds both
	// stacks; there is rarely a reason to change it.
	bindAddress: string | *"[::]"

	// Container timezone
	timezone: string | *"Europe/Stockholm"

	// Process identity. See the radarr module for why this is the only place it
	// can be set, and why it is load-bearing on root_squashed NFS exports.
	runAsUser:  int | *65534
	runAsGroup: int | *65534

	// How many 10-second startup probes may fail before the container is
	// considered failed to start.
	//
	// The default is 10 minutes of grace, and it is not arbitrary: on first
	// boot these apps initialize or migrate their SQLite database BEFORE
	// opening the listener. Sonarr runs 200+ migrations, which overran a
	// liveness probe's budget and got the container SIGKILLed mid-migration —
	// a restart loop that only converges because migrations commit
	// individually. Raise it on slow storage.
	// Optional WITHOUT a default on purpose. #ProbeSchema.failureThreshold
	// already carries `uint | *3`, and unifying a second marked default into it
	// produces `>0 & int | 60 | 3` — a disjunction with TWO defaults, which CUE
	// cannot resolve, so the whole instance renders non-concrete. The default is
	// applied in components.cue with an explicit guard instead.
	startupFailureThreshold?: uint & >0

	// Path the liveness/readiness probes GET.
	//
	// Defaults to "/" rather than the more precise "/api?mode=version" because
	// the kubelet builds the probe URL with the configured value as the URL
	// PATH, which percent-escapes "?" — a query string in a probe path does not
	// survive. "/" answers with a 2xx/3xx, which is what the probe checks.
	healthPath: string | *"/"

	// Hostnames SABnzbd will accept in the HTTP Host header, written to
	// `host_whitelist` in sabnzbd.ini on every start.
	//
	// NOT optional in practice. SABnzbd rejects any request whose Host is a DNS
	// name it does not recognise, with "Access denied - Hostname verification
	// failed". Behind an ingress the Host header is the public name, so leaving
	// this unset makes the app unreachable through the very route that was set
	// up for it — and the failure reads like a routing fault, not a config one.
	//
	// Raw IP addresses are always accepted, which is why the kubelet's probes
	// (which use the pod IP) work without an entry here.
	//
	// The entrypoint always prepends the container's own $HOSTNAME, so a
	// StatefulSet's stable pod name is whitelisted for free.
	hostWhitelist?: [...string]

	// Client ranges treated as local, written to `local_ranges` in sabnzbd.ini.
	//
	// Peers that call the API — Radarr, Sonarr — do so from POD IPs once they
	// move into the cluster, not from the LAN, so a range that only covers the
	// LAN silently changes who is treated as authenticated. Set this to the
	// cluster's pod CIDR plus whatever LAN ranges applied before.
	localRanges?: [...string]

	// Extra environment variables, passed to the container verbatim.
	//
	// The image reads SABNZBD__API_KEY and SABNZBD__NZB_KEY the same way it
	// reads the settings above, but those are credentials and this module does
	// not model them: putting a key here would put it in cleartext in the
	// instance values. v1.0.0 has no supported way to pre-seed them — use the
	// keys the entrypoint generates on first boot, or the ones already present
	// in a migrated sabnzbd.ini.
	env?: [Name=string]: string

	// Storage: config is required; downloads is optional but effectively
	// mandatory for a working install.
	storage: {
		// Application data — sabnzbd.ini plus the admin/ queue and history
		// databases. Wants a block device, not NFS.
		//
		// ⚠ Size this against the INI's download_dir. If incomplete downloads
		// land under /config rather than under the downloads mount, this volume
		// carries every in-flight unpack and needs to be tens of GB, not the
		// couple of GB the configuration itself uses.
		config: #storageVolume & {
			mountPath: *"/config" | string
			type:      *"pvc" | "emptyDir" | "nfs"
			size:      string | *"10Gi"
		}

		// Completed (and usually incomplete) downloads. The consuming Servarr
		// apps mount the same directory to import from, so the mount path here
		// and there is a contract between them.
		downloads?: #storageVolume
	}

	// Kubernetes Service type
	serviceType: "ClusterIP" | "NodePort" | "LoadBalancer" | *"ClusterIP"

	// Explicit Service name, rendered verbatim instead of the default
	// {instance}-{component}.
	//
	// Opt-in, and the reason it exists on this module: the Servarr apps store
	// their download client as a bare hostname in their own databases. Setting
	// this to that stored name lets them keep working without being
	// reconfigured. Not instance-safe — two instances in one namespace collide.
	//
	// ⚠ DO NOT COMBINE WITH httpRoute ON catalogs/opm@v1.0.0-alpha.6.
	// The route transformers build their backendRef from the instance-scoped
	// {instance}-{component} name and never consult expose.name, so the route
	// points at a Service that does not exist and every request through the
	// gateway returns 503. This bites THIS module hardest, because it is the one
	// that wants both an exact Service name and an ingress route. The workaround
	// is to leave this unset and put a second, plain Service carrying the wanted
	// name next to the ModuleInstance.
	// Verified against the rendered output 2026-07-29; all four route
	// transformers (http/grpc/tcp/tls) share it.
	serviceName?: string

	// Optional Gateway API HTTPRoute for ingress routing.
	// Every hostname listed here also belongs in hostWhitelist.
	httpRoute?: {
		hostnames: [...string]
		gatewayRef?: {
			name:      string
			namespace: string
		}
	}

	// Container resource requests and limits.
	// par2 repair and unpack are the memory spike, not steady-state operation.
	resources?: res.#ResourceRequirementsSchema

	// Optional scheduling constraints.
	podScheduling?: tr.#PodSchedulingSchema

	// Optional pod-template labels and annotations (mesh membership, scrape
	// hints, k8up backup annotations).
	podMetadata?: tr.#PodMetadataSchema
}

debugValues: {
	image: {
		repository: "ghcr.io/home-operations/sabnzbd"
		tag:        "4.5.2"
		digest:     "sha256:e3f27e50ee51f950d89ce888cb3c3c4e74b46b42751333ee008f906906cbf05b"
	}
	port:        8080
	bindAddress: "[::]"
	timezone:    "Europe/Stockholm"
	runAsUser:   3005
	runAsGroup:  3005
	healthPath:  "/"
	serviceType: "ClusterIP"
	serviceName: "sabnzbd"
	hostWhitelist: ["sab.example.com"]
	localRanges: ["10.244.0.0/16", "10.10.0.0/24"]
	env: {
		SABNZBD__LOG_LEVEL: "1"
	}
	resources: {
		requests: {
			cpu:    "100m"
			memory: "256Mi"
		}
		limits: {
			cpu:    "4000m"
			memory: "4Gi"
		}
	}
	httpRoute: {
		hostnames: ["sab.example.com"]
		gatewayRef: {
			name:      "gateway-gateway"
			namespace: "istio-ingress"
		}
	}
	podScheduling: nodeSelector: "kubernetes.io/os":    "linux"
	podMetadata: annotations: "k8up.io/file-extension": ".sql"
	storage: {
		config: {
			mountPath:    "/config"
			type:         "pvc"
			size:         "10Gi"
			storageClass: "local-path"
		}
		downloads: {
			mountPath: "/downloads"
			type:      "nfs"
			server:    "192.168.1.1"
			path:      "/mnt/data/media/downloads"
		}
	}
}
