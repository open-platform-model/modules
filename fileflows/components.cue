// Components defines the FileFlows workloads.
//
//   - opm-secrets: the module's Secret, rendered only when accessToken is set.
//     Named exactly "opm-secrets" on purpose — the secret transformer renders
//     that component's secrets as {instance}-{secretName}, which is the only
//     shape a container's `env.from` secretKeyRef resolves to. Any other
//     component name renders {instance}-{component}-{secretName} and every env
//     ref points at an object that does not exist.
//   - fileflows: the server. Stateful, with a persistent data volume, optional
//     logs/temp and media mounts, a web Service, TCP health checks, and
//     optional GPU / RuntimeClass / HTTPRoute wiring.
//   - node-<key>: one stateless worker per #config.nodes entry. No Service, no
//     probes, no data volume — it dials the server and runs flows.
package fileflows

import (
	"list"

	bp "opmodel.dev/catalogs/opm/blueprints/v1beta1"
	res "opmodel.dev/catalogs/opm/resources/v1beta1"
	tr "opmodel.dev/catalogs/opm/traits/v1beta1"
)

// NOTE ON ENFORCING accessToken — the obvious spelling does not work.
//
// A package-scope guard of the shape
//
//     _validate: {
//         if len(#config.nodes) > 0 {
//             accessTokenIsRequired: #config.accessToken
//         }
//     }
//
// is INERT. It reads correctly and it does produce the right error when
// evaluated by hand, but nothing in the build path ever evaluates it: hidden
// fields are not rendered, and CUE does not evaluate what nothing references.
// Measured — with nodes defined and no token, `cue vet`, `cue vet -c` AND
// `cue export -e '#components'` all exit 0.
//
// The requirement is therefore enforced where it cannot be skipped: each node
// container references #config.accessToken UNCONDITIONALLY (see the env block
// below), so a node without a token fails to render, naming the field.
//
// Unconditional is also correct on the merits, not just convenient. The server
// always holds an AccessToken value; security being off only means it does not
// check it. Sending one to a server that ignores it is harmless, so there is no
// configuration where requiring it for a node costs anything — while omitting
// it under security produces a Running pod, a valid render, and a server that
// simply never sees the node.

// #GpuClaims turns a concrete `devices` map into one extended-resource claim per
// card, defaulting the resource name from the vendor key unless overridden.
//
// A definition rather than a hidden field: the server component and every
// generated node need identical claim derivation, and package-scope hidden
// REGULAR fields are what left this package non-concrete under a plain
// `cue vet` before (see _chownPaths below). Definitions are not
// concreteness-checked, so they are safe here.
//
// Callers resolve the optional `hardwareAcceleration` themselves and pass only
// `devices`, so no optional dereference crosses this boundary.
#GpuClaims: {
	// ⚠ OPEN, deliberately — see the note on #VolumeSources.#in.
	#in!: {...}
	out: {
		for v, d in #in {
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

// #VolumeSources renders a map of #storageVolume entries into catalog volume
// sources via a type-switch. accessMode/storageClass/readOnly carry no catalog
// defaults, so every field is set concretely — the release must finalize to a
// fully concrete value before transformers run.
#VolumeSources: {
	// ⚠ `#in!: {...}` — OPEN, NOT `#in!: [string]: #storageVolume`, and the
	// difference is load-bearing rather than stylistic. A pattern constraint on a
	// definition's map input DROPS the concrete value of any entry the caller
	// produced by a comprehension: the entry arrives as `_` and every guard below
	// fails with
	//     v.type undefined as v is incomplete (type _)
	// Both callers build their input with `for name, v in ...` comprehensions, so
	// the pattern-constrained form fails for all of them. Type discipline lives at
	// the call site instead, where entries are #storageVolume by construction.
	#in!: {...}
	out: {
		for name, v in #in {
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
						// Read-only at the SOURCE, so the kernel mount is ro rather
						// than just this container's view.
						if v.readOnly {
							readOnly: true
						}
					}
				}
			}
		}
	}
}

