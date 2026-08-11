package istio_ambient

import (
	bp "opmodel.dev/catalogs/opm/blueprints/v1beta1"
	res "opmodel.dev/catalogs/opm/resources/v1beta1"
	tr "opmodel.dev/catalogs/opm/traits/v1beta1"
)

/////////////////////////////////////////////////////////////////
//// istiod — the control plane
////
//// Renders the Deployment, the Service, the ServiceAccount, and (per
//// #config) an HPA, a PodDisruptionBudget and a NetworkPolicy.
////
//// The Service name `istiod` is load-bearing and must never be prefixed:
//// the mesh config's discoveryAddress, ztunnel's XDS/CA addresses, istiod's
//// own serving-cert SANs and all three webhook clientConfigs resolve
//// istiod.<ns>.svc. The Deployment takes the same exact name so that
//// `kubectl rollout restart deploy/istiod` and every upstream runbook work
//// unchanged.
/////////////////////////////////////////////////////////////////

#components: {
	istiod: {
		bp.#StatelessWorkload
		res.#Volumes
		res.#ServiceAccount
		tr.#Expose
		tr.#WorkloadIdentity
		tr.#ResourceName
		tr.#PodMetadata
		tr.#PodScheduling

		// PDB and NetworkPolicy attach conditionally. Attaching them
		// unconditionally is not an option: #DisruptionBudgetSchema requires
		// exactly one of minAvailable/maxUnavailable, so an attached-but-unset
		// trait leaves spec.disruptionBudget non-concrete and the whole
		// instance fails to compile.
		if #config.pilot.pdb.enabled {
			tr.#DisruptionBudget
		}

		// Note this is tr.#NetworkPolicy, from the STABLE catalog. The
		// experimental catalog's version could not be attached here at all: a
		// blueprint's spec closedness (core component.cue:80,
		// spec: close({_allFields})) does not admit a field contributed by a
		// trait from a foreign CUE module, so it failed with "field not
		// allowed". tr.#DisruptionBudget above always worked for the same
		// reason in reverse — it ships alongside the blueprint. Ported in
		// catalog_opm v1.0.0-alpha.6; do not reach for the experimental one.
		if #config.networkPolicy.enabled {
			tr.#NetworkPolicy
		}

		// Conditional struct-valued spec fields, HOISTED to component level
		// rather than guarded inside the spec block — the in-spec form trips
		// the CUE v0.17 closedness regression on the v2 catalog's closed
		// blueprint spec (catalog CLAUDE.md authoring pitfall; see
		// docs/cue-guard-closedness-workaround.md there). Do not inline these.
		//
		// When autoscaling is on the HPA owns the replica count and the
		// Deployment omits `replicas` entirely — emitting both puts them in a
		// permanent server-side-apply fight.
		if #config.pilot.autoscale.enabled {
			spec: statelessWorkload: scaling: auto: {
				min: #config.pilot.autoscale.min
				max: #config.pilot.autoscale.max
				metrics: [{
					type: "cpu"
					target: averageUtilization: #config.pilot.autoscale.targetCPUUtilization
				}]
			}
		}
		if #config.pilot.resources != _|_ {
			spec: statelessWorkload: container: resources: #config.pilot.resources
		}
		if #config.networkPolicy.enabled {
			spec: networkPolicy: {
				policyTypes: ["Ingress", "Egress"]
				ingress: [
					// Webhook traffic from the API server.
					{ports: [{protocol: "TCP", port: 15017}]},
					// xDS, debug and monitoring, reachable from anywhere.
					{ports: [
						{protocol: "TCP", port: 15010},
						{protocol: "TCP", port: 15011},
						{protocol: "TCP", port: 15012},
						{protocol: "TCP", port: 8080},
						{protocol: "TCP", port: 15014},
					]},
				]
				// Allow-all, expressed as one empty rule. istiod reaches
				// user-defined endpoints (JWKS resolution among others), so
				// egress cannot be enumerated — and naming "Egress" in
				// policyTypes with no rules would be a deny-all, not a no-op.
				egress: [{}]
			}
		}
		if #config.pilot.pdb.enabled {
			spec: disruptionBudget: minAvailable: #config.pilot.pdb.minAvailable
		}

		spec: {
			resourceName: "istiod"

			statelessWorkload: {
				restartPolicy: "Always"
				updateStrategy: {
					type: "RollingUpdate"
					rollingUpdate: {
						maxSurge:       "100%"
						maxUnavailable: "25%"
					}
				}

				scaling: {
					count: #config.pilot.replicas
					// scaling.auto is conditionally set from component level —
					// see the hoisted guards above the spec block.
				}

				container: {
					name: "discovery"
					image: {
						repository: "\(#config.image.hub)/pilot"
						tag:        "\(#config.image.tag)-\(#config.image.variant)"
						digest:     ""
						pullPolicy: #config.image.pullPolicy
					}

					args: [
						"discovery",
						"--monitoringAddr=:15014",
						"--log_output_level=default:info",
						"--domain",
						#config.mesh.trustDomain,
						"--keepaliveMaxServerConnectionAge",
						"30m",
					]

					ports: {
						"http-debug": {name: "http-debug", targetPort: 8080}
						"grpc-xds": {name: "grpc-xds", targetPort: 15010}
						"tls-xds": {name: "tls-xds", targetPort: 15012}
						// 14 runes; #IANA_SVC_NAME caps at 15.
						"https-webhooks": {name: "https-webhooks", targetPort: 15017}
						// Exactly 15 runes — at the cap.
						"http-monitoring": {name: "http-monitoring", targetPort: 15014}
					}

					env: {
						REVISION: {name: "REVISION", value: "default"}
						PILOT_CERT_PROVIDER: {name: "PILOT_CERT_PROVIDER", value: "istiod"}
						POD_NAME: {name: "POD_NAME", fieldRef: {apiVersion: "v1", fieldPath: "metadata.name"}}
						POD_NAMESPACE: {name: "POD_NAMESPACE", fieldRef: {apiVersion: "v1", fieldPath: "metadata.namespace"}}
						SERVICE_ACCOUNT: {name: "SERVICE_ACCOUNT", fieldRef: {apiVersion: "v1", fieldPath: "spec.serviceAccountName"}}
						KUBECONFIG: {name: "KUBECONFIG", value: "/var/run/secrets/remote/config"}

						// Ambient hard-locks. CA_TRUSTED_NODE_ACCOUNTS is what
						// permits ztunnel to request certificates on behalf of
						// the pods on its node — the whole ambient identity
						// model rests on it.
						CA_TRUSTED_NODE_ACCOUNTS: {
							name:  "CA_TRUSTED_NODE_ACCOUNTS"
							value: "\(#config.namespace.name)/ztunnel"
						}
						PILOT_ENABLE_AMBIENT: {name: "PILOT_ENABLE_AMBIENT", value: "true"}

						PILOT_TRACE_SAMPLING: {
							name:  "PILOT_TRACE_SAMPLING"
							value: "\(#config.pilot.traceSampling)"
						}
						PILOT_ENABLE_ANALYSIS: {name: "PILOT_ENABLE_ANALYSIS", value: "false"}
						CLUSTER_ID: {name: "CLUSTER_ID", value: #config.mesh.clusterName}
						GOMAXPROCS: {
							name: "GOMAXPROCS"
							resourceFieldRef: {resource: "limits.cpu", divisor: "1"}
						}
						PLATFORM: {name: "PLATFORM", value: ""}

						for k, v in #config.pilot.env {
							(k): {name: k, value: v}
						}
					}

					readinessProbe: {
						httpGet: {path: "/ready", port: 8080}
						initialDelaySeconds: 1
						periodSeconds:       3
						timeoutSeconds:      5
					}

					// resources is conditionally set from component level — see
					// the hoisted guards above the spec block.

					securityContext: {
						allowPrivilegeEscalation: false
						readOnlyRootFilesystem:   true
						runAsNonRoot:             true
						capabilities: drop: ["ALL"]
					}

					volumeMounts: {
						"istio-token": spec.volumes."istio-token" & {
							mountPath: "/var/run/secrets/tokens"
							readOnly:  true
						}
						"local-certs": spec.volumes."local-certs" & {
							mountPath: "/var/run/secrets/istio-dns"
						}
						cacerts: spec.volumes.cacerts & {
							mountPath: "/etc/cacerts"
							readOnly:  true
						}
						"istio-kubeconfig": spec.volumes."istio-kubeconfig" & {
							mountPath: "/var/run/secrets/remote"
							readOnly:  true
						}
						"istio-csr-dns-cert": spec.volumes."istio-csr-dns-cert" & {
							mountPath: "/var/run/secrets/istiod/tls"
							readOnly:  true
						}
						"istio-csr-ca-configmap": spec.volumes."istio-csr-ca-configmap" & {
							mountPath: "/var/run/secrets/istiod/ca"
							readOnly:  true
						}
					}
				}
			}

			volumes: {
				// istiod writes its own serving certs here, and the root
				// filesystem is read-only.
				"local-certs": {
					name:     "local-certs"
					readOnly: false
					emptyDir: medium: "memory"
				}

				// Audience-bound token istiod presents to the CA.
				"istio-token": {
					name:     "istio-token"
					readOnly: true
					projected: sources: [{
						serviceAccountToken: {
							audience:          "istio-ca"
							expirationSeconds: 43200
							path:              "istio-token"
						}
					}]
				}

				// All four below are OPTIONAL and external: they are
				// provisioned out-of-band (a user-supplied root CA, a remote
				// cluster kubeconfig) or written by another controller
				// (cert-manager's istio-csr). istiod must start without them.
				cacerts: {
					name:     "cacerts"
					readOnly: true
					secretRef: {
						name:     "cacerts"
						optional: true
					}
				}
				"istio-kubeconfig": {
					name:     "istio-kubeconfig"
					readOnly: true
					secretRef: {
						name:     "istio-kubeconfig"
						optional: true
					}
				}
				"istio-csr-dns-cert": {
					name:     "istio-csr-dns-cert"
					readOnly: true
					secretRef: {
						name:     "istiod-tls"
						optional: true
					}
				}
				"istio-csr-ca-configmap": {
					name:     "istio-csr-ca-configmap"
					readOnly: true
					configMapRef: {
						name:        "istio-ca-root-cert"
						defaultMode: 420
						optional:    true
					}
				}
			}

			// 443 -> 15017 is the webhook port pair the API server dials; the
			// webhook configurations omit `port`, and Kubernetes defaults it to
			// 443, so this mapping is not optional.
			expose: {
				name: "istiod"
				type: "ClusterIP"
				ports: {
					"grpc-xds": {targetPort: 15010, exposedPort: 15010}
					"https-dns": {targetPort: 15012, exposedPort: 15012}
					"https-webhook": {targetPort: 15017, exposedPort: 443}
					"http-monitoring": {targetPort: 15014, exposedPort: 15014}
				}
			}

			// The trait wires the pod's serviceAccountName; the resource emits
			// the object. Both are needed — the trait alone names an account
			// nothing creates, and every RBAC binding lists it as a subject.
			workloadIdentity: {
				name:           "istiod"
				automountToken: true
			}
			serviceAccount: {
				name:           "istiod"
				automountToken: true
			}

			podMetadata: {
				labels: {
					// Keeps the control plane out of the dataplane it runs. If
					// istio-system were ever labelled for ambient capture,
					// without this ztunnel would try to capture istiod itself.
					"istio.io/dataplane-mode": "none"
					"sidecar.istio.io/inject": "false"
					// Upstream's own Service selector value; carried so
					// istioctl and existing tooling still find these pods.
					istio: "pilot"
				}
				annotations: {
					"prometheus.io/scrape": "true"
					"prometheus.io/port":   "15014"
				}
			}

			// istio-cni taints nodes until its agent is ready. istiod has to
			// tolerate that or the control plane cannot start on a fresh node.
			podScheduling: tolerations: [{
				key:      "cni.istio.io/not-ready"
				operator: "Exists"
			}]

			// networkPolicy and disruptionBudget are conditionally set from
			// component level — see the hoisted guards above the spec block.
		}
	}
}

