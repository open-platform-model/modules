// Package apprise defines the Apprise API notification router module.
// A single-container stateless application (Django + gunicorn behind nginx)
// that accepts one HTTP call and fans it out to 130+ notification services:
// - module.cue:     metadata and config schema
// - components.cue: component definitions (catalog_opm blueprints/traits)
//
// This wraps caronc/apprise-api — the REST service — not the Apprise Python
// library of the same name. Apprise is a ROUTER, not a transport: it has no
// app of its own and reaches phones only through something else (an ntfy
// topic, a Discord webhook, email).
//
// Configuration is delivered as files. With APPRISE_STATEFUL_MODE=simple a
// config {KEY} is just "<KEY>.yml" in the config directory, so a SOPS-managed
// Secret mounted read-only at /config IS the configuration — no API calls, no
// web-UI clicking, no runtime state. APPRISE_CONFIG_LOCK then blocks the API
// from mutating it, which is what makes the read-only mount safe rather than
// merely restrictive.
//
// Verified against v1.5.1 (2026-08-13): with a read-only /config plus
// config lock, GET /status returns 200 with details ["OK"] — the config
// lock suppresses the CONFIG_PERMISSION_ISSUE that an unwritable config
// directory would otherwise report, so the health probe stays honest. A
// seeded key resolves (POST /notify/<key> returned 424 "delivery failed"
// with the URLs loaded, against 204 "no such config" for an unknown key).
//
// The URL bodies themselves are NOT modelled in CUE: an Apprise URL embeds
// its own credential (discord://id/token, mailto://user:pass@host), and a
// config file is a single blob that cannot carry a secretKeyRef. CUE owns
// which keys exist and how they are mounted; the bodies live in the Secret.
//
// OPM v2 line: path major v2 (the v1 train publishes this registry path at
// major v1 — cross-train major separation), core@v2 identity reshape
// (complete modulePath with major, identity/ package, derived fqn), and the
// version-segment catalog imports (resources/v1beta1 etc.).
package apprise

import (
	id "opmodel.dev/modules/apprise/identity"
	m "opmodel.dev/core@v2"
	res "opmodel.dev/catalogs/opm/resources/v1beta1"
)

// Module definition
m.#Module

// Module metadata — modulePath is the COMPLETE CUE module path including the
// major, byte-identical to cue.mod's module field and identity/identity.cue;
// fqn/registryPath/uuid derive from it (enhancement 0010).
metadata: {
	name:        "apprise"
	modulePath:  id.ModulePath
	version:     id.Version
	description: "Apprise API - notification router fanning one HTTP call out to 130+ services"
}

