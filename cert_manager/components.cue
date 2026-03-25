// Components for the cert-manager module.
//
// Nineteen components:
//   crds                           — 6 CRDs (Certificate, CertificateRequest, ClusterIssuer, Issuer, Order, Challenge)
//   controller                     — certificate controller (Deployment)
//   webhook                        — admission webhook (Deployment)
//   cainjector                     — CA bundle injector (Deployment)
//   controller-issuers-rbac        — ClusterRole for Issuer management
//   controller-clusterissuers-rbac — ClusterRole for ClusterIssuer management
//   controller-certificates-rbac   — ClusterRole for Certificate/CertificateRequest lifecycle
//   controller-orders-rbac         — ClusterRole for ACME Order management
//   controller-challenges-rbac     — ClusterRole for ACME Challenge management
//   controller-ingress-shim-rbac   — ClusterRole for Ingress-to-Certificate shim
//   controller-approve-rbac        — ClusterRole for CertificateRequest approval
//   controller-csr-rbac            — ClusterRole for CertificateSigningRequest signing
//   controller-leaderelection-role — namespace Role for controller leader election
//   cainjector-rbac                — ClusterRole for CA bundle injection
//   cainjector-leaderelection-role — namespace Role for cainjector leader election
//   webhook-sar-rbac               — ClusterRole for SubjectAccessReview (webhook authz)
//   webhook-dynamic-serving-role   — namespace Role for dynamic TLS cert management
//   webhook-validating             — ValidatingWebhookConfiguration (cert-manager-webhook)
//   webhook-mutating               — MutatingWebhookConfiguration (cert-manager-webhook)
//
// RBAC follows the cert-manager Helm chart v1.13.0 structure exactly.
package cert_manager

import (
	resources_admission "opmodel.dev/kubernetes/v1alpha1/resources/admission@v1"
	resources_extension "opmodel.dev/opm/v1alpha1/resources/extension@v1"
	resources_security "opmodel.dev/opm/v1alpha1/resources/security@v1"
	resources_workload "opmodel.dev/opm/v1alpha1/resources/workload@v1"
	traits_security "opmodel.dev/opm/v1alpha1/traits/security@v1"
	traits_workload "opmodel.dev/opm/v1alpha1/traits/workload@v1"
)