/////////////////////////////////////////////////////////////////
//// Guards
/////////////////////////////////////////////////////////////////

// The Service name is the mesh's discovery identity — assert it against the
// same value the mesh ConfigMap embeds, so the two can never drift.
_istiodExposeName:   "\(#components.istiod.spec.expose.name)" & "istiod"
_istiodResourceName: "\(#components.istiod.spec.resourceName)" & "istiod"

// 443 -> 15017 specifically: the webhook configurations rely on the default
// port, and getting this wrong presents as a TLS/connection error at admission
// time rather than as anything visible here.
_istiodWebhookPort:   (#components.istiod.spec.expose.ports."https-webhook".exposedPort + 0) & 443
_istiodWebhookTarget: (#components.istiod.spec.expose.ports."https-webhook".targetPort + 0) & 15017

// Ambient hard-locks must be present. Absent-field territory, so the
// empty-comprehension form rather than interpolation.
_istiodAmbientEnabled: [
	if #components.istiod.spec.statelessWorkload.container.env.PILOT_ENABLE_AMBIENT != _|_ {
		#components.istiod.spec.statelessWorkload.container.env.PILOT_ENABLE_AMBIENT.value
	},
] & ["true"]

_istiodTrustedZtunnel: [
	if #components.istiod.spec.statelessWorkload.container.env.CA_TRUSTED_NODE_ACCOUNTS != _|_ {
		#components.istiod.spec.statelessWorkload.container.env.CA_TRUSTED_NODE_ACCOUNTS.value
	},
] & ["\(#config.namespace.name)/ztunnel"]

// The control plane must never be captured by its own dataplane.
_istiodDataplaneNone: [
	if #components.istiod.spec.podMetadata.labels["istio.io/dataplane-mode"] != _|_ {
		#components.istiod.spec.podMetadata.labels["istio.io/dataplane-mode"]
	},
] & ["none"]
