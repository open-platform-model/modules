// Package seafile composes a self-hosted Seafile Community Edition deployment —
// the Seafile server (Seahub + fileserver) backed by a MariaDB database and a
// Memcached cache.
//
// This module deploys three components:
//   - seafile   (StatefulSet) — Seahub web UI + fileserver on :80, /shared PVC
//   - mariadb   (StatefulSet) — relational store for ccnet/seafile/seahub DBs
//   - memcached (Deployment)  — in-memory cache for Seahub sessions/metadata
//
// Cross-component DNS: OPM's Service transformer names Services
// "<release>-<component>", which the module cannot know at author time. The
// release name is therefore supplied via #config.releaseName and used to build
// the MariaDB/Memcached hostnames the Seafile server connects to.
//
// PVCs are retained on module uninstall — clean up manually to reclaim storage.
package seafile

import (
	m "opmodel.dev/core/v1alpha1/module@v1"
	schemas "opmodel.dev/opm/v1alpha1/schemas@v1"
)

m.#Module

metadata: {
	modulePath:       "opmodel.dev/modules"
	name:             "seafile"
	version:          "0.2.0"
	description:      "Seafile Community Edition — self-hosted file sync & share with MariaDB + Memcached"
	defaultNamespace: "seafile"
	labels: {
		"app.kubernetes.io/component": "storage"
	}
}

// #storageVolume is the shared schema for persistent volumes in this module.
#storageVolume: {
	mountPath:     string
	type:          "pvc" | "emptyDir" | "nfs"
	size?:         string // required when type == "pvc"
	storageClass?: string // optional, only used when type == "pvc"
	server?:       string // required when type == "nfs"
	path?:         string // required when type == "nfs"
}

#config: {
	// ModuleRelease name — MUST match metadata.name in the release.cue. Used to
	// construct cross-component Service DNS names (Services are emitted as
	// "<release>-<component>"). CUE cannot introspect the release name.
	releaseName: string | *"seafile"

	// Seafile server (Seahub + fileserver) image. Community Edition.
	image: schemas.#Image & {
		repository: string | *"seafileltd/seafile-mc"
		tag:        string | *"11.0-latest"
		digest:     string | *""
	}

	// MariaDB database image.
	mariadbImage: schemas.#Image & {
		repository: string | *"mariadb"
		tag:        string | *"10.11"
		digest:     string | *""
	}

	// Memcached cache image.
	memcachedImage: schemas.#Image & {
		repository: string | *"memcached"
		tag:        string | *"1.6.18"
		digest:     string | *""
	}

	// Init image used by the Seafile "wait for MariaDB" init container.
	initImage: schemas.#Image & {
		repository: string | *"busybox"
		tag:        string | *"1.37"
		digest:     string | *""
	}

	// Seafile web/fileserver port (container + Service).
	port: int & >0 & <=65535 | *80

	// MariaDB TCP port.
	dbPort: int & >0 & <=65535 | *3306

	// Memcached TCP port and memory budget (megabytes).
	cachePort:        int & >0 & <=65535 | *11211
	cacheMemoryLimit: int & >=64 | *256

	// Container timezone (TZ database format).
	timezone: string | *"Europe/Stockholm"

	// Public hostname Seafile advertises (SEAFILE_SERVER_HOSTNAME). Set by the
	// release to the externally-routed host, e.g. "file.larnet.eu".
	seafileServerHostname: string | *"seafile.example.com"

	// Initial admin account created on first boot.
	adminEmail: string | *"admin@example.com"

	// Secrets — both resolve into one Kubernetes Secret ("seafile-secret").
	// The DB root password is shared by MariaDB (MARIADB_ROOT_PASSWORD) and the
	// Seafile server (DB_ROOT_PASSWD).
	adminPassword: schemas.#Secret & {
		$secretName:  "seafile-secret"
		$dataKey:     "admin-password"
		$description: "Seafile initial admin account password"
	}
	dbRootPassword: schemas.#Secret & {
		$secretName:  "seafile-secret"
		$dataKey:     "db-root-password"
		$description: "MariaDB root password used by Seafile"
	}

	// Persistent storage. `data` holds Seafile libraries + generated config
	// (/shared); `database` holds the MariaDB data dir (/var/lib/mysql).
	storage: {
		data: #storageVolume & {
			mountPath: *"/shared" | string
			type:      *"pvc" | "emptyDir" | "nfs"
			size:      string | *"100Gi"
		}
		database: #storageVolume & {
			mountPath: *"/var/lib/mysql" | string
			type:      *"pvc" | "emptyDir" | "nfs"
			size:      string | *"10Gi"
		}
	}

	// Kubernetes Service type for the Seafile web UI.
	serviceType: "ClusterIP" | "NodePort" | "LoadBalancer" | *"ClusterIP"

	// Optional Gateway API HTTPRoute for ingress routing.
	httpRoute?: {
		hostnames: [...string]
		gatewayRef?: {
			name:      string
			namespace: string
		}
	}

	// Resource requirements (optional, per workload).
	resources?:        schemas.#ResourceRequirementsSchema
	mariadbResources?: schemas.#ResourceRequirementsSchema
}

debugValues: {
	releaseName: "seafile"
	image: {
		repository: "seafileltd/seafile-mc"
		tag:        "11.0-latest"
		digest:     ""
	}
	mariadbImage: {
		repository: "mariadb"
		tag:        "10.11"
		digest:     ""
	}
	memcachedImage: {
		repository: "memcached"
		tag:        "1.6.18"
		digest:     ""
	}
	initImage: {
		repository: "busybox"
		tag:        "1.37"
		digest:     ""
	}
	port:                  80
	dbPort:                3306
	cachePort:             11211
	cacheMemoryLimit:      256
	timezone:              "Europe/Stockholm"
	seafileServerHostname: "seafile.example.com"
	adminEmail:            "admin@example.com"
	adminPassword: {value: "debug-admin-password-change-me-32ch"}
	dbRootPassword: {value: "debug-db-root-password-change-me-32"}
	storage: {
		data: {
			mountPath:    "/shared"
			type:         "pvc"
			size:         "100Gi"
			storageClass: "standard"
		}
		database: {
			mountPath:    "/var/lib/mysql"
			type:         "pvc"
			size:         "10Gi"
			storageClass: "standard"
		}
	}
	serviceType: "ClusterIP"
	httpRoute: {
		hostnames: ["seafile.example.com"]
		gatewayRef: {
			name:      "gateway-gateway"
			namespace: "istio-ingress"
		}
	}
	resources: {
		requests: {cpu: "250m", memory: "512Mi"}
		limits: {cpu: "2000m", memory: "2Gi"}
	}
	mariadbResources: {
		requests: {cpu: "100m", memory: "256Mi"}
		limits: {cpu: "1000m", memory: "1Gi"}
	}
}
