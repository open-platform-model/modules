// Components defines the Jellyfin workload.
// Single stateful component with persistent config, optional media mounts,
// a web Service, health checks, and optional Serilog logging / GPU / HTTPRoute.
package jellyfin

import (
	"encoding/json"

	bp "opmodel.dev/catalogs/opm/blueprints/workload"
	res "opmodel.dev/catalogs/opm/resources"
	tr "opmodel.dev/catalogs/opm/traits"
)

// #components contains component definitions.
// Components reference #config which gets resolved to concrete values at build time.
#components: {

	/////////////////////////////////////////////////////////////////
	//// Jellyfin - Stateful Media Server
	/////////////////////////////////////////////////////////////////

	jellyfin: {
		// StatefulWorkload composes the Container + Volumes resources and the
		// scaling / restart / init-container traits, and stamps the
		// workload-type=stateful label that selects the StatefulSet transformer.
		bp.#StatefulWorkload
		tr.#Expose
		tr.#SecurityContext
		res.#ConfigMaps

		// Attached unconditionally, unlike the optional traits below: #config
		// gives terminationGracePeriodSeconds a default, so the field is always
		// concrete and there is nothing to guard against.
		tr.#GracefulShutdown

		// HTTPRoute trait only when ingress is requested.
		if #config.httpRoute != _|_ {
			tr.#HttpRoute
		}

		// Attached only when configured. Both are optional traits on the
		// StatefulSet transformer, so leaving one off costs nothing — but
		// attaching unconditionally would leave a non-concrete field in the
		// spec and fail the render, the same way an always-attached
		// #DisruptionBudget does.
		if #config.podScheduling != _|_ {
			tr.#PodScheduling
		}
		if #config.podMetadata != _|_ {
			tr.#PodMetadata
		}

		metadata: name: "jellyfin"

		// Bind the rendered volume set so volumeMounts can reuse each source.
		_volumes: spec.statefulWorkload.volumes

		// All storage entries flattened into one named map for uniform rendering.
		// config is always present; media entries are optional.
		_allVolumes: {
			config: #config.storage.config
			if #config.storage.media != _|_ {
				for name, v in #config.storage.media {
					(name): v
				}
			}
		}

		spec: {
			statefulWorkload: {
				// Single replica - Jellyfin does not support horizontal scaling.
				scaling: count: 1
				restartPolicy: "Always"
				updateStrategy: {
					type: "RollingUpdate"
					rollingUpdate: {}
				}

				// Fix file ownership on every start so /config is writable by
				// the LinuxServer.io PUID/PGID regardless of how the PVC was
				// provisioned.
				initContainers: [{
					name: "fix-permissions"
					image: {
						repository: "busybox"
						tag:        "1.37"
						digest:     ""
					}
					command: ["/bin/sh", "-c", "chown -R \(#config.puid):\(#config.pgid) \(#config.storage.config.mountPath)"]
					volumeMounts: config: _volumes.config & {
						mountPath: #config.storage.config.mountPath
					}
				}]

				container: {
					name:  "jellyfin"
					image: #config.image
					ports: http: {
						name:       "http"
						targetPort: 8096
					}
					env: {
						PUID: {
							name:  "PUID"
							value: "\(#config.puid)"
						}
						PGID: {
							name:  "PGID"
							value: "\(#config.pgid)"
						}
						TZ: {
							name:  "TZ"
							value: #config.timezone
						}
						JELLYFIN_DATA_DIR: {
							name:  "JELLYFIN_DATA_DIR"
							value: #config.storage.config.mountPath
						}
						if #config.publishedServerUrl != _|_ {
							JELLYFIN_PublishedServerUrl: {
								name:  "JELLYFIN_PublishedServerUrl"
								value: #config.publishedServerUrl
							}
						}
					}
					// Every threshold here is sized to ride out a VACUUM rather
					// than restart through one — Jellyfin's own "Optimize
					// database" task blocks /health for its whole run. The
					// measurements and the reasoning are on the schema fields in
					// module.cue; the short version is that the previous 30s
					// liveness budget lost to a 45s vacuum, four times a day.
					//
					// Probe port stays literal 8096 rather than #config.port:
					// that field is the SERVICE port (see exposedPort below), and
					// the container listens on 8096 regardless of what it is set
					// to. Same reason targetPort above is literal.
					startupProbe: {
						httpGet: {
							path: #config.healthPath
							port: 8096
						}
						initialDelaySeconds: 10
						periodSeconds:       10
						timeoutSeconds:      5
						// Guarded rather than defaulted. Both arms must set a
						// CONCRETE value, because the arm that unifies with
						// #ProbeSchema's `uint | *3` is where a second default
						// would make the render ambiguous.
						if #config.startupFailureThreshold != _|_ {
							failureThreshold: #config.startupFailureThreshold
						}
						if #config.startupFailureThreshold == _|_ {
							failureThreshold: 30
						}
					}
					livenessProbe: {
						httpGet: {
							path: #config.healthPath
							port: 8096
						}
						// 0: the startupProbe above already holds liveness off
						// until the app answers, so a second delay would only
						// slow down detection of a genuine hang.
						initialDelaySeconds: 0
						periodSeconds:       10
						timeoutSeconds:      5
						if #config.livenessFailureThreshold != _|_ {
							failureThreshold: #config.livenessFailureThreshold
						}
						if #config.livenessFailureThreshold == _|_ {
							failureThreshold: 18
						}
					}
					readinessProbe: {
						httpGet: {
							path: #config.healthPath
							port: 8096
						}
						initialDelaySeconds: 10
						periodSeconds:       10
						// 5 not 3: a probe that has to wait on the database
						// should not be scored a failure just for being slow.
						timeoutSeconds: 5
						if #config.readinessFailureThreshold != _|_ {
							failureThreshold: #config.readinessFailureThreshold
						}
						if #config.readinessFailureThreshold == _|_ {
							failureThreshold: 12
						}
					}
					if #config.resources != _|_ {
						resources: #config.resources
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

						// Serilog logging config — mounted as a single file via subPath.
						// Built fresh (not unified from _volumes) so readOnly can be
						// true without conflicting with the volume's readOnly: false.
						if #config.logging != _|_ {
							"jellyfin-logging": {
								name:      "jellyfin-logging"
								configMap: spec.configMaps["jellyfin-logging"]
								mountPath: "/config/logging.json"
								subPath:   "logging.json"
								readOnly:  true
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
							"name": name
							// From #storageVolume, which defaults it to false — so
							// this stays concrete and existing instances render
							// exactly as before.
							readOnly: v.readOnly
							if v.type == "pvc" {
								// NOTE: #PersistentClaimSchema carries no readOnly, so a
								// PVC-backed volume can only be made read-only at the
								// MOUNT. Enough to stop this container writing; it does
								// not harden the volume against another container in the
								// same pod. Catalog gap; NFS below does both.
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
									// Read-only at the SOURCE, so the kernel mount
									// itself is ro rather than just this container's
									// view of it. This is the half that actually
									// protects a shared media dataset.
									if v.readOnly {
										readOnly: true
									}
								}
							}
						}
					}

					// Logging ConfigMap volume — only when logging is configured.
					if #config.logging != _|_ {
						"jellyfin-logging": {
							name:      "jellyfin-logging"
							readOnly:  false
							configMap: spec.configMaps["jellyfin-logging"]
						}
					}
				}
			}

			// Intel GPU — add render group supplemental GIDs for DRI device access.
			if #config.resources != _|_ if #config.resources.gpu != _|_ {
				securityContext: supplementalGroups: [44, 109]
			}

			// Long enough that a SIGTERM arriving mid-VACUUM waits for the
			// database rather than turning into a SIGKILL through an in-flight
			// SQLite write — see the schema field for the numbers.
			gracefulShutdown: terminationGracePeriodSeconds: #config.terminationGracePeriodSeconds

			// Passed through verbatim; the schemas are the catalog's own, so
			// there is nothing to translate.
			if #config.podScheduling != _|_ {
				podScheduling: #config.podScheduling
			}
			if #config.podMetadata != _|_ {
				podMetadata: #config.podMetadata
			}

			// Expose the web UI as a Service.
			expose: {
				ports: http: statefulWorkload.container.ports.http & {
					exposedPort: #config.port
				}
				type: #config.serviceType
			}

			// Optional HTTPRoute.
			if #config.httpRoute != _|_ {
				httpRoute: {
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
					if #config.httpRoute.gatewayRef != _|_ {
						gatewayRef: #config.httpRoute.gatewayRef
					}
				}
			}

			// Serilog logging config injected as a ConfigMap — only when configured.
			if #config.logging != _|_ {
				configMaps: {
					"jellyfin-logging": {
						immutable: false
						data: {
							"logging.json": "\(json.Marshal({
								Serilog: {
									MinimumLevel: {
										Default: #config.logging.defaultLevel
										if #config.logging.overrides != _|_ {
											Override: #config.logging.overrides
										}
									}
								}
							}))"
						}
					}
				}
			}
		}
	}
}
