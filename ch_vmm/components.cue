// Components for the ch-vmm module.
//
// Translated from the upstream release manifest (ch-vmm v1.4.0):
//   https://github.com/nalajala4naresh/ch-vmm/releases/latest/download/ch-vmm.yaml
//
// Components:
//   crds                            — 9 cloudhypervisor.quill.today CustomResourceDefinitions
//   controller                      — virtmanager-controller-manager Deployment + webhook Service
//   daemon                          — ch-vmm-daemon DaemonSet + headless Service
//   daemon-config                   — ConfigMap with daemon-conf.yaml (gRPC port + TLS paths)
//   controller-manager-role         — ClusterRole granting the controller full CR + PVC/Pod access
//   controller-leader-election-role — namespace Role for leader election Leases/ConfigMaps/Events
//   controller-metrics-auth-role    — ClusterRole for TokenReview + SubjectAccessReview (metrics auth)
//   vm-editor-role                  — aggregating ClusterRole (admin + edit) for VirtualMachines
//   vm-viewer-role                  — aggregating ClusterRole (view) for VirtualMachines
//   daemon-role                     — ClusterRole granting the per-node daemon VM/PVC/Pod access
//   controller-cert-issuer          — self-signed Issuer used for the webhook serving cert
//   controller-serving-cert         — Certificate producing the webhook-server-cert Secret
//   daemon-cert-issuer              — self-signed Issuer used for the daemon mTLS cert
//   daemon-cert                     — Certificate producing the ch-vmm-daemon-cert Secret
//   mutating-webhook                — MutatingWebhookConfiguration for 5 CR mutation paths
//   validating-webhook              — ValidatingWebhookConfiguration for 6 CR validation paths
//
// Known gaps (see DEPLOYMENT_NOTES.md):
//   - mountPropagation (Bidirectional/HostToContainer) not modeled by OPM — daemon may not work
//     for all VM disk flows until this is patched post-render or OPM schema is extended.
//   - Headless Service (clusterIP: None) for the daemon not expressible via #Expose — falls back
//     to ClusterIP. May break pod-direct DNS resolution if the controller relies on it.
//   - NetworkPolicies, virtmanager-metrics-reader (nonResourceURLs), and kustomize labels are
//     intentionally omitted from this first cut.
package ch_vmm

import (
	cm_security "opmodel.dev/cert_manager/v1alpha1/resources/security@v1"
	resources_admission "opmodel.dev/kubernetes/v1/resources/admission@v1"
	resources_config "opmodel.dev/opm/v1alpha1/resources/config@v1"
	resources_extension "opmodel.dev/opm/v1alpha1/resources/extension@v1"
	resources_security "opmodel.dev/opm/v1alpha1/resources/security@v1"
	resources_storage "opmodel.dev/opm/v1alpha1/resources/storage@v1"
	resources_workload "opmodel.dev/opm/v1alpha1/resources/workload@v1"
	traits_network "opmodel.dev/opm/v1alpha1/traits/network@v1"
	traits_security "opmodel.dev/opm/v1alpha1/traits/security@v1"
	traits_workload "opmodel.dev/opm/v1alpha1/traits/workload@v1"
)

// SA names — referenced from RBAC subjects, WorkloadIdentity, and webhook DNS.
let _controllerSA = "virtmanager-controller-manager"
let _daemonSA = "ch-vmm-daemon"

// Webhook Service DNS is fixed by the clientConfig.service.name/namespace contract.
let _webhookServiceName = "virtmanager-webhook-service"
let _daemonServiceName = "ch-vmm-daemon"