// Schema only - constraints for users.
#config: {
	// Container image. Docker Hub tags carry the leading "v" ("v1.5.1").
	image: res.#Image & {
		repository: string | *"caronc/apprise"
		tag:        string | *"v1.5.1"
		digest:     string | *"sha256:1871ed736799f6320d5061b72a60507f62c8747026e830175dc4b9f8adbf78dd"
	}

	// Kubernetes Service port.
	port: int & >0 & <=65535 | *8000

	// Port the server listens on inside the container (HTTP_PORT). nginx and
	// gunicorn both run in the container; this is the nginx frontend.
	listenPort: int & >0 & <=65535 | *8000

	// "stateful" mounts configSecret at the config directory and serves
	// /notify/{KEY}. "stateless" stores nothing at all — callers pass the
	// target URLs in each /notify request body, or they come from
	// statelessUrls. Stateless keeps credentials in the caller, which
	// defeats most of the reason to run a router, so it is not the default.
	mode: "stateful" | "stateless" | *"stateful"

	// The pre-existing (SOPS-managed) Secret holding the Apprise config
	// bodies, one Secret key per Apprise config {KEY}. Each listed key is
	// projected to "<key>.<ext>" in the config directory, where ext follows
	// configFormat. Required when mode is "stateful".
	//
	// The Secret is NOT created by this module — provision it out of band
	// and let the pod reference it by exact name.
	configSecret?: {
		name!: string
		keys!: [...string]
	}

	// Apprise reads YAML config as "<KEY>.yml" and its TEXT format as
	// "<KEY>.cfg". YAML is the richer form — it carries per-URL tags.
	configFormat: "yaml" | "text" | *"yaml"

	// Lock the stateful store read-only: the API can no longer add, delete
	// or read back configuration, while /notify/{KEY} keeps resolving it.
	// Load-bearing, not decoration — this is what makes a read-only config
	// mount report healthy instead of a permission failure.
	configLock: bool | *true

	// The {KEY} the web UI defaults to (APPRISE_DEFAULT_CONFIG_ID).
	defaultConfigId: string | *"apprise"

	// Default targets for /notify calls that carry no URLs and no {KEY}.
	// Only meaningful when mode is "stateless"; the value is a set of
	// credential-bearing Apprise URLs.
	// 0013: becomes c.#Secret when core ships it; plain string until then.
	statelessUrls?: string

	// Admin mode removes the user/admin distinction and allows listing
	// stored configuration keys. Off by default: the API has no
	// authentication of its own, by upstream design.
	admin: bool | *false

	// Disable the web administration interface entirely, leaving only the
	// API. Worth turning on once a configuration is settled — but the UI's
	// review tab is the easiest way to confirm a config parsed as intended,
	// so it starts enabled.
	apiOnly: bool | *false

	// nginx refuses to answer invalid or unsupported requests at all.
	strictMode: bool | *true

	// Sub-path this API is served under when it sits behind a proxy that
	// does not strip the prefix (APPRISE_BASE_URL).
	baseUrl?: string

	// Plugins to refuse, comma or space separated. The upstream default
	// blocks local desktop actions that make no sense in a container; it is
	// restated here rather than left implicit so the deny list is visible in
	// the rendered manifest.
	denyServices: string | *"windows, dbus, gnome, macosx, syslog"

	// Exclusive allow list. When set, upstream IGNORES denyServices
	// entirely — the two are not additive.
	allowServices?: string

	// How many times one Apprise server may recursively call another
	// through the apprise:// schema.
	recursionMax: int & >=0 | *1

	// Webhook that receives a POST with the result of every notification.
	webhookUrl?: string & =~"^https?://"

	// File attachments. Uploads land on the container's ephemeral
	// filesystem — they are transient by nature, so no volume is mounted
	// for them. Disabling sets APPRISE_ATTACH_SIZE=0, which makes the
	// server drop attachments even when a caller provides them.
	attachments: {
		enabled: bool | *true
		// Megabytes. nginx caps this at 500 upstream.
		maxSizeMb: int & >0 & <=500 | *200
	}

	// gunicorn workers. Upstream computes (2 * CPUs) + 1, which is wildly
	// oversized for a home notification router — hence 1, matching the
	// upstream docker-compose example.
	workers: {
		count:          int & >0 | *1
		timeoutSeconds: int & >0 | *300
	}

	// Console log level (LOG_LEVEL). All logs go to stdout/stderr.
	logLevel: "CRITICAL" | "ERROR" | "WARNING" | "INFO" | "DEBUG" | *"INFO"

	// Container timezone (TZ database format). Applies to both nginx and
	// application log timestamps.
	timezone: string | *"Europe/Stockholm"

	// The container starts as root and drops to this uid/gid.
	puid: int | *1000
	pgid: int | *1000

	// Replica count. Safe above 1: every replica mounts the same read-only
	// config Secret and holds no local state.
	replicas: int & >0 | *1

	// Kubernetes Service type
	serviceType: "ClusterIP" | "NodePort" | "LoadBalancer" | *"ClusterIP"

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
}

debugValues: {
	image: {
		repository: "caronc/apprise"
		tag:        "v1.5.1"
		digest:     "sha256:1871ed736799f6320d5061b72a60507f62c8747026e830175dc4b9f8adbf78dd"
	}
	port:       8000
	listenPort: 8000
	mode:       "stateful"
	configSecret: {
		name: "apprise-config"
		keys: ["nas1", "critical"]
	}
	configFormat:    "yaml"
	configLock:      true
	defaultConfigId: "apprise"
	statelessUrls:   "mailto://user:pass@example.com"
	admin:           false
	apiOnly:         false
	strictMode:      true
	baseUrl:         "/apprise"
	denyServices:    "windows, dbus, gnome, macosx, syslog"
	allowServices:   "ntfy, discord, mailto"
	recursionMax:    1
	webhookUrl:      "https://hooks.example.com/apprise-results"
	attachments: {
		enabled:   true
		maxSizeMb: 200
	}
	workers: {
		count:          1
		timeoutSeconds: 300
	}
	logLevel:    "INFO"
	timezone:    "Europe/Stockholm"
	puid:        1000
	pgid:        1000
	replicas:    1
	serviceType: "ClusterIP"
	resources: {
		requests: {
			cpu:    "50m"
			memory: "128Mi"
		}
		limits: {
			cpu:    "1000m"
			memory: "512Mi"
		}
	}
	httpRoute: {
		hostnames: ["apprise.example.com"]
		gatewayRef: {
			name:      "gateway-gateway"
			namespace: "istio-ingress"
		}
	}
}
