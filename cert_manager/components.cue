// Components for the cert-manager module.
//
// Nineteen components:
//   namespace                   — cert-manager Namespace (exact name, baseline PSS)
//   crds                        — all 6 cert-manager CustomResourceDefinitions
//   controller                  — certificate issuance controller (Deployment)
//   webhook                     — admission webhook server (Deployment + Service via #Expose)
//   cainjector                  — CA bundle injector (Deployment)
//   webhook-validating          — ValidatingWebhookConfiguration (exact name)
//   webhook-mutating            — MutatingWebhookConfiguration (exact name)
//   10 × *-rbac                 — bound ClusterRoles + ClusterRoleBindings
//   3 × *-role                  — namespace Roles + RoleBindings (leader election ×2, dynamic-serving)
//
// All bodies are transcribed from the upstream v1.21.0 static manifest.
// Deliberate deviations from upstream:
//   - controller/cainjector metrics Services are not emitted (nothing scrapes
//     them on the target clusters); the webhook Service IS emitted (the
//     webhook configurations' clientConfig depends on it).
//   - the aggregation-only ClusterRoles (view/edit/cluster-view) are skipped —
//     they carry no bindings and #Role always creates one.
//   - leader election Roles land in the module instance's namespace, not
//     kube-system (see #config.leaderElection).
//   - pod-level seccompProfile and nodeSelector are not expressible in the
//     catalog schema and are dropped (both are no-ops on the target clusters).
package cert_manager

import (
	bp "opmodel.dev/catalogs/opm/blueprints/workload"
	res "opmodel.dev/catalogs/opm/resources"
	tr "opmodel.dev/catalogs/opm/traits"
	exp "opmodel.dev/catalogs/opm-experimental/resources"
)

// Upstream webhook configuration metadata, shared by the VWC and MWC.
_webhookConfigLabels: {
	app:                           "webhook"
	"app.kubernetes.io/name":      "webhook"
	"app.kubernetes.io/instance":  "cert-manager"
	"app.kubernetes.io/component": "webhook"
	"app.kubernetes.io/version":   #config.image.tag
}

// cainjector populates the webhook configs' caBundle from the webhook's
// self-managed serving-cert CA. The legacy module's inject-apiserver-ca
// annotation was wrong (pre-v0.12 aggregated-apiserver era) — the modern
// chart uses inject-ca-from-secret, verified against v1.21.0.
_webhookConfigAnnotations: {
	"cert-manager.io/inject-ca-from-secret": "cert-manager/cert-manager-webhook-ca"
}

