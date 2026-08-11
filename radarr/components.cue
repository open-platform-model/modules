// Components defines the Radarr workload.
// Single stateful component with a persistent config volume, optional library
// and download mounts, a web Service, health checks and an optional HTTPRoute.
package radarr

import (
	bp "opmodel.dev/catalogs/opm/blueprints/v1beta1"
	tr "opmodel.dev/catalogs/opm/traits/v1beta1"
)

// #components contains component definitions.
// Components reference #config which gets resolved to concrete values at build time.
#components: {

	/////////////////////////////////////////////////////////////////
	//// Radarr - Stateful Movie Collection Manager
	/////////////////////////////////////////////////////////////////

	radarr: {
		// StatefulWorkload composes the Container + Volumes resources and the
		// scaling / restart / init-container traits, and stamps the
		// workload-type=stateful label that selects the StatefulSet transformer.
		bp.#StatefulWorkload
		tr.#Expose
		tr.#SecurityContext

		// HTTPRoute trait only when ingress is requested.
		if #config.httpRoute != _|_ {
			tr.#HttpRoute
		}

		// Attached only when configured. Attaching unconditionally would leave a
		// non-concrete field in the spec and fail the render.
		if #config.podScheduling != _|_ {
			tr.#PodScheduling
		}
		if #config.podMetadata != _|_ {
			tr.#PodMetadata
		}

		metadata: name: "radarr"

		// Bind the rendered volume set so volumeMounts can reuse each source.
		_volumes: spec.statefulWorkload.volumes

		// All storage entries flattened into one named map for uniform
		// rendering. config is always present; media and downloads are optional.
		_allVolumes: {
			config: #config.storage.config
			if #config.storage.media != _|_ {
				for name, v in #config.storage.media {
					(name): v
				}
			}
			if #config.storage.downloads != _|_ {
				downloads: #config.storage.downloads
			}
		}

		// Conditional struct-valued spec fields, HOISTED to component level
		// rather than guarded inside the spec block — the in-spec form trips
		// the CUE v0.17 closedness regression on the v2 catalog's closed
		// blueprint spec (catalog CLAUDE.md authoring pitfall; see
		// docs/cue-guard-closedness-workaround.md there). Do not inline these.
		if #config.resources != _|_ {
			spec: statefulWorkload: container: resources: #config.resources
		}

		// Passed through verbatim; the schemas are the catalog's own.
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
			// Identity for the whole pod. The image ships USER nobody:nogroup and
			// has no PUID/PGID mechanism, so this is the ONLY place the process
			// identity can be set — and on root_squashed NFS exports it is what
			// decides whether the mounts are readable at all.
			//
			// fsGroup makes the kubelet chgrp the config volume on mount, which
			// is what removes the need for a root chown init container.
			securityContext: {
				runAsUser:    #config.runAsUser
				runAsGroup:   #config.runAsGroup
				fsGroup:      #config.runAsGroup
				runAsNonRoot: true
			}

			statefulWorkload: {
				// Single replica - SQLite, no horizontal scaling.
				scaling: count: 1
				restartPolicy: "Always"
				updateStrategy: {
					type: "RollingUpdate"
					rollingUpdate: {}
				}

				container: {
					name:  "radarr"
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
						if #config.env != _|_ {
							for k, v in #config.env {
								(k): {
									name:  k
									value: v
								}
							}
						}
					}

					// Servarr's /ping is unauthenticated and cheap.
					//
					// The startupProbe gates liveness AND readiness until the
					// app actually serves, and it is required rather than
					// belt-and-braces: first boot initializes or migrates the
					// SQLite database BEFORE opening the listener. Sonarr's
					// 200+ migrations outran a plain liveness delay and the
					// container was SIGKILLed mid-migration (exit 137,
					// "failed liveness probe"), observed on nas1 2026-07-29.
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
						initialDelaySeconds: 15
						periodSeconds:       10
						timeoutSeconds:      5
						failureThreshold:    5
					}

					// resources is conditionally set from component level — see
					// the hoisted guards above the spec block.

					// Container-scope security. These fields share
					// #SecurityContextSchema with the pod-level block above, but
					// the StatefulSet transformer only maps the identity fields
					// (runAsNonRoot/runAsUser/runAsGroup/fsGroup/supplementalGroups)
					// to the pod — the rest take effect only here.
					//
					// readOnlyRootFilesystem is deliberately NOT set: .NET writes
					// outside /config.
					securityContext: {
						allowPrivilegeEscalation: false
						capabilities: drop: ["ALL"]
					}

					volumeMounts: {
						for vName, v in _allVolumes {
							// _volumes[vName] already carries readOnly from the
							// volume source, so unifying propagates it here — the
							// two can never disagree by construction.
							(vName): _volumes[vName] & {
								mountPath: v.mountPath
							}
						}
					}
				}

				// All volumes rendered from _allVolumes via a type-switch.
				// accessMode/storageClass/readOnly carry no catalog defaults, so
				// every field must be set concretely — the release must finalize
				// to a fully concrete value before transformers run.
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

			// podScheduling and podMetadata are conditionally set from
			// component level — see the hoisted guards above the spec block.

			// Expose the web UI as a Service.
			expose: {
				ports: http: statefulWorkload.container.ports.http & {
					exposedPort: #config.port
				}
				type: #config.serviceType
				if #config.serviceName != _|_ {
					name: #config.serviceName
				}
			}

			// The optional HTTPRoute is written from the hoisted guards above
			// the spec block.
		}
	}
}