#components: {

	/////////////////////////////////////////////////////////////////
	//// CRDs — cert-manager CustomResourceDefinitions
	////
	//// Deploys all 6 cert-manager CRDs so the cluster accepts
	//// Certificate, CertificateRequest, ClusterIssuer, Issuer,
	//// Order, and Challenge as first-class resources.
	//// The openAPIV3Schema is sourced from crds_data.cue.
	/////////////////////////////////////////////////////////////////

	crds: {
		resources_extension.#CRDs

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
	//// Controller — certificate issuance and renewal (Deployment)
	////
	//// Watches Certificate and CertificateRequest CRs, drives the
	//// issuance lifecycle against configured Issuer/ClusterIssuer
	//// backends, and manages ACME orders and challenges.
	/////////////////////////////////////////////////////////////////

	controller: {
		resources_workload.#Container
		traits_workload.#Scaling
		traits_workload.#RestartPolicy
		traits_workload.#UpdateStrategy
		traits_workload.#GracefulShutdown
		traits_security.#SecurityContext
		traits_security.#WorkloadIdentity

		metadata: {
			name: "controller"
			labels: {
				"core.opmodel.dev/workload-type": "stateless"
			}
		}

		spec: {
			scaling: count: #config.controller.replicas

			restartPolicy: "Always"

			updateStrategy: type: "RollingUpdate"

			gracefulShutdown: terminationGracePeriodSeconds: 0

			// ServiceAccount bound to all controller ClusterRoles and the leaderelection Role.
			workloadIdentity: {
				name:           "cert-manager"
				automountToken: true
			}

			container: {
				name: "cert-manager-controller"
				image: {
					repository: "quay.io/jetstack/cert-manager-controller"
					tag:        #config.image.tag
					digest:     ""
					pullPolicy: #config.image.pullPolicy
				}

				args: [
					"--v=\(#config.controller.logLevel)",
					"--cluster-resource-namespace=$(POD_NAMESPACE)",
					"--leader-election-namespace=\(#config.leaderElection.namespace)",
					"--acme-http01-solver-image=quay.io/jetstack/cert-manager-acmesolver:\(#config.image.tag)",
				]

				env: {
					POD_NAMESPACE: {
						name: "POD_NAMESPACE"
						fieldRef: fieldPath: "metadata.namespace"
					}
				}

				ports: {
					metrics: {
						name:       "metrics"
						targetPort: 9402
						protocol:   "TCP"
					}
					healthz: {
						name:       "healthz"
						targetPort: 9403
						protocol:   "TCP"
					}
				}

				if #config.controller.resources != _|_ {
					resources: #config.controller.resources
				}
			}

			// Matches Helm chart: non-root uid 1000, drop all capabilities, read-only root fs.
			securityContext: {
				runAsNonRoot:             true
				runAsUser:                1000
				readOnlyRootFilesystem:   true
				allowPrivilegeEscalation: false
				capabilities: drop: ["ALL"]
			}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Webhook — cert-manager admission webhook (Deployment)
	////
	//// Validates and mutates cert-manager CRs via Kubernetes admission
	//// control. Generates and manages its own TLS serving certificate
	//// using the --dynamic-serving-* flags (stored in a K8s Secret).
	////
	/////////////////////////////////////////////////////////////////

	webhook: {
		resources_workload.#Container
		traits_workload.#Scaling
		traits_workload.#RestartPolicy
		traits_workload.#UpdateStrategy
		traits_workload.#GracefulShutdown
		traits_security.#SecurityContext
		traits_security.#WorkloadIdentity

		metadata: {
			name: "webhook"
			labels: {
				"core.opmodel.dev/workload-type": "stateless"
			}
		}

		spec: {
			scaling: count: #config.webhook.replicas

			restartPolicy: "Always"

			updateStrategy: type: "RollingUpdate"

			gracefulShutdown: terminationGracePeriodSeconds: 0

			// ServiceAccount bound to webhook-sar-rbac and webhook-dynamic-serving-role.
			workloadIdentity: {
				name:           "cert-manager-webhook"
				automountToken: true
			}

			container: {
				name: "cert-manager-webhook"
				image: {
					repository: "quay.io/jetstack/cert-manager-webhook"
					tag:        #config.image.tag
					digest:     ""
					pullPolicy: #config.image.pullPolicy
				}

				args: [
					"--v=\(#config.webhook.logLevel)",
					"--secure-port=\(#config.webhook.securePort)",
					"--dynamic-serving-ca-secret-namespace=$(POD_NAMESPACE)",
					"--dynamic-serving-ca-secret-name=cert-manager-webhook-ca",
					"--dynamic-serving-dns-names=cert-manager-webhook,cert-manager-webhook.cert-manager,cert-manager-webhook.cert-manager.svc",
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
					healthz: {
						name:       "healthz"
						targetPort: 6080
						protocol:   "TCP"
					}
				}

				if #config.webhook.resources != _|_ {
					resources: #config.webhook.resources
				}
			}

			securityContext: {
				runAsNonRoot:             true
				runAsUser:                1000
				readOnlyRootFilesystem:   true
				allowPrivilegeEscalation: false
				capabilities: drop: ["ALL"]
			}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// CAInjector — CA bundle injector (Deployment)
	////
	//// Reads CA data from cert-manager Certificate CRs or Secrets
	//// and patches it as caBundle into ValidatingWebhookConfigurations,
	//// MutatingWebhookConfigurations, APIServices, and CRDs.
	/////////////////////////////////////////////////////////////////

	cainjector: {
		resources_workload.#Container
		traits_workload.#Scaling
		traits_workload.#RestartPolicy
		traits_workload.#UpdateStrategy
		traits_workload.#GracefulShutdown
		traits_security.#SecurityContext
		traits_security.#WorkloadIdentity

		metadata: {
			name: "cainjector"
			labels: {
				"core.opmodel.dev/workload-type": "stateless"
			}
		}

		spec: {
			scaling: count: #config.cainjector.replicas

			restartPolicy: "Always"

			updateStrategy: type: "RollingUpdate"

			gracefulShutdown: terminationGracePeriodSeconds: 0

			// ServiceAccount bound to cainjector-rbac and cainjector-leaderelection-role.
			workloadIdentity: {
				name:           "cert-manager-cainjector"
				automountToken: true
			}

			container: {
				name: "cert-manager-cainjector"
				image: {
					repository: "quay.io/jetstack/cert-manager-cainjector"
					tag:        #config.image.tag
					digest:     ""
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
					metrics: {
						name:       "metrics"
						targetPort: 9402
						protocol:   "TCP"
					}
				}

				if #config.cainjector.resources != _|_ {
					resources: #config.cainjector.resources
				}
			}

			securityContext: {
				runAsNonRoot:             true
				runAsUser:                1000
				readOnlyRootFilesystem:   true
				allowPrivilegeEscalation: false
				capabilities: drop: ["ALL"]
			}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Controller RBAC — ClusterRole: cert-manager-controller-issuers
	////
	//// Manages namespace-scoped Issuer resources and reads referenced
	//// Secrets (CA certs, ACME account keys, etc.).
	/////////////////////////////////////////////////////////////////

	"controller-issuers-rbac": {
		resources_security.#Role

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

	/////////////////////////////////////////////////////////////////
	//// Controller RBAC — ClusterRole: cert-manager-controller-clusterissuers
	////
	//// Manages cluster-scoped ClusterIssuer resources and reads
	//// referenced Secrets across all namespaces.
	/////////////////////////////////////////////////////////////////

	"controller-clusterissuers-rbac": {
		resources_security.#Role

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

	/////////////////////////////////////////////////////////////////
	//// Controller RBAC — ClusterRole: cert-manager-controller-certificates
	////
	//// Full lifecycle management of Certificate and CertificateRequest
	//// objects, including creating ACME Orders and managing Secrets.
	/////////////////////////////////////////////////////////////////

	"controller-certificates-rbac": {
		resources_security.#Role

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
					verbs: ["get", "list", "watch", "create", "delete"]
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

	/////////////////////////////////////////////////////////////////
	//// Controller RBAC — ClusterRole: cert-manager-controller-orders
	////
	//// Manages ACME Order objects: creates HTTP01 and DNS01 challenges,
	//// tracks order status, and cleans up after completion.
	/////////////////////////////////////////////////////////////////

	"controller-orders-rbac": {
		resources_security.#Role

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
					resources: ["challenges", "orders/finalizers"]
					verbs: ["create", "delete", "update"]
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

	/////////////////////////////////////////////////////////////////
	//// Controller RBAC — ClusterRole: cert-manager-controller-challenges
	////
	//// Manages ACME Challenge objects for HTTP01 (creates solver Pods
	//// and Services) and DNS01 (updates DNS zone records).
	/////////////////////////////////////////////////////////////////

	"controller-challenges-rbac": {
		resources_security.#Role

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
					apiGroups: ["acme.cert-manager.io"]
					resources: ["challenges/finalizers"]
					verbs: ["update"]
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
			]

			subjects: [{name: "cert-manager"}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Controller RBAC — ClusterRole: cert-manager-controller-ingress-shim
	////
	//// Watches Ingress and Gateway resources with cert-manager annotations
	//// and automatically creates Certificate objects for TLS termination.
	/////////////////////////////////////////////////////////////////

	"controller-ingress-shim-rbac": {
		resources_security.#Role

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
					resources: ["gateways", "httproutes"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: ["gateway.networking.k8s.io"]
					resources: ["gateways/finalizers", "httproutes/finalizers"]
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

	/////////////////////////////////////////////////////////////////
	//// Controller RBAC — ClusterRole: cert-manager-controller-approve:cert-manager-io
	////
	//// Allows the controller to approve CertificateRequests issued
	//// by cert-manager Issuers and ClusterIssuers.
	/////////////////////////////////////////////////////////////////

	"controller-approve-rbac": {
		resources_security.#Role

		spec: role: {
			name:  "cert-manager-controller-approve:cert-manager-io"
			scope: "cluster"

			rules: [
				{
					apiGroups: ["cert-manager.io"]
					resources: ["signers"]
					verbs: ["approve"]
				},
			]

			subjects: [{name: "cert-manager"}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Controller RBAC — ClusterRole: cert-manager-controller-certificatesigningrequests
	////
	//// Manages Kubernetes-native CertificateSigningRequest objects and
	//// signs them using cert-manager Issuers/ClusterIssuers.
	/////////////////////////////////////////////////////////////////

	"controller-csr-rbac": {
		resources_security.#Role

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

	/////////////////////////////////////////////////////////////////
	//// Controller Role — namespace Role: cert-manager-controller:leaderelection
	////
	//// Allows the controller to manage leader election Leases and
	//// ConfigMaps. Created in the cert-manager namespace (see TECH_DEBT.md
	//// regarding the Helm default of kube-system).
	/////////////////////////////////////////////////////////////////

	"controller-leaderelection-role": {
		resources_security.#Role

		spec: role: {
			name:  "cert-manager-controller:leaderelection"
			scope: "namespace"

			rules: [
				{
					apiGroups: ["coordination.k8s.io"]
					resources: ["leases"]
					verbs: ["get", "create", "update", "list", "watch", "delete"]
				},
				{
					apiGroups: [""]
					resources: ["configmaps"]
					verbs: ["get", "create", "update", "list", "watch", "delete"]
				},
			]

			subjects: [{name: "cert-manager"}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// CAInjector RBAC — ClusterRole: cert-manager-cainjector
	////
	//// Reads cert-manager Certificate objects and Secrets, then patches
	//// caBundle fields into ValidatingWebhookConfigurations,
	//// MutatingWebhookConfigurations, APIServices, and CRDs.
	/////////////////////////////////////////////////////////////////

	"cainjector-rbac": {
		resources_security.#Role

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
					verbs: ["get", "list", "watch", "update"]
				},
				{
					apiGroups: ["apiregistration.k8s.io"]
					resources: ["apiservices"]
					verbs: ["get", "list", "watch", "update"]
				},
				{
					apiGroups: ["apiextensions.k8s.io"]
					resources: ["customresourcedefinitions"]
					verbs: ["get", "list", "watch", "update"]
				},
				{
					apiGroups: ["batch"]
					resources: ["jobs"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: [""]
					resources: ["configmaps"]
					verbs: ["get", "list", "watch"]
				},
			]

			subjects: [{name: "cert-manager-cainjector"}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// CAInjector Role — namespace Role: cert-manager-cainjector:leaderelection
	////
	//// Allows the cainjector to manage leader election Leases and
	//// ConfigMaps in the leaderElection namespace.
	/////////////////////////////////////////////////////////////////

	"cainjector-leaderelection-role": {
		resources_security.#Role

		spec: role: {
			name:  "cert-manager-cainjector:leaderelection"
			scope: "namespace"

			rules: [
				{
					apiGroups: ["coordination.k8s.io"]
					resources: ["leases"]
					verbs: ["get", "create", "update", "list", "watch", "delete"]
				},
				{
					apiGroups: [""]
					resources: ["configmaps"]
					verbs: ["get", "create", "update", "list", "watch", "delete"]
				},
			]

			subjects: [{name: "cert-manager-cainjector"}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Webhook RBAC — ClusterRole: cert-manager-webhook:subjectaccessreviews
	////
	//// Allows the webhook to create SubjectAccessReview objects to
	//// authorize CertificateRequest approvals via RBAC.
	/////////////////////////////////////////////////////////////////

	"webhook-sar-rbac": {
		resources_security.#Role

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

	/////////////////////////////////////////////////////////////////
	//// Webhook Role — namespace Role: cert-manager-webhook:dynamic-serving
	////
	//// Allows the webhook to manage its dynamic TLS serving certificate
	//// Secret (cert-manager-webhook-ca) in the cert-manager namespace.
	/////////////////////////////////////////////////////////////////

	"webhook-dynamic-serving-role": {
		resources_security.#Role

		spec: role: {
			name:  "cert-manager-webhook:dynamic-serving"
			scope: "namespace"

			rules: [
				{
					apiGroups: [""]
					resources: ["secrets"]
					verbs: ["get", "list", "watch", "create", "update", "delete"]
				},
			]

			subjects: [{name: "cert-manager-webhook"}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Webhook Validating — ValidatingWebhookConfiguration: cert-manager-webhook
	////
	//// Registers the cert-manager admission webhook for validation of
	//// cert-manager.io and acme.cert-manager.io resources. The cainjector
	//// injects the CA bundle via the cert-manager.io/inject-apiserver-ca
	//// annotation. Excludes the cert-manager namespace and namespaces that
	//// opt out via the cert-manager.io/disable-validation label.
	////
	//// Source: cert-manager Helm chart v1.13.0 —
	//// templates/webhook-validatingwebhookconfiguration.yaml
	/////////////////////////////////////////////////////////////////

	"webhook-validating": {
		resources_admission.#ValidatingWebhookConfigurationComponent

		spec: validatingwebhookconfiguration: {
			metadata: {
				name: "cert-manager-webhook"
				labels: {
					"app":                         "webhook"
					"app.kubernetes.io/name":      "webhook"
					"app.kubernetes.io/instance":  "cert-manager"
					"app.kubernetes.io/component": "webhook"
					"app.kubernetes.io/version":   "v1.13.0"
				}
				annotations: {
					"cert-manager.io/inject-apiserver-ca": "true"
				}
			}
			webhooks: [
				{
					name: "webhook.cert-manager.io"
					admissionReviewVersions: ["v1"]
					matchPolicy:    "Equivalent"
					timeoutSeconds: 10
					failurePolicy:  "Fail"
					sideEffects:    "None"
					namespaceSelector: {
						matchExpressions: [
							{
								key:      "cert-manager.io/disable-validation"
								operator: "NotIn"
								values: ["true"]
							},
							{
								key:      "name"
								operator: "NotIn"
								values: ["cert-manager"]
							},
						]
					}
					rules: [
						{
							apiGroups: ["cert-manager.io", "acme.cert-manager.io"]
							apiVersions: ["v1"]
							operations: ["CREATE", "UPDATE"]
							resources: ["*/*"]
						},
					]
					clientConfig: service: {
						name:      "cert-manager-webhook"
						namespace: "cert-manager"
						path:      "/validate"
					}
				},
			]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Webhook Mutating — MutatingWebhookConfiguration: cert-manager-webhook
	////
	//// Registers the cert-manager admission webhook for mutation of
	//// cert-manager.io resources. The cainjector injects the CA bundle
	//// via the cert-manager.io/inject-apiserver-ca annotation.
	////
	//// Source: cert-manager Helm chart v1.13.0 —
	//// templates/webhook-mutatingwebhookconfiguration.yaml
	/////////////////////////////////////////////////////////////////

	"webhook-mutating": {
		resources_admission.#MutatingWebhookConfigurationComponent

		spec: mutatingwebhookconfiguration: {
			metadata: {
				name: "cert-manager-webhook"
				labels: {
					"app":                         "webhook"
					"app.kubernetes.io/name":      "webhook"
					"app.kubernetes.io/instance":  "cert-manager"
					"app.kubernetes.io/component": "webhook"
					"app.kubernetes.io/version":   "v1.13.0"
				}
				annotations: {
					"cert-manager.io/inject-apiserver-ca": "true"
				}
			}
			webhooks: [
				{
					name: "webhook.cert-manager.io"
					admissionReviewVersions: ["v1"]
					matchPolicy:    "Equivalent"
					timeoutSeconds: 10
					failurePolicy:  "Fail"
					sideEffects:    "None"
					rules: [
						{
							apiGroups: ["cert-manager.io"]
							apiVersions: ["v1"]
							operations: ["CREATE", "UPDATE"]
							resources: [
								"certificates/*",
								"issuers/*",
								"clusterissuers/*",
								"certificaterequests/*",
							]
						},
					]
					clientConfig: service: {
						name:      "cert-manager-webhook"
						namespace: "cert-manager"
						path:      "/mutate"
					}
				},
			]
		}
	}
}