// #components contains component definitions.
// Components reference #config which gets resolved to concrete values at build time.
#components: {

	/////////////////////////////////////////////////////////////////
	//// Secrets - the processing-node access token
	/////////////////////////////////////////////////////////////////

	// Guarded: an instance with no nodes needs no token, and an unguarded
	// #AutoSecrets over an empty result renders an empty Secret object.
	if #config.accessToken != _|_ {
		"opm-secrets": {
			res.#Secrets

			metadata: name: "opm-secrets"

			// #AutoSecrets walks #config, collects every field carrying the $opm
			// discriminator and groups it by $secretName/$dataKey. An entry
			// supplied as #SecretK8sRef is skipped by the transformer, so
			// pointing accessToken at a pre-existing cluster Secret emits
			// nothing here and wires the env ref straight through.
			spec: secrets: {
				for _secretName, _data in (res.#AutoSecrets & {#in: #config}).out {
					(_secretName): {
						name: _secretName
						data: _data
					}
				}
			}
		}
	}

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
			_hwClaims: (#GpuClaims & {#in: #config.hardwareAcceleration.devices}).out
		}

		// Conditional struct- and list-valued spec fields, HOISTED to component
		// level rather than guarded inside the spec block — the in-spec form
		// trips the CUE v0.17 closedness regression on the v2 catalog's closed
		// blueprint spec (catalog CLAUDE.md authoring pitfall; see
		// docs/cue-guard-closedness-workaround.md there). Do not inline these.

		// The GPU claim is unified INTO whatever the instance set for
		// cpu/memory. The catalog emits each claim to requests AND limits,
		// which is what Kubernetes requires for an extended resource.
		if #config.resources != _|_ {
			spec: statefulWorkload: container: resources: #config.resources
		}
		if _hwEnabled {
			spec: statefulWorkload: container: resources: gpus: _hwClaims
		}

		// NVIDIA only — Intel needs nothing here.
		//
		// ⚠ NVIDIA_VISIBLE_DEVICES is deliberately NOT set, even though every
		// upstream Docker example sets it to `all`. Under Kubernetes the device
		// plugin owns that variable — it writes the UUID of the GPU it
		// allocated into the container's environment. Setting it in the pod
		// spec overrides that allocation and hands the container every GPU on
		// the node, quietly defeating the scheduler's accounting.
		if _hwNvidia {
			spec: statefulWorkload: container: env: NVIDIA_DRIVER_CAPABILITIES: {
				name:  "NVIDIA_DRIVER_CAPABILITIES"
				value: #config.hardwareAcceleration.driverCapabilities
			}
		}

		if #config.ffmpegInjection != _|_ {
			// Built fresh rather than unified from _volumes, so readOnly can be
			// true here without conflicting with the volume's own readOnly:
			// false — the init container has to write the tree before this
			// container may read it.
			spec: statefulWorkload: container: volumeMounts: "ffmpeg-bin": {
				name: "ffmpeg-bin"
				emptyDir: {}
				mountPath: #config.ffmpegInjection.path
				readOnly:  true
			}

			// Scratch space for the injected FFmpeg tree. emptyDir, not a PVC:
			// it is rebuilt from the donor image on every start, so persisting
			// it would only let a stale copy outlive the image pin that
			// produced it.
			spec: statefulWorkload: volumes: "ffmpeg-bin": {
				name:     "ffmpeg-bin"
				readOnly: false
				emptyDir: {}
			}
		}

		// Render-group GIDs, so the process can open /dev/dri/renderD*.
		// The legacy arm keeps an instance that still sets resources.gpu
		// directly rendering exactly as it did before.
		if _hwEnabled {
			spec: securityContext: supplementalGroups: #config.hardwareAcceleration.renderGroups
		}
		if !_hwEnabled if #config.resources != _|_ if #config.resources.gpu != _|_ {
			spec: securityContext: supplementalGroups: [44, 109]
		}

		// Passed through verbatim; the schemas are the catalog's own, so there
		// is nothing to translate.
		if #config.podScheduling != _|_ {
			spec: podScheduling: #config.podScheduling
		}
		if #config.podMetadata != _|_ {
			spec: podMetadata: #config.podMetadata
		}

		// Optional HTTPRoute.
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

						// NVIDIA_DRIVER_CAPABILITIES is conditionally set from
						// component level — see the hoisted guards above the
						// spec block.
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

					// resources (cpu/memory and GPU claims) are conditionally set
					// from component level — see the hoisted guards above the
					// spec block.

					volumeMounts: {
						for vName, v in _allVolumes
						// The optional ffmpeg-bin mount is written from the
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

				// All volumes rendered from _allVolumes via the shared type-switch.
				// The optional ffmpeg-bin volume is written from the hoisted
				// guards above the spec block.
				volumes: {
					(#VolumeSources & {#in: _allVolumes}).out
				}
			}

			// securityContext.supplementalGroups is conditionally set from
			// component level — see the hoisted guards above the spec block.

			// Long enough that a SIGTERM arriving mid-transcode is not escalated
			// to SIGKILL — see the schema field for why that matters.
			gracefulShutdown: terminationGracePeriodSeconds: #config.terminationGracePeriodSeconds

			// Passed through verbatim; the schema is the catalog's own, so
			// there is nothing to translate. Scalar, so it may stay in-spec.
			if _hwNvidia {
				runtimeClass: #config.hardwareAcceleration.runtimeClass
			}

			// podScheduling / podMetadata / httpRoute are written from the
			// hoisted guards above the spec block.

			// Expose the web UI as a Service.
			expose: {
				ports: http: statefulWorkload.container.ports.http & {
					exposedPort: #config.port
				}
				type: #config.serviceType
			}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// FileFlows - External Processing Nodes (one per #config.nodes entry)
	/////////////////////////////////////////////////////////////////

	// Dynamic component generation from a config map. Legal and supported:
	// #ModuleInstance unifies #config BEFORE reading #components
	// (core/src/module_instance.cue:79-94), so this comprehension materialises.
	// Read the other way round it would silently yield zero components.
	for _k, _n in #config.nodes {
		"node-\(_k)": {
			// STATELESS, not stateful, and the choice is load-bearing:
			//   - a node holds no durable state; it re-fetches its configuration
			//     from the server on every start, and its temp is scratch.
			//   - the StatefulSet transformer emits
			//     `serviceName: {instance}-{component}` unconditionally, so a
			//     StatefulSet here would point its governing Service at an
			//     object that is deliberately never created.
			// #StatelessWorkloadSchema carries no `volumes` field, so res.#Volumes
			// is composed separately and volumes live at spec.volumes — the shape
			// proven by modules/nvidia_device_plugin.
			bp.#StatelessWorkload
			res.#Volumes
			tr.#SecurityContext

			// Unconditional: _grace below always resolves to a concrete value,
			// because the server's field carries a default.
			tr.#GracefulShutdown

			// Per node, not per module: the NVIDIA node gets a RuntimeClass and
			// the Intel ones must not. Attaching unconditionally would leave
			// spec.runtimeClass non-concrete and fail the render.
			if _hwNvidia {
				tr.#RuntimeClass
			}
			if _n.podScheduling != _|_ {
				tr.#PodScheduling
			}
			if _n.podMetadata != _|_ {
				tr.#PodMetadata
			}

			metadata: name: "node-\(_k)"

			// Volumes live at component level for a stateless workload.
			_volumes: spec.volumes

			// A node mounts its own temp plus the SAME media paths as the server.
			// Identical mount paths across every pod is exactly what makes
			// FileFlows' NodeMappings unnecessary.
			//
			// Deliberately NOT `data` or `logs`: both are the server's RWO
			// volumes — `data` holds the SQLite database, and two writers would
			// fight over either.
			_allVolumes: {
				temp: _n.temp
				if #config.storage.media != _|_ {
					for name, v in #config.storage.media {
						(name): v
					}
				}
			}

			// Same derivation as the server's, but over THIS node's cards. Kept
			// inline rather than lifted into a definition because it dereferences
			// an optional field — that has to be resolved on this side of any
			// definition boundary (see #GpuClaims).
			_hwEnabled: bool
			if _n.hardwareAcceleration == _|_ {
				_hwEnabled: false
			}
			if _n.hardwareAcceleration != _|_ {
				_hwEnabled: true
			}

			_hwVendors: [...string]
			if !_hwEnabled {
				_hwVendors: []
			}
			if _hwEnabled {
				_hwVendors: [for v, _ in _n.hardwareAcceleration.devices {v}]
			}
			_hwNvidia: list.Contains(_hwVendors, "nvidia")

			_hwClaims: [string]: {
				resource: string
				count:    uint & >0
			}
			if !_hwEnabled {
				_hwClaims: {}
			}
			if _hwEnabled {
				_hwClaims: (#GpuClaims & {#in: _n.hardwareAcceleration.devices}).out
			}

			// ⚠ BUILT FROM #ctx.instance, NOT #ctx.components.fileflows.dns.fqdn.
			// The latter derives from metadata.resourceName ("fileflows") while
			// the rendered Service is "{instance}-{component}"
			// ("fileflows-fileflows"), so it would produce a name that does not
			// resolve — and the only symptom would be nodes that never register.
			// See #config.serverUrl.
			_serverUrl: string
			if #config.serverUrl != _|_ {
				_serverUrl: #config.serverUrl
			}
			if #config.serverUrl == _|_ {
				_serverUrl: "http://\(#ctx.instance.name)-fileflows.\(#ctx.instance.namespace).svc.\(#ctx.instance.clusterDomain):\(#config.port)"
			}

			_nodeName: string
			if _n.nodeName != _|_ {
				_nodeName: _n.nodeName
			}
			if _n.nodeName == _|_ {
				_nodeName: _k
			}

			// Set-it-or-inherit-it, never a partial merge.
			//
			// The obvious `*#config.terminationGracePeriodSeconds | uint` spelling
			// in the schema reads as "override, defaulting to the server value"
			// and means something worse: on a PARTIAL override of a struct the
			// default arm evaluates to bottom, the disjunction falls through to
			// the bare type, and required fields silently vanish. The list-index
			// form has no such failure mode.
			_grace: [
				if _n.terminationGracePeriodSeconds != _|_ {_n.terminationGracePeriodSeconds},
				#config.terminationGracePeriodSeconds,
			][0]

			// Conditional struct- and list-valued spec fields, HOISTED to
			// component level rather than guarded inside the spec block — the
			// in-spec form trips the CUE v0.17 closedness regression on the v2
			// catalog's closed blueprint spec (catalog CLAUDE.md authoring
			// pitfall; see docs/cue-guard-closedness-workaround.md there). Do
			// not inline these.

			// `enabled: false` parks the node: the pod goes away and RELEASES
			// ITS GPU while the entry stays in git.
			if _n.enabled {
				spec: statelessWorkload: scaling: count: 1
			}
			if !_n.enabled {
				spec: statelessWorkload: scaling: count: 0
			}

			if _n.resources != _|_ {
				spec: statelessWorkload: container: resources: _n.resources
			}
			if _hwEnabled {
				spec: statelessWorkload: container: resources: gpus: _hwClaims
			}

			if _n.runners != _|_ {
				spec: statelessWorkload: container: env: NodeRunnerCount: {
					name:  "NodeRunnerCount"
					value: "\(_n.runners)"
				}
			}

			// NVIDIA only. NVIDIA_VISIBLE_DEVICES stays unset for the same
			// reason as on the server: the device plugin owns it, and setting
			// it hands the container every GPU on the host.
			if _hwNvidia {
				spec: statelessWorkload: container: env: NVIDIA_DRIVER_CAPABILITIES: {
					name:  "NVIDIA_DRIVER_CAPABILITIES"
					value: _n.hardwareAcceleration.driverCapabilities
				}
			}

			if #config.ffmpegInjection != _|_ {
				spec: volumes: "ffmpeg-bin": {
					name:     "ffmpeg-bin"
					readOnly: false
					emptyDir: {}
				}

				// Built fresh rather than unified from _volumes, so readOnly
				// can be true here without conflicting with the volume's own
				// readOnly: false.
				spec: statelessWorkload: container: volumeMounts: "ffmpeg-bin": {
					name: "ffmpeg-bin"
					emptyDir: {}
					mountPath: #config.ffmpegInjection.path
					readOnly:  true
				}
			}

			if _hwEnabled {
				spec: securityContext: supplementalGroups: _n.hardwareAcceleration.renderGroups
			}

			if _n.podScheduling != _|_ {
				spec: podScheduling: _n.podScheduling
			}
			if _n.podMetadata != _|_ {
				spec: podMetadata: _n.podMetadata
			}

			spec: {
				// The optional ffmpeg-bin volume is written from the hoisted
				// guards above the spec block.
				volumes: {
					(#VolumeSources & {#in: _allVolumes}).out
				}

				statelessWorkload: {
					// scaling.count is written from the hoisted enabled/parked
					// guards above the spec block.
					restartPolicy: "Always"

					// ⚠ RECREATE, NOT ROLLINGUPDATE, and this is not a style
					// choice. A rolling update would start the replacement pod
					// while the outgoing one still holds its GPU. Kubernetes does
					// not preempt extended resources, so the new pod sits Pending
					// forever waiting for a card the old pod will not release
					// until the new one is Ready — a silent, permanent deadlock.
					updateStrategy: type: "Recreate"

					initContainers: [
						// Only when temp is chownable. An NFS export with
						// root_squash maps root to nobody, so the chown fails and
						// takes the pod down before FileFlows starts; NFS mounts
						// must already carry the right owner server-side.
						//
						// Worth keeping even though the image entrypoint chowns
						// /temp itself: it does so as `2>/dev/null || true`, which
						// turns a permissions problem into flows that fail at
						// their first write. This fails loudly instead.
						//
						// There is nothing else to chown — a node carries no
						// `data` volume, and media is never chowned.
						if _n.temp.type != "nfs" {
							{
								name: "fix-permissions"
								image: {
									repository: "busybox"
									tag:        "1.37"
									digest:     ""
								}
								command: ["/bin/sh", "-c", "chown -R \(#config.puid):\(#config.pgid) \(_n.temp.mountPath)"]
								volumeMounts: temp: _volumes.temp & {
									mountPath: _n.temp.mountPath
								}
							}
						},

						// A node runs the transcode, so it needs the same FFmpeg
						// the server was given. Inherited, never overridden: the
						// `FFmpeg` variable is one server-wide string, so the tree
						// has to sit at the same path on every pod.
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
						name: "fileflows-node"

						// ⚠ INHERITED FROM THE SERVER, deliberately not
						// overridable. FileFlows enforces version lockstep with
						// its own auto-updater: a node whose version differs
						// downloads an update into /app/NodeUpdate, a container
						// layer discarded on every restart — so a divergent tag
						// is a permanent update loop, not a one-off upgrade.
						image: #config.image

						// NO PORTS AND NO PROBES, on purpose. FileFlows.Node.dll
						// carries no HTTP listener — it dials out to the server
						// and holds a SignalR connection. The entrypoint ends in
						// `wait $dotnet_pid`, so container exit tracks process
						// exit and restartPolicy covers death. Any probe here
						// would be asserting against nothing.
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

							// Selects node mode in the shared entrypoint, which
							// tests `FFNODE == 'true' || FFNODE == '1'` and then
							// launches FileFlows.Node.dll instead of the server.
							FFNODE: {
								name:  "FFNODE"
								value: "1"
							}
							ServerUrl: {
								name:  "ServerUrl"
								value: _serverUrl
							}
							NodeName: {
								name:  "NodeName"
								value: _nodeName
							}

							// Always set explicitly: the node binary's own
							// built-in default is /mnt/temp, which nothing here
							// mounts and nothing chowns.
							TempPath: {
								name:  "TempPath"
								value: _n.temp.mountPath
							}

							// The optional NodeRunnerCount is written from the
							// hoisted guards above the spec block.

							// Sent as an x-token header when the node registers.
							//
							// ⚠ DELIBERATELY UNGUARDED. Wrapping this in
							// `if #config.accessToken != _|_` would render a
							// tokenless node perfectly happily, and the only
							// symptom would be a Running pod the server never
							// sees. This reference is what makes the token
							// required for nodes — see the note at the top of
							// this file for why the guard cannot live anywhere
							// else.
							AccessToken: {
								name: "AccessToken"
								from: #config.accessToken
							}

							// NVIDIA_DRIVER_CAPABILITIES is conditionally set
							// from component level — see the hoisted guards
							// above the spec block.
						}

						// resources (cpu/memory and GPU claims) are conditionally
						// set from component level — see the hoisted guards above
						// the spec block.

						volumeMounts: {
							for vName, v in _allVolumes
							// The optional ffmpeg-bin mount is written from the
							// hoisted guards above the spec block.
							{
								(vName): _volumes[vName] & {
									mountPath: v.mountPath
								}
							}
						}
					}
				}

				// securityContext.supplementalGroups is conditionally set from
				// component level — see the hoisted guards above the spec block.

				gracefulShutdown: terminationGracePeriodSeconds: _grace

				// Scalar, so it may stay in-spec.
				if _hwNvidia
				// podScheduling / podMetadata are written from the hoisted
				// guards above the spec block.
				{
					runtimeClass: _n.hardwareAcceleration.runtimeClass
				}
			}
		}
	}
}
