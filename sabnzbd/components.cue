// Components defines the SABnzbd workload.
// Single stateful component with a persistent config volume, an optional
// downloads mount, a web Service, health checks and an optional HTTPRoute.
package sabnzbd

import (
	"strings"

	bp "opmodel.dev/catalogs/opm/blueprints/v1beta1"
	tr "opmodel.dev/catalogs/opm/traits/v1beta1"
)

// #components contains component definitions.
// Components reference #config which gets resolved to concrete values at build time.
#components: {

	/////////////////////////////////////////////////////////////////
	//// SABnzbd - Stateful Usenet Download Client
	/////////////////////////////////////////////////////////////////

	sabnzbd: {
		bp.#StatefulWorkload
		tr.#Expose
		tr.#SecurityContext

		if #config.httpRoute != _|_ {
			tr.#HttpRoute
		}
		if #config.podScheduling != _|_ {
			tr.#PodScheduling
		}
		if #config.podMetadata != _|_ {
			tr.#PodMetadata
		}

		metadata: name: "sabnzbd"

		_volumes: spec.statefulWorkload.volumes

		_allVolumes: {
			config: #config.storage.config
			if #config.storage.downloads != _|_ {
				downloads: #config.storage.downloads
			}
		}

		// Conditional struct-valued spec fields, HOISTED to component level
		// rather than guarded inside the spec block — the in-spec form trips
		// the CUE v0.17 closedness regression on the v2 catalog's closed
		// blueprint spec (catalog CLAUDE.md authoring pitfall; see
		// docs/cue-guard-closedness-workaround.md there). Do not inline these.
		if #config.hostWhitelist != _|_ {
			// Rewritten into sabnzbd.ini on every start. Comma-joined
			// because the entrypoint seds the value in verbatim.
			spec: statefulWorkload: container: env: SABNZBD__HOST_WHITELIST_ENTRIES: {
				name:  "SABNZBD__HOST_WHITELIST_ENTRIES"
				value: strings.Join(#config.hostWhitelist, ", ")
			}
		}
		if #config.localRanges != _|_ {
			spec: statefulWorkload: container: env: SABNZBD__LOCAL_RANGES_ENTRIES: {
				name:  "SABNZBD__LOCAL_RANGES_ENTRIES"
				value: strings.Join(#config.localRanges, ", ")
			}
		}
		if #config.env != _|_ {
			spec: statefulWorkload: container: env: {
				for k, v in #config.env {
					(k): {
						name:  k
						value: v
					}
				}
			}
		}
		if #config.resources != _|_ {
			spec: statefulWorkload: container: resources: #config.resources
		}
		if #config.podScheduling != _|_ {
			spec: podScheduling: #config.podScheduling
		}
		if #config.podMetadata != _|_ {
			spec: podMetadata: #config.podMetadata
		}
		if #config.httpRoute != _|_ {
			spec: httpRoute: {
				hostnames: #config.httpRoute.hostnames
				rules: [{
					matches: [{
						path: {
							type:  "PathPrefix"
							value: "/"
						}
					}]
					backendPort: #config.port
				}]
			}
		}
		if #config.httpRoute != _|_ if #config.httpRoute.gatewayRef != _|_ {
			spec: httpRoute: gatewayRef: #config.httpRoute.gatewayRef
		}

		spec: {
			// See the radarr module: this is the only place process identity can
			// be set, and fsGroup is what removes the need for a root chown init
			// container on the config volume.
			securityContext: {
				runAsUser:    #config.runAsUser
				runAsGroup:   #config.runAsGroup
				fsGroup:      #config.runAsGroup
				runAsNonRoot: true
			}

			statefulWorkload: {
				// Single replica — one queue, one set of on-disk databases.
				scaling: count: 1
				restartPolicy: "Always"
				updateStrategy: {
					type: "RollingUpdate"
					rollingUpdate: {}
				}

				container: {
					name:  "sabnzbd"
					image: #config.image
					ports: http: {
						name:       "http"
						targetPort: #config.port
					}
					env: {
						TZ: {
							name:  "TZ"
							value: #config.timezone
						}
						// The entrypoint interpolates these two directly into its
						// --server argument, so they set the real listen socket.
						SABNZBD__ADDRESS: {
							name:  "SABNZBD__ADDRESS"
							value: #config.bindAddress
						}
						SABNZBD__PORT: {
							name:  "SABNZBD__PORT"
							value: "\(#config.port)"
						}
						// The conditional entries (host whitelist, local ranges,
						// extra env) are written from the hoisted guards above
						// the spec block.
					}

					// SABnzbd accepts raw IP addresses in the Host header
					// regardless of host_whitelist, so a probe against the pod IP
					// is not affected by that setting.
					//
					// The startupProbe gates liveness AND readiness until the
					// app actually serves. Sibling modules were SIGKILLed
					// mid-database-migration without one; this image seeds its
					// INI on first boot, so it gets the same protection.
					startupProbe: {
						httpGet: {
							path: #config.healthPath
							port: #config.port
						}
						initialDelaySeconds: 10
						periodSeconds:       10
						timeoutSeconds:      5
						// Guarded rather than defaulted — see the schema note.
						// Both arms must set a CONCRETE value, because the arm
						// that unifies with #ProbeSchema's `uint | *3` is where
						// a second default would make the render ambiguous.
						if #config.startupFailureThreshold != _|_ {
							failureThreshold: #config.startupFailureThreshold
						}
						if #config.startupFailureThreshold == _|_ {
							failureThreshold: 60
						}
					}
					livenessProbe: {
						httpGet: {
							path: #config.healthPath
							port: #config.port
						}
						// 0: the startupProbe above already held liveness off
						// until the app answered, so a second delay would only
						// slow down detection of a genuine hang.
						initialDelaySeconds: 0
						periodSeconds:       10
						timeoutSeconds:      5
						failureThreshold:    5
					}
					readinessProbe: {
						httpGet: {
							path: #config.healthPath
							port: #config.port
						}
						initialDelaySeconds: 10
						periodSeconds:       10
						timeoutSeconds:      5
						failureThreshold:    5
					}

					// resources is conditionally set from component level — see
					// the hoisted guards above the spec block.

					// Container-scope security. The StatefulSet transformer maps
					// only the identity fields to the pod, so these take effect
					// here or nowhere. readOnlyRootFilesystem is deliberately not
					// set — the entrypoint writes to /config and Python writes
					// outside it.
					securityContext: {
						allowPrivilegeEscalation: false
						capabilities: drop: ["ALL"]
					}

					volumeMounts: {
						for vName, v in _allVolumes {
							(vName): _volumes[vName] & {
								mountPath: v.mountPath
							}
						}
					}
				}

				// accessMode/storageClass/readOnly carry no catalog defaults, so
				// every field must be set concretely.
				volumes: {
					for name, v in _allVolumes {
						(name): {
							"name":   name
							readOnly: v.readOnly
							if v.type == "pvc" {
								persistentClaim: {
									size:       v.size
									accessMode: "ReadWriteOnce"
									if v.storageClass != _|_ {
										storageClass: v.storageClass
									}
									if v.storageClass == _|_ {
										storageClass: "standard"
									}
								}
							}
							if v.type == "emptyDir" {
								emptyDir: {}
							}
							if v.type == "nfs" {
								nfs: {
									server: v.server
									path:   v.path
									if v.readOnly {
										readOnly: true
									}
								}
							}
						}
					}
				}
			}

			expose: {
				ports: http: statefulWorkload.container.ports.http & {
					exposedPort: #config.port
				}
				type: #config.serviceType
				if #config.serviceName != _|_ {
					name: #config.serviceName
				}
			}

			// podScheduling, podMetadata and the optional HTTPRoute are written
			// from the hoisted guards above the spec block.
		}
	}
}
