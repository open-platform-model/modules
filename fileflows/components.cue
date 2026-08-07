// Components defines the FileFlows workload.
// Single stateful component with a persistent data volume, optional logs/temp
// and media mounts, a web Service, TCP health checks, and optional GPU /
// RuntimeClass / HTTPRoute wiring.
package fileflows

import (
	"list"

	bp "opmodel.dev/catalogs/opm/blueprints/workload"
	tr "opmodel.dev/catalogs/opm/traits"
)

// #components contains component definitions.
// Components reference #config which gets resolved to concrete values at build time.
#components: {

	/////////////////////////////////////////////////////////////////
	//// FileFlows - Stateful Processing Server
	/////////////////////////////////////////////////////////////////

	fileflows: {
		// StatefulWorkload composes the Container + Volumes resources and the
		// scaling / restart / init-container traits, and stamps the
		// workload-type=stateful label that selects the StatefulSet transformer.
		bp.#StatefulWorkload
		tr.#Expose
		tr.#SecurityContext

		// Attached unconditionally: #config gives terminationGracePeriodSeconds a
		// default, so the field is always concrete and there is nothing to guard.
		tr.#GracefulShutdown

		// Attached only when configured. Each is an optional trait on the
		// StatefulSet transformer, so leaving one off costs nothing — but
		// attaching unconditionally would leave a non-concrete field in the spec
		// and fail the render.
		if #config.httpRoute != _|_ {
			tr.#HttpRoute
		}

		// Attached only for NVIDIA. Attaching it unconditionally would leave
		// spec.runtimeClass non-concrete and fail the render, the same way an
		// always-attached #PodScheduling does.
		if _hwNvidia {
			tr.#RuntimeClass
		}
		if #config.podScheduling != _|_ {
			tr.#PodScheduling
		}
		if #config.podMetadata != _|_ {
			tr.#PodMetadata
		}

		metadata: name: "fileflows"

		// Bind the rendered volume set so volumeMounts can reuse each source.
		_volumes: spec.statefulWorkload.volumes

		// All storage entries flattened into one named map for uniform rendering.
		// `data` is always present; the rest are optional.
		_allVolumes: {
			data: #config.storage.data
			if #config.storage.logs != _|_ {
				logs: #config.storage.logs
			}
			if #config.storage.temp != _|_ {
				temp: #config.storage.temp
			}
			if #config.storage.media != _|_ {
				for name, v in #config.storage.media {
					(name): v
				}
			}
		}

		// Derived once and concrete in every branch: a non-concrete hidden field
		// would make the whole component fail to render the moment anything
		// referenced it.
		_hwEnabled: bool
		if #config.hardwareAcceleration == _|_ {
			_hwEnabled: false
		}
		if #config.hardwareAcceleration != _|_ {
			_hwEnabled: true
		}

		// Vendor keys as a concrete list, so membership can be tested without
		// dereferencing a field that may not exist.
		_hwVendors: [...string]
		if !_hwEnabled {
			_hwVendors: []
		}
		if _hwEnabled {
			_hwVendors: [for v, _ in #config.hardwareAcceleration.devices {v}]
		}

		// True when ANY attached card is NVIDIA — that alone decides the
		// RuntimeClass and the driver-capabilities env var, both of which are
		// pod-wide rather than per-device.
		_hwNvidia: list.Contains(_hwVendors, "nvidia")

		// Paths the fix-permissions init container chowns — exactly the volumes
		// it mounts, and no others.
		//
		// Nested guards rather than `temp == _|_ || temp.type == "nfs"`: a
		// disjunction evaluates BOTH arms, so the second still dereferences
		// `temp.type` when `temp` is absent. CUE rejects that with "cannot
		// reference optional field", and because this used to sit at package
		// scope it left the whole package non-concrete under a plain `cue vet`
		// — passing `-c=false` while jellyfin passed unqualified.
		_chownPaths: string
		if #config.storage.temp == _|_ {
			_chownPaths: #config.storage.data.mountPath
		}
		if #config.storage.temp != _|_ {
			if #config.storage.temp.type == "nfs" {
				_chownPaths: #config.storage.data.mountPath
			}
			if #config.storage.temp.type != "nfs" {
				_chownPaths: "\(#config.storage.data.mountPath) \(#config.storage.temp.mountPath)"
			}
		}
		_chownCmd: "chown -R \(#config.puid):\(#config.pgid) \(_chownPaths)"

		// One GPU claim per attached card, each with its extended-resource name
		// defaulted from the vendor key unless explicitly overridden.
		_hwClaims: [string]: {
			resource: string
			count:    uint & >0
		}
		if !_hwEnabled {
			_hwClaims: {}
		}
		if _hwEnabled {
			_hwClaims: {
				for v, d in #config.hardwareAcceleration.devices {
					(v): {
						count: d.count
						if d.resource != _|_ {
							resource: d.resource
						}
						if d.resource == _|_ {
							if v == "intel" {
								resource: "gpu.intel.com/i915"
							}
							if v == "nvidia" {
								resource: "nvidia.com/gpu"
							}
						}
					}
				}
			}
		}

		spec: {
			statefulWorkload: {
				// Single replica. FileFlows holds a SQLite database and a
				// singleton scheduler; a second server would not share work, it
				// would duplicate it.
				scaling: count: 1
				restartPolicy: "Always"
				updateStrategy: {
					type: "RollingUpdate"
					rollingUpdate: {}
				}

				// Fix ownership on every start so the volumes are writable by
				// PUID/PGID regardless of how they were provisioned.
				//
				// `data` always; `temp` only when it is NOT nfs. That exclusion is
				// deliberate: an NFS export with root_squash maps root to nobody,
				// so a chown from this root init container fails and takes the
				// whole pod down before FileFlows ever starts. NFS mounts must
				// already carry the right owner server-side. Media mounts are
				// never chowned for the same reason, and because recursively
				// chowning a media library is not something a module should do.
				initContainers: [
					{
						name: "fix-permissions"
						image: {
							repository: "busybox"
							tag:        "1.37"
							digest:     ""
						}
						command: ["/bin/sh", "-c", _chownCmd]
						volumeMounts: {
							data: _volumes.data & {
								mountPath: #config.storage.data.mountPath
							}
							if #config.storage.temp != _|_ if #config.storage.temp.type != "nfs" {
								temp: _volumes.temp & {
									mountPath: #config.storage.temp.mountPath
								}
							}
						}
					},

					// Stages a known-good FFmpeg tree into a shared emptyDir.
					//
					// `cp -a` and a trailing `/.` so symlinks, permissions and
					// the bundled lib/ survive the copy — a plain `cp` of the
					// binary alone would leave it unable to resolve its own
					// shared objects. The mount here is a staging path; the app
					// container mounts the same volume at the donor's original
					// location so nothing has to be told the tree moved.
					if #config.ffmpegInjection != _|_ {
						{
							name:  "ffmpeg-inject"
							image: #config.ffmpegInjection.image
							command: ["/bin/sh", "-c", "cp -a \(#config.ffmpegInjection.path)/. /inject/"]
							volumeMounts: "ffmpeg-bin": {
								name: "ffmpeg-bin"
								emptyDir: {}
								mountPath: "/inject"
								readOnly:  false
							}
						}
					},
				]

				container: {
					name:  "fileflows"
					image: #config.image
					ports: http: {
						name: "http"
						// Literal, not #config.port: that field is the SERVICE
						// port, and FileFlows listens on 5000 regardless.
						targetPort: 5000
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

						// NVIDIA only — Intel needs nothing here.
						//
						// ⚠ NVIDIA_VISIBLE_DEVICES is deliberately NOT set,
						// even though every upstream Docker example sets it to
						// `all`. Under Kubernetes the device plugin owns that
						// variable — it writes the UUID of the GPU it allocated
						// into the container's environment. Setting it in the pod
						// spec overrides that allocation and hands the container
						// every GPU on the node, quietly defeating the scheduler's
						// accounting.
						if _hwNvidia {
							NVIDIA_DRIVER_CAPABILITIES: {
								name:  "NVIDIA_DRIVER_CAPABILITIES"
								value: #config.hardwareAcceleration.driverCapabilities
							}
						}
					}

					// TCP rather than HTTP on all three: FileFlows publishes no
					// documented health endpoint, and probing the SPA root would
					// assert far more than liveness needs while risking a false
					// restart on any UI-route change across an image bump.
					startupProbe: {
						tcpSocket: port: 5000
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
						tcpSocket: port: 5000
						// 0: the startupProbe already holds liveness off until the
						// listener answers, so a second delay would only slow down
						// detection of a genuine hang.
						initialDelaySeconds: 0
						periodSeconds:       10
						timeoutSeconds:      5
						if #config.livenessFailureThreshold != _|_ {
							failureThreshold: #config.livenessFailureThreshold
						}
						if #config.livenessFailureThreshold == _|_ {
							failureThreshold: 6
						}
					}
					readinessProbe: {
						tcpSocket: port: 5000
						initialDelaySeconds: 10
						periodSeconds:       10
						timeoutSeconds:      5
						if #config.readinessFailureThreshold != _|_ {
							failureThreshold: #config.readinessFailureThreshold
						}
						if #config.readinessFailureThreshold == _|_ {
							failureThreshold: 3
						}
					}

					// The GPU claim is unified INTO whatever the instance set for
					// cpu/memory. The catalog emits it to requests AND limits,
					// which is what Kubernetes requires for an extended resource.
					if #config.resources != _|_ {
						resources: #config.resources
					}

					// Plural: one entry per attached card. The catalog emits each
					// to requests AND limits, which Kubernetes requires for
					// extended resources.
					if _hwEnabled {
						resources: gpus: _hwClaims
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

						// Built fresh rather than unified from _volumes, so
						// readOnly can be true here without conflicting with the
						// volume's own readOnly: false — the init container has
						// to write the tree before this container may read it.
						if #config.ffmpegInjection != _|_ {
							"ffmpeg-bin": {
								name: "ffmpeg-bin"
								emptyDir: {}
								mountPath: #config.ffmpegInjection.path
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
									// Read-only at the SOURCE, so the kernel mount
									// is ro rather than just this container's view.
									if v.readOnly {
										readOnly: true
									}
								}
							}
						}
					}

					// Scratch space for the injected FFmpeg tree. emptyDir, not
					// a PVC: it is rebuilt from the donor image on every start,
					// so persisting it would only let a stale copy outlive the
					// image pin that produced it.
					if #config.ffmpegInjection != _|_ {
						"ffmpeg-bin": {
							name:     "ffmpeg-bin"
							readOnly: false
							emptyDir: {}
						}
					}
				}
			}

			// Render-group GIDs, so the process can open /dev/dri/renderD*.
			// The legacy arm keeps an instance that still sets resources.gpu
			// directly rendering exactly as it did before.
			if _hwEnabled {
				securityContext: supplementalGroups: #config.hardwareAcceleration.renderGroups
			}
			if !_hwEnabled if #config.resources != _|_ if #config.resources.gpu != _|_ {
				securityContext: supplementalGroups: [44, 109]
			}

			// Long enough that a SIGTERM arriving mid-transcode is not escalated
			// to SIGKILL — see the schema field for why that matters.
			gracefulShutdown: terminationGracePeriodSeconds: #config.terminationGracePeriodSeconds

			// Passed through verbatim; the schemas are the catalog's own, so
			// there is nothing to translate.
			if _hwNvidia {
				runtimeClass: #config.hardwareAcceleration.runtimeClass
			}
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
		}
	}
}
