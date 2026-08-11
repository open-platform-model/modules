// Components defines the Jellyfin workload.
// Single stateful component with persistent config, optional media mounts,
// a web Service, health checks, and optional Serilog logging / hardware
// transcoding / HTTPRoute.
package jellyfin

import (
	"encoding/json"

	bp "opmodel.dev/catalogs/opm/blueprints/v1beta1"
	res "opmodel.dev/catalogs/opm/resources/v1beta1"
	tr "opmodel.dev/catalogs/opm/traits/v1beta1"
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

		// Only NVIDIA needs a non-default container runtime. Attaching this
		// unconditionally would leave spec.runtimeClass non-concrete and fail
		// the render, exactly like the traits above.
		if _hwNvidia {
			tr.#RuntimeClass
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

		// Hardware transcoding, resolved once here rather than re-derived at
		// each use site.
		//
		// Every branch below assigns a CONCRETE value, including the disabled
		// one. A hidden field left at `bool` or `string` is fine only until
		// something references it — at which point the whole component renders
		// non-concrete and the release fails to finalize.
		_hwEnabled: bool
		if #config.hardwareAcceleration == _|_ {
			_hwEnabled: false
		}
		if #config.hardwareAcceleration != _|_ {
			_hwEnabled: true
		}

		// Split out from the vendor so every NVIDIA-only branch reads the same
		// way and none of them has to re-test whether the block exists at all.
		_hwNvidia: bool
		if !_hwEnabled {
			_hwNvidia: false
		}
		if _hwEnabled {
			if #config.hardwareAcceleration.vendor == "nvidia" {
				_hwNvidia: true
			}
			if #config.hardwareAcceleration.vendor != "nvidia" {
				_hwNvidia: false
			}
		}

		// The extended resource the device plugin advertises. The explicit
		// override wins; otherwise it derives from the vendor.
		_hwResource: string
		if !_hwEnabled {
			_hwResource: ""
		}

		if _hwEnabled {
			if #config.hardwareAcceleration.resource != _|_ {
				_hwResource: #config.hardwareAcceleration.resource
			}
			if #config.hardwareAcceleration.resource == _|_ {
				if #config.hardwareAcceleration.vendor == "intel" {
					_hwResource: "gpu.intel.com/i915"
				}
				if #config.hardwareAcceleration.vendor == "nvidia" {
					_hwResource: "nvidia.com/gpu"
				}
			}
		}

		// Conditional struct- and list-valued spec fields, HOISTED to component
		// level rather than guarded inside the spec block — the in-spec form
		// trips the CUE v0.17 closedness regression on the v2 catalog's closed
		// blueprint spec (catalog CLAUDE.md authoring pitfall; see
		// docs/cue-guard-closedness-workaround.md there). Do not inline these.

		if #config.publishedServerUrl != _|_ {
			spec: statefulWorkload: container: env: JELLYFIN_PublishedServerUrl: {
				name:  "JELLYFIN_PublishedServerUrl"
				value: #config.publishedServerUrl
			}
		}

		// Emitted only for NVIDIA, i.e. only where a runtime reads it. See the
		// schema field for why `video` and `compute` both matter, and why
		// NVIDIA_VISIBLE_DEVICES is never set here.
		if _hwNvidia {
			spec: statefulWorkload: container: env: NVIDIA_DRIVER_CAPABILITIES: {
				name:  "NVIDIA_DRIVER_CAPABILITIES"
				value: #config.hardwareAcceleration.driverCapabilities
			}
		}

		if #config.resources != _|_ {
			spec: statefulWorkload: container: resources: #config.resources
		}

		// Unified INTO whatever the instance set for cpu/memory rather than
		// replacing it, so the two can be written independently. The catalog
		// emits the claim to requests AND limits, which is what Kubernetes
		// requires for an extended resource — they cannot be overcommitted.
		//
		// An instance that ALSO writes resources.gpu by hand with different
		// values fails here on a CUE conflict. That is the intended outcome:
		// two disagreeing declarations of which card to use should not resolve
		// last-one-wins.
		if _hwEnabled {
			spec: statefulWorkload: container: resources: gpu: {
				resource: _hwResource
				count:    #config.hardwareAcceleration.count
			}
		}

		// Serilog logging config — ConfigMap, its volume, and the subPath
		// mount, all only when logging is configured. The mount is built fresh
		// (not unified from _volumes) so readOnly can be true without
		// conflicting with the volume's readOnly: false.
		if #config.logging != _|_ {
			spec: statefulWorkload: container: volumeMounts: "jellyfin-logging": {
				name:      "jellyfin-logging"
				configMap: spec.configMaps["jellyfin-logging"]
				mountPath: "/config/logging.json"
				subPath:   "logging.json"
				readOnly:  true
			}
		}
		if #config.logging != _|_ {
			spec: statefulWorkload: volumes: "jellyfin-logging": {
				name:      "jellyfin-logging"
				readOnly:  false
				configMap: spec.configMaps["jellyfin-logging"]
			}
		}
		if #config.logging != _|_ {
			spec: configMaps: "jellyfin-logging": {
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

		// Render-group supplemental GIDs, so the process can open
		// /dev/dri/renderD*. Only meaningful when a device is attached.
		if _hwEnabled {
			spec: securityContext: supplementalGroups: #config.hardwareAcceleration.renderGroups
		}

		// Legacy arm: an instance claiming a device through resources.gpu
		// directly, as everything before v2.5.0 had to. Kept so those
		// instances render exactly as they did, and guarded on !_hwEnabled
		// so the two can never both assign supplementalGroups.
		if !_hwEnabled if #config.resources != _|_ if #config.resources.gpu != _|_ {
			spec: securityContext: supplementalGroups: [44, 109]
		}

		// Passed through verbatim; the schemas are the catalog's own, so
		// there is nothing to translate.
		if #config.podScheduling != _|_ {
			spec: podScheduling: #config.podScheduling
		}
		if #config.podMetadata != _|_ {
			spec: podMetadata: #config.podMetadata
		}

		// Optional HTTPRoute, with the two-level form for the nested
		// optional gatewayRef.
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
						// JELLYFIN_PublishedServerUrl and
						// NVIDIA_DRIVER_CAPABILITIES are conditionally set from
						// component level — see the hoisted guards above the
						// spec block.
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
					// resources (both the instance's requests/limits and the
					// derived GPU claim) are conditionally set from component
					// level — see the hoisted guards above the spec block.
					volumeMounts: {
						for vName, v in _allVolumes
						// The Serilog logging config subPath mount is
						// conditionally set from component level — see the
						// hoisted guards above the spec block.
						{
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
					for name, v in _allVolumes
					// The logging ConfigMap volume is conditionally set from
					// component level — see the hoisted guards above the spec
					// block.
					{
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
				}
			}

			// securityContext.supplementalGroups (both the hardware-
			// acceleration arm and the legacy resources.gpu arm) is
			// conditionally set from component level — see the hoisted guards
			// above the spec block.

			// NVIDIA only — Intel devices work under the default runtime.
			// Stays in-spec: runtimeClass is a scalar (string) write, which
			// the closedness regression does not affect.
			if _hwNvidia {
				runtimeClass: #config.hardwareAcceleration.runtimeClass
			}

			// Long enough that a SIGTERM arriving mid-VACUUM waits for the
			// database rather than turning into a SIGKILL through an in-flight
			// SQLite write — see the schema field for the numbers.
			gracefulShutdown: terminationGracePeriodSeconds: #config.terminationGracePeriodSeconds

			// Expose the web UI as a Service.
			expose: {
				ports: http: statefulWorkload.container.ports.http & {
					exposedPort: #config.port
				}
				type: #config.serviceType
			}

			// podScheduling, podMetadata, the optional HTTPRoute and the
			// Serilog logging ConfigMap are written from the hoisted guards
			// above the spec block.
		}
	}
}