#components: {

	/////////////////////////////////////////////////////////////////
	//// CRDs — 9 cloudhypervisor.quill.today CustomResourceDefinitions
	////
	//// Installs VirtualDisk, VirtualDiskSnapshot, VirtualMachineMigration,
	//// VirtualMachine, VMPool, VMRestoreSpec, VMRollback, VMSet, VMSnapShot.
	//// Uses the simplified x-kubernetes-preserve-unknown-fields schema —
	//// see crds_data.cue.
	/////////////////////////////////////////////////////////////////

	crds: {
		resources_extension.#CRDs

		spec: crds: {
			for crdName, raw in #crds {
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
					}]
				}
			}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Controller — virtmanager-controller-manager (Deployment)
	////
	//// Kubebuilder-style controller. Reconciles VirtualMachine and friends,
	//// spawns per-VM Pods (fronted by ch-daemon on each node), and hosts the
	//// mutating/validating admission webhooks. The webhook TLS material is
	//// delivered by cert-manager via the virtmanager-serving-cert Certificate.
	/////////////////////////////////////////////////////////////////

	controller: {
		resources_workload.#Container
		resources_storage.#Volumes
		traits_workload.#Scaling
		traits_workload.#RestartPolicy
		traits_workload.#UpdateStrategy
		traits_workload.#GracefulShutdown
		traits_security.#SecurityContext
		traits_security.#WorkloadIdentity
		traits_network.#Expose

		metadata: {
			name: "controller"
			labels: {
				"core.opmodel.dev/workload-type": "stateless"
				"control-plane":                  "controller-manager"
			}
		}

		spec: {
			scaling: count: #config.controller.replicas

			restartPolicy: "Always"

			updateStrategy: type: "RollingUpdate"

			gracefulShutdown: terminationGracePeriodSeconds: 10

			workloadIdentity: {
				name:           _controllerSA
				automountToken: true
			}

			container: {
				name: "manager"
				image: {
					repository: #config.controllerImage.repository
					tag:        #config.controllerImage.tag
					digest:     #config.controllerImage.digest
					pullPolicy: #config.controllerImage.pullPolicy
				}

				args: [
					"--metrics-bind-address=:\(#config.controller.metricsPort)",
					"--leader-elect",
					"--health-probe-bind-address=:\(#config.controller.healthProbePort)",
				]

				env: {
					REGISTRY_CREDS_SECRET: {
						name:  "REGISTRY_CREDS_SECRET"
						value: #config.controller.registryCredsSecret
					}
				}

				ports: {
					"webhook-server": {
						name:       "webhook-server"
						targetPort: #config.controller.webhookPort
						protocol:   "TCP"
					}
				}

				livenessProbe: {
					httpGet: {
						path: "/healthz"
						port: #config.controller.healthProbePort
					}
					initialDelaySeconds: 15
					periodSeconds:       20
				}

				readinessProbe: {
					httpGet: {
						path: "/readyz"
						port: #config.controller.healthProbePort
					}
					initialDelaySeconds: 5
					periodSeconds:       10
				}

				if #config.controller.resources != _|_ {
					resources: #config.controller.resources
				}

				volumeMounts: {
					cert: volumes.cert & {
						mountPath: "/tmp/k8s-webhook-server/serving-certs"
						readOnly:  true
					}
				}
			}

			// Webhook serving certs delivered by cert-manager into webhook-server-cert Secret.
			// The Secret itself is not declared by this module — cert-manager's Certificate
			// reconciler creates and populates it. `from.name` references it by name only.
			volumes: {
				cert: {
					name: "cert"
					secret: {
						from: {
							name: "webhook-server-cert"
						}
						defaultMode: 420
					}
				}
			}

			// Webhook Service — virtmanager-webhook-service, port 443 → targetPort 9443.
			// Used by the MutatingWebhookConfiguration and ValidatingWebhookConfiguration
			// clientConfig entries.
			expose: {
				ports: {
					"webhook-server": container.ports."webhook-server" & {
						exposedPort: 443
					}
				}
				type: "ClusterIP"
			}

			securityContext: {
				allowPrivilegeEscalation: false
				capabilities: drop: ["ALL"]
			}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Daemon — ch-vmm-daemon (DaemonSet)
	////
	//// Runs on every node. Responsible for talking to Cloud Hypervisor,
	//// wiring VM network/storage, and reporting status back to the controller.
	//// Requires /dev/kvm, /var/lib/kubelet/pods (bidirectional propagation — see
	//// DEPLOYMENT_NOTES.md), and access to the kubelet's device-plugins socket.
	/////////////////////////////////////////////////////////////////

	daemon: {
		resources_workload.#Container
		resources_storage.#Volumes
		traits_workload.#RestartPolicy
		traits_workload.#UpdateStrategy
		traits_workload.#GracefulShutdown
		traits_security.#SecurityContext
		traits_security.#WorkloadIdentity
		traits_security.#HostPID
		traits_network.#Expose

		metadata: {
			name: _daemonServiceName
			labels: {
				"core.opmodel.dev/workload-type": "daemon"
				"name":                           _daemonServiceName
			}
		}

		spec: {
			restartPolicy: "Always"

			updateStrategy: {
				type: "RollingUpdate"
				rollingUpdate: maxUnavailable: 1
			}

			gracefulShutdown: terminationGracePeriodSeconds: 30

			// DaemonSet shares the node's PID namespace so it can observe/signal
			// Cloud Hypervisor processes it supervises.
			hostPid: true

			workloadIdentity: {
				name:           _daemonSA
				automountToken: true
			}

			container: {
				name: "ch-vmm-daemon"
				image: {
					repository: #config.daemonImage.repository
					tag:        #config.daemonImage.tag
					digest:     #config.daemonImage.digest
					pullPolicy: #config.daemonImage.pullPolicy
				}

				args: ["--zap-time-encoding=iso8601"]

				env: {
					NODE_NAME: {
						name: "NODE_NAME"
						fieldRef: fieldPath: "spec.nodeName"
					}
					NODE_IP: {
						name: "NODE_IP"
						fieldRef: fieldPath: "status.podIP"
					}
				}

				ports: {
					grpc: {
						name:       "grpc"
						targetPort: #config.daemon.grpcPort
						protocol:   "TCP"
					}
				}

				if #config.daemon.resources != _|_ {
					resources: #config.daemon.resources
				}

				// Privileged — daemon manages /dev/kvm, creates tap devices, etc.
				securityContext: {
					privileged: true
				}

				volumeMounts: {
					"daemon-config": volumes."daemon-config" & {
						mountPath: "/config"
					}
					"kubelet-pods": volumes."kubelet-pods" & {
						mountPath: "/pods"
						// NOTE: upstream requires mountPropagation: Bidirectional.
						// OPM VolumeMountSchema does not model mountPropagation yet —
						// see DEPLOYMENT_NOTES.md for the post-render patch workaround.
					}
					cert: volumes.cert & {
						mountPath: "/var/lib/virtmanager/daemon/cert"
						readOnly:  true
					}
					"device-plugins": volumes."device-plugins" & {
						mountPath: "/var/lib/kubelet/device-plugins"
					}
					devices: volumes.devices & {
						mountPath: "/dev"
						// NOTE: upstream requires mountPropagation: HostToContainer — see above.
					}
					"ch-vmm": volumes."ch-vmm" & {
						mountPath: "/var/run/ch-vmm"
					}
				}
			}

			volumes: {
				"daemon-config": {
					name: "daemon-config"
					configMap: {
						name: "daemon-config"
					}
				}
				"kubelet-pods": {
					name: "kubelet-pods"
					hostPath: {
						path: "/var/lib/kubelet/pods"
						type: "Directory"
					}
				}
				// ch-vmm-daemon-cert Secret is populated by cert-manager from the daemon Certificate.
				cert: {
					name: "cert"
					secret: {
						from: {
							name: "ch-vmm-daemon-cert"
						}
						defaultMode: 420
					}
				}
				"device-plugins": {
					name: "device-plugins"
					hostPath: {
						path: "/var/lib/kubelet/device-plugins"
						type: "Directory"
					}
				}
				devices: {
					name: "devices"
					hostPath: {
						path: "/dev"
						type: "Directory"
					}
				}
				"ch-vmm": {
					name: "ch-vmm"
					hostPath: {
						path: "/var/run/ch-vmm"
						type: "DirectoryOrCreate"
					}
				}
			}

			// Per-node gRPC endpoint. Upstream uses clusterIP: None (headless) so that
			// ch-vmm-daemon.ch-vmm-system.svc resolves to every pod's IP. OPM #Expose
			// does not currently emit headless services — falls back to ClusterIP.
			// See DEPLOYMENT_NOTES.md for the workaround.
			expose: {
				ports: {
					grpc: container.ports.grpc & {
						exposedPort: #config.daemon.grpcPort
					}
				}
				type: "ClusterIP"
			}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Daemon Config — ConfigMap: daemon-config
	////
	//// Contains daemon-conf.yaml consumed by the ch-vmm-daemon container.
	//// Advertises the gRPC port and the TLS material paths mounted from the
	//// ch-vmm-daemon-cert Secret.
	/////////////////////////////////////////////////////////////////

	"daemon-config-cm": {
		resources_config.#ConfigMaps

		spec: configMaps: {
			"daemon-config": {
				immutable: false
				data: {
					"daemon-conf.yaml": """
						grpc_port: \(#config.daemon.grpcPort)
						tls_config:
						  server_name: "ch-vmm-daemon.\(#config.namespace).svc"
						  key_file: "/var/lib/virtmanager/daemon/cert/tls.key"
						  cert_file: "/var/lib/virtmanager/daemon/cert/tls.crt"
						  ca_file: "/var/lib/virtmanager/daemon/cert/ca.crt"
						"""
				}
			}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Controller Manager ClusterRole — full reconciler permissions
	////
	//// Grants the controller CRUD access to every cloudhypervisor.quill.today
	//// resource, plus the Pods/PVCs it creates per VM, plus VolumeSnapshot and
	//// CDI DataVolume integration. Bound to the controller ServiceAccount.
	/////////////////////////////////////////////////////////////////

	"controller-manager-role": {
		resources_security.#Role

		metadata: name: "virtmanager-manager-role"

		spec: role: {
			name:  "virtmanager-manager-role"
			scope: "cluster"

			rules: [
				{
					apiGroups: [""]
					resources: ["events"]
					verbs: ["create", "patch", "update", "watch", "get"]
				},
				{
					apiGroups: [""]
					resources: ["persistentvolumeclaims"]
					verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
				},
				{
					apiGroups: [""]
					resources: ["pods"]
					verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
				},
				{
					apiGroups: [""]
					resources: ["pods/resize"]
					verbs: ["update"]
				},
				{
					apiGroups: ["cloudhypervisor.quill.today"]
					resources: ["virtualmachinemigrations"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: ["cloudhypervisor.quill.today"]
					resources: [
						"virtualmachinemigrations/status",
						"virtualmachines/status",
						"vmpools/status",
						"vmrollbacks/status",
						"vmsets/status",
						"vmsnapshots/status",
						"virtualdisks/status",
						"virtualdisksnapshots/status",
					]
					verbs: ["get", "patch", "update"]
				},
				{
					apiGroups: ["cloudhypervisor.quill.today"]
					resources: [
						"virtualmachines",
						"vmpools",
						"vmrollbacks",
						"vmsets",
						"vmsnapshots",
						"virtualdisks",
						"virtualdisksnapshots",
					]
					verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
				},
				{
					apiGroups: ["cloudhypervisor.quill.today"]
					resources: [
						"virtualmachines/finalizers",
						"vmpools/finalizers",
						"vmrollbacks/finalizers",
						"vmsets/finalizers",
						"vmsnapshots/finalizers",
						"virtualdisks/finalizers",
						"virtualdisksnapshots/finalizers",
					]
					verbs: ["update"]
				},
				{
					apiGroups: ["snapshot.storage.k8s.io"]
					resources: ["volumesnapshots", "volumesnapshotcontents", "volumesnapshotclasses"]
					verbs: ["get", "list", "watch", "create", "delete", "update", "patch"]
				},
				{
					apiGroups: ["cdi.kubevirt.io"]
					resources: ["datavolumes"]
					verbs: ["create", "patch", "list", "update", "watch", "delete"]
				},
			]

			subjects: [{name: _controllerSA}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Controller Leader-Election Role — namespace-scoped
	////
	//// Allows the controller to manage leader election leases/configmaps/events
	//// in its own namespace (default ch-vmm-system).
	/////////////////////////////////////////////////////////////////

	"controller-leader-election-role": {
		resources_security.#Role

		metadata: name: "virtmanager-leader-election-role"

		spec: role: {
			name:  "virtmanager-leader-election-role"
			scope: "namespace"

			rules: [
				{
					apiGroups: [""]
					resources: ["configmaps"]
					verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
				},
				{
					apiGroups: ["coordination.k8s.io"]
					resources: ["leases"]
					verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
				},
				{
					apiGroups: [""]
					resources: ["events"]
					verbs: ["create", "patch"]
				},
			]

			subjects: [{name: _controllerSA}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Controller Metrics Auth ClusterRole
	////
	//// Allows the controller's metrics endpoint to authenticate scrape
	//// requests via the Kubernetes TokenReview + SubjectAccessReview APIs.
	/////////////////////////////////////////////////////////////////

	"controller-metrics-auth-role": {
		resources_security.#Role

		metadata: name: "virtmanager-metrics-auth-role"

		spec: role: {
			name:  "virtmanager-metrics-auth-role"
			scope: "cluster"

			rules: [
				{
					apiGroups: ["authentication.k8s.io"]
					resources: ["tokenreviews"]
					verbs: ["create"]
				},
				{
					apiGroups: ["authorization.k8s.io"]
					resources: ["subjectaccessreviews"]
					verbs: ["create"]
				},
			]

			subjects: [{name: _controllerSA}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// VirtualMachine Editor ClusterRole — aggregates to admin + edit
	////
	//// Grants cluster admins and namespace editors the ability to manage
	//// VirtualMachine resources without a separate explicit binding.
	/////////////////////////////////////////////////////////////////

	"vm-editor-role": {
		resources_security.#Role

		metadata: {
			name: "virtmanager-virtualmachine-editor-role"
			labels: {
				"rbac.authorization.k8s.io/aggregate-to-admin": "true"
				"rbac.authorization.k8s.io/aggregate-to-edit":  "true"
			}
		}

		spec: role: {
			name:  "virtmanager-virtualmachine-editor-role"
			scope: "cluster"

			rules: [
				{
					apiGroups: ["cloudhypervisor.quill.today"]
					resources: ["virtualmachines"]
					verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
				},
				{
					apiGroups: ["cloudhypervisor.quill.today"]
					resources: ["virtualmachines/status"]
					verbs: ["get"]
				},
			]

			// Aggregation rules do not require subjects; the built-in admin/edit roles
			// aggregate this one via label selector. Subject included for OPM schema
			// compatibility (#RoleSchema requires ≥1 subject) — the binding is a no-op
			// because the controller SA already has broader access via controller-manager-role.
			subjects: [{name: _controllerSA}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// VirtualMachine Viewer ClusterRole — aggregates to view
	/////////////////////////////////////////////////////////////////

	"vm-viewer-role": {
		resources_security.#Role

		metadata: {
			name: "virtmanager-virtualmachine-viewer-role"
			labels: {
				"rbac.authorization.k8s.io/aggregate-to-view": "true"
			}
		}

		spec: role: {
			name:  "virtmanager-virtualmachine-viewer-role"
			scope: "cluster"

			rules: [
				{
					apiGroups: ["cloudhypervisor.quill.today"]
					resources: ["virtualmachines"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: ["cloudhypervisor.quill.today"]
					resources: ["virtualmachines/status"]
					verbs: ["get"]
				},
			]

			subjects: [{name: _controllerSA}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Daemon ClusterRole — per-node daemon permissions
	////
	//// The daemon reads PVCs/Pods it must hand to Cloud Hypervisor, manages
	//// VirtualMachine status + finalizers for the VM it hosts, and touches
	//// VolumeSnapshot + CDI DataVolume objects during VM lifecycle.
	/////////////////////////////////////////////////////////////////

	"daemon-role": {
		resources_security.#Role

		metadata: name: "ch-vmm-daemon"

		spec: role: {
			name:  "ch-vmm-daemon"
			scope: "cluster"

			rules: [
				{
					apiGroups: [""]
					resources: ["events"]
					verbs: ["create", "patch", "update"]
				},
				{
					apiGroups: [""]
					resources: ["persistentvolumeclaims"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: [""]
					resources: ["pods"]
					verbs: ["get", "list", "watch", "create", "update", "delete"]
				},
				{
					apiGroups: ["cloudhypervisor.quill.today"]
					resources: [
						"virtualmachines",
						"vmsnapshots",
						"vmrollbacks",
						"vmrestorespecs",
						"virtualmachinemigrations",
						"virtualdisks",
						"virtualdisksnapshots",
					]
					verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
				},
				{
					apiGroups: ["cloudhypervisor.quill.today"]
					resources: [
						"virtualmachines/finalizers",
						"vmsnapshots/finalizers",
						"virtualdisks/finalizers",
						"virtualdisksnapshots/finalizers",
					]
					verbs: ["update"]
				},
				{
					apiGroups: ["cloudhypervisor.quill.today"]
					resources: ["virtualmachines/status", "vmsnapshots/status"]
					verbs: ["get", "patch", "update"]
				},
				{
					apiGroups: ["snapshot.storage.k8s.io"]
					resources: ["volumesnapshots", "volumesnapshotcontents", "volumesnapshotclasses"]
					verbs: ["get", "list", "watch", "create", "delete"]
				},
				{
					apiGroups: ["cdi.kubevirt.io"]
					resources: ["datavolumes"]
					verbs: ["create", "patch", "list", "update", "watch", "delete"]
				},
			]

			subjects: [{name: _daemonSA}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Controller Cert Issuer — self-signed cert-manager Issuer
	////
	//// Signs the webhook-server-cert Certificate used by the MutatingWebhook
	//// and ValidatingWebhook configurations.
	/////////////////////////////////////////////////////////////////

	"controller-cert-issuer": {
		cm_security.#Issuer

		metadata: name: "virtmanager-selfsigned-issuer"

		spec: issuer: {
			selfSigned: {}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Controller Serving Certificate
	////
	//// Delivers TLS material for the webhook HTTPS server into the
	//// webhook-server-cert Secret, consumed by the controller Deployment.
	/////////////////////////////////////////////////////////////////

	"controller-serving-cert": {
		cm_security.#Certificate

		metadata: name: "virtmanager-serving-cert"

		spec: certificate: {
			secretName: "webhook-server-cert"
			issuerRef: {
				kind: "Issuer"
				name: "virtmanager-selfsigned-issuer"
			}
			dnsNames: [
				"\(_webhookServiceName).\(#config.namespace).svc",
				"\(_webhookServiceName).\(#config.namespace).svc.cluster.local",
			]
			duration:    #config.certificates.duration
			renewBefore: #config.certificates.renewBefore
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Daemon Cert Issuer — self-signed cert-manager Issuer
	/////////////////////////////////////////////////////////////////

	"daemon-cert-issuer": {
		cm_security.#Issuer

		metadata: name: "ch-vmm-daemon-cert-issuer"

		spec: issuer: {
			selfSigned: {}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Daemon Certificate
	////
	//// Delivers TLS material for the daemon's gRPC listener into the
	//// ch-vmm-daemon-cert Secret. Includes the wildcard *.ch-vmm-daemon.<ns>.svc
	//// DNS name to support the headless Service addressing scheme upstream.
	/////////////////////////////////////////////////////////////////

	"daemon-cert": {
		cm_security.#Certificate

		metadata: name: "ch-vmm-daemon-cert"

		spec: certificate: {
			secretName: "ch-vmm-daemon-cert"
			issuerRef: {
				kind: "Issuer"
				name: "ch-vmm-daemon-cert-issuer"
			}
			dnsNames: [
				"\(_daemonServiceName).\(#config.namespace).svc",
				"\(_daemonServiceName).\(#config.namespace).svc.cluster.local",
				"*.\(_daemonServiceName).\(#config.namespace).svc",
				"*.\(_daemonServiceName).\(#config.namespace).svc.cluster.local",
			]
			duration:    #config.certificates.duration
			renewBefore: #config.certificates.renewBefore
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Mutating Admission Webhook — virtmanager-mutating-webhook-configuration
	////
	//// Mutates VirtualMachine, VirtualDisk, VirtualDiskSnapshot, VMPool, VMSet
	//// on CREATE and UPDATE. CA bundle injected by cert-manager via the
	//// cert-manager.io/inject-ca-from annotation.
	/////////////////////////////////////////////////////////////////

	"mutating-webhook": {
		resources_admission.#MutatingWebhookConfiguration

		spec: mutatingwebhookconfiguration: {
			metadata: {
				name: "virtmanager-mutating-webhook-configuration"
				annotations: {
					"cert-manager.io/inject-ca-from": "\(#config.namespace)/virtmanager-serving-cert"
				}
			}
			webhooks: [
				{
					name: "mvirtualmachine.kb.io"
					admissionReviewVersions: ["v1"]
					failurePolicy: "Fail"
					sideEffects:   "None"
					clientConfig: service: {
						name:      _webhookServiceName
						namespace: #config.namespace
						path:      "/mutate-cloudhypervisor-quill-today-v1beta1-virtualmachine"
					}
					rules: [{
						apiGroups: ["cloudhypervisor.quill.today"]
						apiVersions: ["v1beta1"]
						operations: ["CREATE", "UPDATE"]
						resources: ["virtualmachines"]
					}]
				},
				{
					name: "mvirtualdisk-v1beta1.kb.io"
					admissionReviewVersions: ["v1"]
					failurePolicy: "Fail"
					sideEffects:   "None"
					clientConfig: service: {
						name:      _webhookServiceName
						namespace: #config.namespace
						path:      "/mutate-cloudhypervisor-quill-today-v1beta1-virtualdisk"
					}
					rules: [{
						apiGroups: ["cloudhypervisor.quill.today"]
						apiVersions: ["v1beta1"]
						operations: ["CREATE", "UPDATE"]
						resources: ["virtualdisks"]
					}]
				},
				{
					name: "mvirtualdisksnapshot-v1beta1.kb.io"
					admissionReviewVersions: ["v1"]
					failurePolicy: "Fail"
					sideEffects:   "None"
					clientConfig: service: {
						name:      _webhookServiceName
						namespace: #config.namespace
						path:      "/mutate-cloudhypervisor-quill-today-v1beta1-virtualdisksnapshot"
					}
					rules: [{
						apiGroups: ["cloudhypervisor.quill.today"]
						apiVersions: ["v1beta1"]
						operations: ["CREATE", "UPDATE"]
						resources: ["virtualdisksnapshots"]
					}]
				},
				{
					name: "mvmpool-v1beta1.kb.io"
					admissionReviewVersions: ["v1"]
					failurePolicy: "Fail"
					sideEffects:   "None"
					clientConfig: service: {
						name:      _webhookServiceName
						namespace: #config.namespace
						path:      "/mutate-cloudhypervisor-quill-today-v1beta1-vmpool"
					}
					rules: [{
						apiGroups: ["cloudhypervisor.quill.today"]
						apiVersions: ["v1beta1"]
						operations: ["CREATE", "UPDATE"]
						resources: ["vmpools"]
					}]
				},
				{
					name: "mvmset-v1beta1.kb.io"
					admissionReviewVersions: ["v1"]
					failurePolicy: "Fail"
					sideEffects:   "None"
					clientConfig: service: {
						name:      _webhookServiceName
						namespace: #config.namespace
						path:      "/mutate-cloudhypervisor-quill-today-v1beta1-vmset"
					}
					rules: [{
						apiGroups: ["cloudhypervisor.quill.today"]
						apiVersions: ["v1beta1"]
						operations: ["CREATE", "UPDATE"]
						resources: ["vmsets"]
					}]
				},
			]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Validating Admission Webhook — virtmanager-validating-webhook-configuration
	////
	//// Validates 6 CR types on CREATE and UPDATE.
	/////////////////////////////////////////////////////////////////

	"validating-webhook": {
		resources_admission.#ValidatingWebhookConfiguration

		spec: validatingwebhookconfiguration: {
			metadata: {
				name: "virtmanager-validating-webhook-configuration"
				annotations: {
					"cert-manager.io/inject-ca-from": "\(#config.namespace)/virtmanager-serving-cert"
				}
			}
			webhooks: [
				{
					name: "vvirtualdisk-v1beta1.kb.io"
					admissionReviewVersions: ["v1"]
					failurePolicy: "Fail"
					sideEffects:   "None"
					clientConfig: service: {
						name:      _webhookServiceName
						namespace: #config.namespace
						path:      "/validate-cloudhypervisor-quill-today-v1beta1-virtualdisk"
					}
					rules: [{
						apiGroups: ["cloudhypervisor.quill.today"]
						apiVersions: ["v1beta1"]
						operations: ["CREATE", "UPDATE"]
						resources: ["virtualdisks"]
					}]
				},
				{
					name: "vvirtualdisksnapshot-v1beta1.kb.io"
					admissionReviewVersions: ["v1"]
					failurePolicy: "Fail"
					sideEffects:   "None"
					clientConfig: service: {
						name:      _webhookServiceName
						namespace: #config.namespace
						path:      "/validate-cloudhypervisor-quill-today-v1beta1-virtualdisksnapshot"
					}
					rules: [{
						apiGroups: ["cloudhypervisor.quill.today"]
						apiVersions: ["v1beta1"]
						operations: ["CREATE", "UPDATE"]
						resources: ["virtualdisksnapshots"]
					}]
				},
				{
					name: "vvirtualmachine.kb.io"
					admissionReviewVersions: ["v1"]
					failurePolicy: "Fail"
					sideEffects:   "None"
					clientConfig: service: {
						name:      _webhookServiceName
						namespace: #config.namespace
						path:      "/validate-cloudhypervisor-quill-today-v1beta1-virtualmachine"
					}
					rules: [{
						apiGroups: ["cloudhypervisor.quill.today"]
						apiVersions: ["v1beta1"]
						operations: ["CREATE", "UPDATE"]
						resources: ["virtualmachines"]
					}]
				},
				{
					name: "vvirtualmachinemigration.kb.io"
					admissionReviewVersions: ["v1"]
					failurePolicy: "Fail"
					sideEffects:   "None"
					clientConfig: service: {
						name:      _webhookServiceName
						namespace: #config.namespace
						path:      "/validate-cloudhypervisor-quill-today-v1beta1-virtualmachinemigration"
					}
					rules: [{
						apiGroups: ["cloudhypervisor.quill.today"]
						apiVersions: ["v1beta1"]
						operations: ["CREATE", "UPDATE"]
						resources: ["virtualmachinemigrations"]
					}]
				},
				{
					name: "vvmset-v1beta1.kb.io"
					admissionReviewVersions: ["v1"]
					failurePolicy: "Fail"
					sideEffects:   "None"
					clientConfig: service: {
						name:      _webhookServiceName
						namespace: #config.namespace
						path:      "/validate-cloudhypervisor-quill-today-v1beta1-vmset"
					}
					rules: [{
						apiGroups: ["cloudhypervisor.quill.today"]
						apiVersions: ["v1beta1"]
						operations: ["CREATE", "UPDATE"]
						resources: ["vmsets"]
					}]
				},
				{
					name: "vvmpool-v1beta1.kb.io"
					admissionReviewVersions: ["v1"]
					failurePolicy: "Fail"
					sideEffects:   "None"
					clientConfig: service: {
						name:      _webhookServiceName
						namespace: #config.namespace
						path:      "/validate-cloudhypervisor-quill-today-v1beta1-vmpool"
					}
					rules: [{
						apiGroups: ["cloudhypervisor.quill.today"]
						apiVersions: ["v1beta1"]
						operations: ["CREATE", "UPDATE"]
						resources: ["vmpools"]
					}]
				},
			]
		}
	}
}
