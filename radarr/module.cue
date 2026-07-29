// Package radarr defines the Radarr movie collection manager module.
// A single-container stateful application on the home-operations image:
// - module.cue:     metadata and config schema
// - components.cue: component definitions (catalog_opm blueprints/traits)
//
// This is deliberately NOT modelled on the LinuxServer.io convention that the
// jellyfin module uses. The home-operations image ships `USER nobody:nogroup`,
// has no s6-overlay and no PUID/PGID, and its entire entrypoint is
//
//	exec /app/bin/Radarr --nobrowser --data=/config "$@"
//
// so it cannot change its own identity and never chowns anything. Identity is
// therefore a Kubernetes concern (runAsUser/runAsGroup/fsGroup), and the
// root `fix-permissions` init container that jellyfin and seerr both carry is
// absent here — leaving no container in this pod running as root.
//
// sonarr is the same design with a different name, port and env prefix; the
// two are kept byte-identical apart from the delta documented in both READMEs.
package radarr

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
	name:        "radarr"
	version:     "1.0.2"
	description: "Radarr - movie collection manager for Usenet and BitTorrent"
}

// #storageVolume is the shared schema for all storage entries.
#storageVolume: {
	mountPath:     string
	type:          "pvc" | "emptyDir" | "nfs"
	size?:         string // required when type == "pvc"
	storageClass?: string // optional, only used when type == "pvc"
	server?:       string // required when type == "nfs"
	path?:         string // required when type == "nfs"

	// Mount read-only. Applied to BOTH the volume source and the container's
	// volumeMount, so an NFS export is mounted `ro` at the kernel rather than
	// merely hidden from this container.
	//
	// Defaults false, and for this module that default is load-bearing in a way
	// it is not for jellyfin: Radarr's entire job is to MOVE files out of the
	// download directory and into the library. A read-only media mount does not
	// degrade it, it breaks import outright.
	readOnly: bool | *false
}