#components: {

	/////////////////////////////////////////////////////////////////
	//// Namespace — cert-manager (exact name)
	////
	//// No PSS labels: all three deployments run non-root, no privileged
	//// capabilities — fine under baseline Pod Security. On clusters where
	//// the namespace is pre-created at bootstrap this emission SSA-adopts
	//// the existing object.
	/////////////////////////////////////////////////////////////////

	namespace: {
		exp.#Namespaces

		spec: namespaces: "cert-manager": {}
	}

	/////////////////////////////////////////////////////////////////
	//// CRDs — cert-manager CustomResourceDefinitions
	////
	//// Deploys all 6 cert-manager CRDs (certificates, certificaterequests,
	//// issuers, clusterissuers + acme orders, challenges). The
	//// openAPIV3Schema is sourced from the upstream v1.21.0 manifest via
	//// crds_data.cue.
	/////////////////////////////////////////////////////////////////

	crds: {
		res.#CRDs

		// Map each K8s CRD name to its raw imported struct from crds_data.cue.
		// The comprehension converts each entry into #CRDSchema format,
		// preserving the full upstream openAPIV3Schema for cluster-side validation.
		let _rawCrds = {
			"certificaterequests.cert-manager.io": #cert_manager_io_certificaterequests
			"certificates.cert-manager.io":        #cert_manager_io_certificates
			"clusterissuers.cert-manager.io":      #cert_manager_io_clusterissuers
			"issuers.cert-manager.io":             #cert_manager_io_issuers
			"orders.acme.cert-manager.io":         #acme_cert_manager_io_orders
			"challenges.acme.cert-manager.io":     #acme_cert_manager_io_challenges
		}

		spec: crds: {
			for crdName, raw in _rawCrds {
				(crdName): {
					group: raw.spec.group
					names: {
						kind:   raw.spec.names.kind
						plural: raw.spec.names.plural
						if raw.spec.names.singular != _|_ {
							singular: raw.spec.names.singular
						}
						if raw.spec.names.shortNames != _|_ {
							shortNames: raw.spec.names.shortNames
						}
						if raw.spec.names.categories != _|_ {
							categories: raw.spec.names.categories
						}
					}
					scope: raw.spec.scope
					versions: [for v in raw.spec.versions {
						name:    v.name
						served:  v.served
						storage: v.storage
						if v.schema != _|_ {
							schema: v.schema
						}
						if v.subresources != _|_ {
							subresources: v.subresources
						}
						if v.additionalPrinterColumns != _|_ {
							additionalPrinterColumns: v.additionalPrinterColumns
						}
					}]
				}
			}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Controller — certificate issuance (Deployment)
	////
	//// Reconciles Certificates/Issuers/Orders/Challenges and emits the
	//// ACME solver pods. Leader election Leases go to
	//// #config.leaderElection.namespace (module default: cert-manager).
	/////////////////////////////////////////////////////////////////

	controller: {
		bp.#StatelessWorkload
		tr.#SecurityContext
		tr.#WorkloadIdentity

		spec: {
			statelessWorkload: {
				scaling: count: #config.controller.replicas
				restartPolicy: "Always"

				container: {
					name: "cert-manager-controller"
					image: {
						repository: "\(#config.image.repository)/cert-manager-controller"
						tag:        #config.image.tag
						digest:     #config.image.digest
						pullPolicy: #config.image.pullPolicy
					}

					args: [
						"--v=\(#config.controller.logLevel)",
						"--cluster-resource-namespace=$(POD_NAMESPACE)",
						"--leader-election-namespace=\(#config.leaderElection.namespace)",
						"--acme-http01-solver-image=\(#config.image.repository)/cert-manager-acmesolver:\(#config.image.tag)",
						"--max-concurrent-challenges=60",
					]

					env: {
						POD_NAMESPACE: {
							name: "POD_NAMESPACE"
							fieldRef: fieldPath: "metadata.namespace"
						}
					}

					ports: {
						"http-metrics": {
							name:       "http-metrics"
							targetPort: 9402
							protocol:   "TCP"
						}
						"http-healthz": {
							name:       "http-healthz"
							targetPort: 9403
							protocol:   "TCP"
						}
					}

					livenessProbe: {
						httpGet: {
							path: "/livez"
							port: 9403
						}
						initialDelaySeconds: 10
						periodSeconds:       10
						timeoutSeconds:      15
						failureThreshold:    8
					}

					if #config.controller.resources != _|_ {
						resources: #config.controller.resources
					}

					securityContext: {
						allowPrivilegeEscalation: false
						readOnlyRootFilesystem:   true
						capabilities: drop: ["ALL"]
					}
				}
			}

			workloadIdentity: {
				name:           "cert-manager"
				automountToken: true
			}

			// Pod-level security context (upstream also sets seccompProfile
			// RuntimeDefault, which the catalog schema cannot express).
			securityContext: runAsNonRoot: true
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Webhook — admission webhook server (Deployment + Service)
	////
	//// Serves the validating/mutating admission endpoints over a
	//// self-managed serving cert (dynamic serving) stored in the
	//// cert-manager-webhook-ca Secret. #Expose emits the Service the
	//// webhook configurations' clientConfig points at — the rendered
	//// name {instance}-{component} must equal cert-manager-webhook
	//// (instance `cert-manager`, component `webhook`).
	/////////////////////////////////////////////////////////////////

	webhook: {
		bp.#StatelessWorkload
		tr.#Expose
		tr.#SecurityContext
		tr.#WorkloadIdentity

		spec: {
			statelessWorkload: {
				scaling: count: #config.webhook.replicas
				restartPolicy: "Always"

				container: {
					name: "cert-manager-webhook"
					image: {
						repository: "\(#config.image.repository)/cert-manager-webhook"
						tag:        #config.image.tag
						digest:     #config.image.digest
						pullPolicy: #config.image.pullPolicy
					}

					args: [
						"--v=\(#config.webhook.logLevel)",
						"--secure-port=\(#config.webhook.securePort)",
						"--dynamic-serving-ca-secret-namespace=$(POD_NAMESPACE)",
						"--dynamic-serving-ca-secret-name=cert-manager-webhook-ca",
						"--dynamic-serving-dns-names=cert-manager-webhook",
						"--dynamic-serving-dns-names=cert-manager-webhook.$(POD_NAMESPACE)",
						"--dynamic-serving-dns-names=cert-manager-webhook.$(POD_NAMESPACE).svc",
					]

					env: {
						POD_NAMESPACE: {
							name: "POD_NAMESPACE"
							fieldRef: fieldPath: "metadata.namespace"
						}
					}

					ports: {
						https: {
							name:       "https"
							targetPort: #config.webhook.securePort
							protocol:   "TCP"
						}
						healthcheck: {
							name:       "healthcheck"
							targetPort: 6080
							protocol:   "TCP"
						}
						"http-metrics": {
							name:       "http-metrics"
							targetPort: 9402
							protocol:   "TCP"
						}
					}

					livenessProbe: {
						httpGet: {
							path: "/livez"
							port: 6080
						}
						initialDelaySeconds: 60
						periodSeconds:       10
					}
					readinessProbe: {
						httpGet: {
							path: "/healthz"
							port: 6080
						}
						initialDelaySeconds: 5
						periodSeconds:       5
					}

					if #config.webhook.resources != _|_ {
						resources: #config.webhook.resources
					}

					securityContext: {
						allowPrivilegeEscalation: false
						readOnlyRootFilesystem:   true
						capabilities: drop: ["ALL"]
					}
				}
			}

			// The Service the VWC/MWC clientConfig targets (renders as
			// cert-manager-webhook), plus the upstream metrics port.
			expose: {
				type: "ClusterIP"
				ports: {
					https: {
						targetPort:  #config.webhook.securePort
						exposedPort: 443
					}
					metrics: {
						targetPort:  9402
						exposedPort: 9402
					}
				}
			}

			workloadIdentity: {
				name:           "cert-manager-webhook"
				automountToken: true
			}

			securityContext: runAsNonRoot: true
		}
	}

	/////////////////////////////////////////////////////////////////
	//// CAInjector — CA bundle injection (Deployment)
	////
	//// Watches the cert-manager-webhook-ca Secret and injects its CA into
	//// the webhook configurations (via the inject-ca-from-secret
	//// annotation) and CRD conversion webhook specs.
	/////////////////////////////////////////////////////////////////

	cainjector: {
		bp.#StatelessWorkload
		tr.#SecurityContext
		tr.#WorkloadIdentity

		spec: {
			statelessWorkload: {
				scaling: count: #config.cainjector.replicas
				restartPolicy: "Always"

				container: {
					name: "cert-manager-cainjector"
					image: {
						repository: "\(#config.image.repository)/cert-manager-cainjector"
						tag:        #config.image.tag
						digest:     #config.image.digest
						pullPolicy: #config.image.pullPolicy
					}

					args: [
						"--v=\(#config.cainjector.logLevel)",
						"--leader-election-namespace=\(#config.leaderElection.namespace)",
					]

					env: {
						POD_NAMESPACE: {
							name: "POD_NAMESPACE"
							fieldRef: fieldPath: "metadata.namespace"
						}
					}

					ports: {
						"http-metrics": {
							name:       "http-metrics"
							targetPort: 9402
							protocol:   "TCP"
						}
					}

					if #config.cainjector.resources != _|_ {
						resources: #config.cainjector.resources
					}

					securityContext: {
						allowPrivilegeEscalation: false
						readOnlyRootFilesystem:   true
						capabilities: drop: ["ALL"]
					}
				}
			}

			workloadIdentity: {
				name:           "cert-manager-cainjector"
				automountToken: true
			}

			securityContext: runAsNonRoot: true
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Webhook configurations — exact names, no caBundle
	////
	//// Bodies re-vendored from the v1.21.0 manifest (the legacy module's
	//// transcription had drifted: wrong timeoutSeconds, an extra
	//// namespaceSelector term, over-broad MWC rules, and the obsolete
	//// inject-apiserver-ca annotation). cainjector patches caBundle into
	//// these objects by name at runtime.
	/////////////////////////////////////////////////////////////////

	"webhook-validating": {
		exp.#ValidatingWebhooks

		spec: validatingWebhooks: "cert-manager-webhook": {
			labels:      _webhookConfigLabels
			annotations: _webhookConfigAnnotations
			webhooks: [{
				name: "webhook.cert-manager.io"
				namespaceSelector: matchExpressions: [{
					key:      "cert-manager.io/disable-validation"
					operator: "NotIn"
					values: ["true"]
				}]
				rules: [{
					apiGroups: ["cert-manager.io", "acme.cert-manager.io"]
					apiVersions: ["v1"]
					operations: ["CREATE", "UPDATE"]
					resources: ["*/*"]
				}]
				admissionReviewVersions: ["v1"]
				matchPolicy:    "Equivalent"
				timeoutSeconds: 30
				failurePolicy:  "Fail"
				sideEffects:    "None"
				clientConfig: service: {
					name:      "cert-manager-webhook"
					namespace: "cert-manager"
					path:      "/validate"
				}
			}]
		}
	}

	"webhook-mutating": {
		exp.#MutatingWebhooks

		spec: mutatingWebhooks: "cert-manager-webhook": {
			labels:      _webhookConfigLabels
			annotations: _webhookConfigAnnotations
			webhooks: [{
				name: "webhook.cert-manager.io"
				rules: [{
					apiGroups: ["cert-manager.io"]
					apiVersions: ["v1"]
					operations: ["CREATE"]
					resources: ["certificaterequests"]
				}]
				admissionReviewVersions: ["v1"]
				matchPolicy:    "Equivalent"
				timeoutSeconds: 30
				failurePolicy:  "Fail"
				sideEffects:    "None"
				clientConfig: service: {
					name:      "cert-manager-webhook"
					namespace: "cert-manager"
					path:      "/mutate"
				}
			}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// RBAC — 10 bound ClusterRoles + 3 namespace Roles
	////
	//// Transcribed from the v1.21.0 manifest with exact upstream names,
	//// including the resourceNames-scoped rules (signer approval, CSR
	//// signing, leader-election Leases, the dynamic-serving CA Secret).
	//// The leader-election Roles are emitted into the module instance's
	//// namespace instead of upstream's kube-system (see #config).
	/////////////////////////////////////////////////////////////////

	"cainjector-rbac": {
		res.#Role

		spec: role: {
			name:  "cert-manager-cainjector"
			scope: "cluster"

			rules: [
				{
					apiGroups: ["cert-manager.io"]
					resources: ["certificates"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: [""]
					resources: ["secrets"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: [""]
					resources: ["events"]
					verbs: ["get", "create", "update", "patch"]
				},
				{
					apiGroups: ["admissionregistration.k8s.io"]
					resources: ["validatingwebhookconfigurations", "mutatingwebhookconfigurations"]
					verbs: ["get", "list", "watch", "update", "patch"]
				},
				{
					apiGroups: ["apiregistration.k8s.io"]
					resources: ["apiservices"]
					verbs: ["get", "list", "watch", "update", "patch"]
				},
				{
					apiGroups: ["apiextensions.k8s.io"]
					resources: ["customresourcedefinitions"]
					verbs: ["get", "list", "watch", "update", "patch"]
				},
			]

			subjects: [{name: "cert-manager-cainjector"}]
		}
	}

	"controller-issuers-rbac": {
		res.#Role

		spec: role: {
			name:  "cert-manager-controller-issuers"
			scope: "cluster"

			rules: [
				{
					apiGroups: ["cert-manager.io"]
					resources: ["issuers", "issuers/status"]
					verbs: ["update", "patch"]
				},
				{
					apiGroups: ["cert-manager.io"]
					resources: ["issuers"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: [""]
					resources: ["secrets"]
					verbs: ["get", "list", "watch", "create", "update", "delete"]
				},
				{
					apiGroups: [""]
					resources: ["events"]
					verbs: ["create", "patch"]
				},
			]

			subjects: [{name: "cert-manager"}]
		}
	}

	"controller-clusterissuers-rbac": {
		res.#Role

		spec: role: {
			name:  "cert-manager-controller-clusterissuers"
			scope: "cluster"

			rules: [
				{
					apiGroups: ["cert-manager.io"]
					resources: ["clusterissuers", "clusterissuers/status"]
					verbs: ["update", "patch"]
				},
				{
					apiGroups: ["cert-manager.io"]
					resources: ["clusterissuers"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: [""]
					resources: ["secrets"]
					verbs: ["get", "list", "watch", "create", "update", "delete"]
				},
				{
					apiGroups: [""]
					resources: ["events"]
					verbs: ["create", "patch"]
				},
			]

			subjects: [{name: "cert-manager"}]
		}
	}

	"controller-certificates-rbac": {
		res.#Role

		spec: role: {
			name:  "cert-manager-controller-certificates"
			scope: "cluster"

			rules: [
				{
					apiGroups: ["cert-manager.io"]
					resources: ["certificates", "certificates/status", "certificaterequests", "certificaterequests/status"]
					verbs: ["update", "patch"]
				},
				{
					apiGroups: ["cert-manager.io"]
					resources: ["certificates", "certificaterequests", "clusterissuers", "issuers"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: ["cert-manager.io"]
					resources: ["certificates/finalizers", "certificaterequests/finalizers"]
					verbs: ["update"]
				},
				{
					apiGroups: ["acme.cert-manager.io"]
					resources: ["orders"]
					verbs: ["create", "delete", "get", "list", "watch"]
				},
				{
					apiGroups: [""]
					resources: ["secrets"]
					verbs: ["get", "list", "watch", "create", "update", "delete", "patch"]
				},
				{
					apiGroups: [""]
					resources: ["events"]
					verbs: ["create", "patch"]
				},
			]

			subjects: [{name: "cert-manager"}]
		}
	}

	"controller-orders-rbac": {
		res.#Role

		spec: role: {
			name:  "cert-manager-controller-orders"
			scope: "cluster"

			rules: [
				{
					apiGroups: ["acme.cert-manager.io"]
					resources: ["orders", "orders/status"]
					verbs: ["update", "patch"]
				},
				{
					apiGroups: ["acme.cert-manager.io"]
					resources: ["orders", "challenges"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: ["cert-manager.io"]
					resources: ["clusterissuers", "issuers"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: ["acme.cert-manager.io"]
					resources: ["challenges"]
					verbs: ["create", "delete"]
				},
				{
					apiGroups: ["acme.cert-manager.io"]
					resources: ["orders/finalizers"]
					verbs: ["update"]
				},
				{
					apiGroups: ["cert-manager.io"]
					resources: ["clusterissuers/finalizers", "issuers/finalizers"]
					verbs: ["update"]
				},
				{
					apiGroups: [""]
					resources: ["secrets"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: [""]
					resources: ["events"]
					verbs: ["create", "patch"]
				},
			]

			subjects: [{name: "cert-manager"}]
		}
	}

	"controller-challenges-rbac": {
		res.#Role

		spec: role: {
			name:  "cert-manager-controller-challenges"
			scope: "cluster"

			rules: [
				{
					apiGroups: ["acme.cert-manager.io"]
					resources: ["challenges", "challenges/status"]
					verbs: ["update", "patch"]
				},
				{
					apiGroups: ["acme.cert-manager.io"]
					resources: ["challenges"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: ["cert-manager.io"]
					resources: ["issuers", "clusterissuers"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: [""]
					resources: ["secrets"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: [""]
					resources: ["events"]
					verbs: ["create", "patch"]
				},
				{
					apiGroups: [""]
					resources: ["pods", "services"]
					verbs: ["get", "list", "watch", "create", "delete"]
				},
				{
					apiGroups: ["networking.k8s.io"]
					resources: ["ingresses"]
					verbs: ["get", "list", "watch", "create", "delete", "update"]
				},
				{
					apiGroups: ["gateway.networking.k8s.io"]
					resources: ["httproutes"]
					verbs: ["get", "list", "watch", "create", "delete", "update"]
				},
				{
					apiGroups: ["route.openshift.io"]
					resources: ["routes/custom-host"]
					verbs: ["create"]
				},
				{
					apiGroups: ["acme.cert-manager.io"]
					resources: ["challenges/finalizers"]
					verbs: ["update"]
				},
				{
					apiGroups: [""]
					resources: ["secrets"]
					verbs: ["get", "list", "watch"]
				},
			]

			subjects: [{name: "cert-manager"}]
		}
	}

	"controller-ingress-shim-rbac": {
		res.#Role

		spec: role: {
			name:  "cert-manager-controller-ingress-shim"
			scope: "cluster"

			rules: [
				{
					apiGroups: ["cert-manager.io"]
					resources: ["certificates", "certificaterequests"]
					verbs: ["create", "update", "delete"]
				},
				{
					apiGroups: ["cert-manager.io"]
					resources: ["certificates", "certificaterequests", "issuers", "clusterissuers"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: ["networking.k8s.io"]
					resources: ["ingresses"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: ["networking.k8s.io"]
					resources: ["ingresses/finalizers"]
					verbs: ["update"]
				},
				{
					apiGroups: ["gateway.networking.k8s.io"]
					resources: ["gateways", "httproutes", "listenersets"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: ["gateway.networking.k8s.io"]
					resources: ["gateways/finalizers", "httproutes/finalizers", "listenersets/finalizers"]
					verbs: ["update"]
				},
				{
					apiGroups: [""]
					resources: ["events"]
					verbs: ["create", "patch"]
				},
			]

			subjects: [{name: "cert-manager"}]
		}
	}

	"controller-approve-rbac": {
		res.#Role

		spec: role: {
			name:  "cert-manager-controller-approve:cert-manager-io"
			scope: "cluster"

			rules: [
				{
					apiGroups: ["cert-manager.io"]
					resources: ["signers"]
					verbs: ["approve"]
					resourceNames: ["issuers.cert-manager.io/*", "clusterissuers.cert-manager.io/*"]
				},
			]

			subjects: [{name: "cert-manager"}]
		}
	}

	"controller-csr-rbac": {
		res.#Role

		spec: role: {
			name:  "cert-manager-controller-certificatesigningrequests"
			scope: "cluster"

			rules: [
				{
					apiGroups: ["certificates.k8s.io"]
					resources: ["certificatesigningrequests"]
					verbs: ["get", "list", "watch", "update"]
				},
				{
					apiGroups: ["certificates.k8s.io"]
					resources: ["certificatesigningrequests/status"]
					verbs: ["update", "patch"]
				},
				{
					apiGroups: ["certificates.k8s.io"]
					resources: ["signers"]
					verbs: ["sign"]
					resourceNames: ["issuers.cert-manager.io/*", "clusterissuers.cert-manager.io/*"]
				},
				{
					apiGroups: ["authorization.k8s.io"]
					resources: ["subjectaccessreviews"]
					verbs: ["create"]
				},
			]

			subjects: [{name: "cert-manager"}]
		}
	}

	"webhook-sar-rbac": {
		res.#Role

		spec: role: {
			name:  "cert-manager-webhook:subjectaccessreviews"
			scope: "cluster"

			rules: [
				{
					apiGroups: ["authorization.k8s.io"]
					resources: ["subjectaccessreviews"]
					verbs: ["create"]
				},
			]

			subjects: [{name: "cert-manager-webhook"}]
		}
	}

	"cainjector-leaderelection-role": {
		res.#Role

		spec: role: {
			name:  "cert-manager-cainjector:leaderelection"
			scope: "namespace"

			rules: [
				{
					apiGroups: ["coordination.k8s.io"]
					resources: ["leases"]
					verbs: ["get", "update", "patch"]
					resourceNames: ["cert-manager-cainjector-leader-election", "cert-manager-cainjector-leader-election-core"]
				},
				{
					apiGroups: ["coordination.k8s.io"]
					resources: ["leases"]
					verbs: ["create"]
				},
			]

			subjects: [{name: "cert-manager-cainjector"}]
		}
	}

	"controller-leaderelection-role": {
		res.#Role

		spec: role: {
			name:  "cert-manager:leaderelection"
			scope: "namespace"

			rules: [
				{
					apiGroups: ["coordination.k8s.io"]
					resources: ["leases"]
					verbs: ["get", "update", "patch"]
					resourceNames: ["cert-manager-controller"]
				},
				{
					apiGroups: ["coordination.k8s.io"]
					resources: ["leases"]
					verbs: ["create"]
				},
			]

			subjects: [{name: "cert-manager"}]
		}
	}

	"webhook-dynamic-serving-role": {
		res.#Role

		spec: role: {
			name:  "cert-manager-webhook:dynamic-serving"
			scope: "namespace"

			rules: [
				{
					apiGroups: [""]
					resources: ["secrets"]
					verbs: ["get", "list", "watch", "update"]
					resourceNames: ["cert-manager-webhook-ca"]
				},
				{
					apiGroups: [""]
					resources: ["secrets"]
					verbs: ["create"]
				},
			]

			subjects: [{name: "cert-manager-webhook"}]
		}
	}

}