// Schema only - constraints for users, no defaults beyond sensible image/port.
#config: {
	// Container image
	image: res.#Image & {
		repository: string | *"ghcr.io/home-operations/radarr"
		tag:        string | *"5.27.0"
		digest:     string | *""
	}

	// Exposed service port for the web UI
	port: int & >0 & <=65535 | *7878

	// Container timezone
	timezone: string | *"Europe/Stockholm"

	// Process identity.
	//
	// Defaults to the image's own `nobody:nogroup`. Override to match whatever
	// owns the mounted data — for NFS exports this is not cosmetic: the exports
	// typically root_squash, so a pod running as the wrong uid gets a
	// successful mount and then EACCES on every read. `df` succeeding while
	// `ls` fails is an identity problem, never a mount problem.
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

	// Path the liveness/readiness probes GET. Servarr exposes an
	// unauthenticated /ping. Override when the app is served under a URL base,
	// since the probe path has to carry the same prefix.
	healthPath: string | *"/ping"

	// Extra environment variables, passed to the container verbatim.
	//
	// This is how Servarr settings are set. Radarr binds its configuration from
	// the environment as RADARR__<SECTION>__<KEY> — the image itself ships
	// RADARR__UPDATE__BRANCH=develop, which is what proves the binding is live
	// on this version. The module deliberately does NOT model the individual
	// settings as typed fields: only the UPDATE__BRANCH name is verified
	// against the running artefact, and a typed field whose env name turns out
	// to be wrong is worse than no field at all — it reads as configuration and
	// silently does nothing.
	//
	// Note that these override /config/config.xml on EVERY start, not just the
	// first. That makes them right for declaring a setting and wrong for
	// migrating an existing instance, whose config.xml is already authoritative.
	env?: [Name=string]: string

	// Storage: config is required; media and downloads are optional.
	storage: {
		// Application data — SQLite (radarr.db, logs.db) in WAL mode, so this
		// wants a block device with real locking semantics, not NFS.
		config: #storageVolume & {
			mountPath: *"/config" | string
			type:      *"pvc" | "emptyDir" | "nfs"
			size:      string | *"10Gi"
		}

		// Library directories, keyed by name (e.g. "movies", "movies4k").
		//
		// One mount per directory rather than one mount of the parent: an NFS
		// export does not traverse into child datasets, so mounting the library
		// root yields a view with the actual media missing. Each directory that
		// is its own dataset needs its own export and its own entry here.
		media?: [Name=string]: #storageVolume

		// The download client's completed-output directory. Radarr reads from
		// here and deletes from here, so it must not be read-only.
		downloads?: #storageVolume
	}

	// Kubernetes Service type for the web UI
	serviceType: "ClusterIP" | "NodePort" | "LoadBalancer" | *"ClusterIP"

	// Explicit Service name, rendered verbatim instead of the default
	// {instance}-{component}.
	//
	// Opt-in and normally wrong — two instances of this module in one namespace
	// would collide. Correct only when the name is a contract with something
	// outside the module, e.g. a peer application that stores this service as a
	// bare hostname and would otherwise need reconfiguring.
	//
	// ⚠ DO NOT COMBINE WITH httpRoute ON catalogs/opm@v1.0.0-alpha.6.
	// The route transformers build their backendRef from the instance-scoped
	// {instance}-{component} name and never consult expose.name, so the route
	// is emitted pointing at a Service that does not exist and every request
	// through the gateway returns 503. The Service and StatefulSet transformers
	// DO honour expose.name, so nothing else looks wrong: the render succeeds,
	// the objects apply, and it fails only at request time.
	// Verified against the rendered output 2026-07-29; all four route
	// transformers (http/grpc/tcp/tls) share it.
	serviceName?: string

	// Optional Gateway API HTTPRoute for ingress routing.
	httpRoute?: {
		hostnames: [...string]
		gatewayRef?: {
			name:      string
			namespace: string
		}
	}

	// Container resource requests and limits.
	resources?: res.#ResourceRequirementsSchema

	// Optional scheduling constraints — which nodes this pod may run on.
	podScheduling?: tr.#PodSchedulingSchema

	// Optional pod-template labels and annotations.
	//
	// Distinct from component metadata on purpose: component labels flow into
	// spec.selector.matchLabels, which Kubernetes makes IMMUTABLE. Anything
	// belonging on the pod and not on the selector goes here — mesh membership
	// (istio.io/dataplane-mode), scrape hints, and k8up's backup annotations
	// (k8up.io/backupcommand, k8up.io/file-extension), which is how a pre-backup
	// SQLite checkpoint is attached without the module modelling backups.
	podMetadata?: tr.#PodMetadataSchema
}

debugValues: {
	image: {
		repository: "ghcr.io/home-operations/radarr"
		tag:        "5.27.0"
		digest:     "sha256:f1a47717f5792d82becbe278c9502d756b898d63b2c637da131172c4adf1ffc7"
	}
	port:                    7878
	timezone:                "Europe/Stockholm"
	runAsUser:               3005
	runAsGroup:              3005
	healthPath:              "/ping"
	startupFailureThreshold: 60
	serviceType:             "ClusterIP"
	serviceName:             "radarr"
	env: {
		RADARR__UPDATE__BRANCH: "develop"
	}
	resources: {
		requests: {
			cpu:    "100m"
			memory: "256Mi"
		}
		limits: {
			cpu:    "2000m"
			memory: "2Gi"
		}
	}
	httpRoute: {
		hostnames: ["radarr.example.com"]
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
		media: {
			movies: {
				mountPath: "/media/movies"
				type:      "nfs"
				server:    "192.168.1.1"
				path:      "/mnt/data/media/movies"
			}
		}
		downloads: {
			mountPath: "/downloads"
			type:      "nfs"
			server:    "192.168.1.1"
			path:      "/mnt/data/media/downloads"
		}
	}
}
