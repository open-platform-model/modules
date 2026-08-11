package istio_ambient

import (
	res "opmodel.dev/catalogs/opm/resources/v1beta1"
)

/////////////////////////////////////////////////////////////////
//// RBAC
////
//// Six ClusterRoles and one namespaced Role, each with the binding #Role
//// emits automatically. Rules are transcribed from `helm template` of the
//// ambient chart at 1.30.3 — one component per upstream role, so a rule
//// change upstream lands in exactly one place here.
////
//// Names embed the namespace (istiod-clusterrole-<ns>) exactly as upstream
//// does, because they are cluster-scoped and must not collide between
//// meshes.
////
//// Note istio-cni-ambient carries `resourceNames: ["istio-cni-node"]` — the
//// agent reads its own DaemonSet, and that scoping only works because the
//// DaemonSet renders under that exact name.
/////////////////////////////////////////////////////////////////

#components: {
	// Created by the base chart upstream, and referenced as a binding subject
	// by istio-reader-clusterrole. Without it that binding dangles.
	"istio-reader-sa": {
		res.#ServiceAccount

		spec: serviceAccount: {
			name:           "istio-reader-service-account"
			automountToken: true
		}
	}

	"istio-cni-rbac": {
		res.#Role

		spec: role: {
			name:  "istio-cni"
			scope: "cluster"

			rules: [
				{
					apiGroups: [""]
					resources: ["pods", "nodes", "namespaces"]
					verbs: ["get", "list", "watch"]
				},
			]

			subjects: [{name: "istio-cni"}]
		}
	}

	"istio-cni-ambient-rbac": {
		res.#Role

		spec: role: {
			name:  "istio-cni-ambient"
			scope: "cluster"

			rules: [
				{
					apiGroups: [""]
					resources: ["pods/status"]
					verbs: ["patch", "update"]
				},
				{
					apiGroups: ["apps"]
					resources: ["daemonsets"]
					verbs: ["get"]
					resourceNames: ["istio-cni-node"]
				},
			]

			subjects: [{name: "istio-cni"}]
		}
	}

	"istio-cni-repair-role-rbac": {
		res.#Role

		spec: role: {
			name:  "istio-cni-repair-role"
			scope: "cluster"

			rules: [
				{
					apiGroups: [""]
					resources: ["events"]
					verbs: ["create", "patch"]
				},
				{
					apiGroups: [""]
					resources: ["pods"]
					verbs: ["watch", "get", "list"]
				},
			]

			subjects: [{name: "istio-cni"}]
		}
	}

	"istio-reader-clusterrole-rbac": {
		res.#Role

		spec: role: {
			name:  "istio-reader-clusterrole-\(#config.namespace.name)"
			scope: "cluster"

			rules: [
				{
					apiGroups: ["config.istio.io", "security.istio.io", "networking.istio.io", "authentication.istio.io", "rbac.istio.io", "telemetry.istio.io", "extensions.istio.io"]
					resources: ["*"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: [""]
					resources: ["endpoints", "pods", "services", "nodes", "replicationcontrollers", "namespaces", "secrets", "configmaps"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: ["networking.istio.io"]
					resources: ["workloadentries"]
					verbs: ["get", "watch", "list"]
				},
				{
					apiGroups: ["networking.x-k8s.io", "gateway.networking.k8s.io"]
					resources: ["gateways"]
					verbs: ["get", "watch", "list"]
				},
				{
					apiGroups: ["apiextensions.k8s.io"]
					resources: ["customresourcedefinitions"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: ["discovery.k8s.io"]
					resources: ["endpointslices"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: ["multicluster.x-k8s.io"]
					resources: ["serviceexports"]
					verbs: ["get", "list", "watch", "create", "delete"]
				},
				{
					apiGroups: ["multicluster.x-k8s.io"]
					resources: ["serviceimports"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: ["apps"]
					resources: ["replicasets"]
					verbs: ["get", "list", "watch"]
				},
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

			subjects: [{name: "istio-reader-service-account"}]
		}
	}

	"istiod-clusterrole-rbac": {
		res.#Role

		spec: role: {
			name:  "istiod-clusterrole-\(#config.namespace.name)"
			scope: "cluster"

			rules: [
				{
					apiGroups: ["admissionregistration.k8s.io"]
					resources: ["mutatingwebhookconfigurations"]
					verbs: ["get", "list", "watch", "update", "patch"]
				},
				{
					apiGroups: ["admissionregistration.k8s.io"]
					resources: ["validatingwebhookconfigurations"]
					verbs: ["get", "list", "watch", "update"]
				},
				{
					apiGroups: ["config.istio.io", "security.istio.io", "networking.istio.io", "authentication.istio.io", "rbac.istio.io", "telemetry.istio.io", "extensions.istio.io"]
					resources: ["*"]
					verbs: ["get", "watch", "list"]
				},
				{
					apiGroups: ["networking.istio.io"]
					resources: ["workloadentries"]
					verbs: ["get", "watch", "list", "update", "patch", "create", "delete"]
				},
				{
					apiGroups: ["networking.istio.io"]
					resources: ["workloadentries/status", "serviceentries/status"]
					verbs: ["get", "watch", "list", "update", "patch", "create", "delete"]
				},
				{
					apiGroups: ["security.istio.io"]
					resources: ["authorizationpolicies/status"]
					verbs: ["get", "watch", "list", "update", "patch", "create", "delete"]
				},
				{
					apiGroups: [""]
					resources: ["services/status"]
					verbs: ["get", "watch", "list", "update", "patch", "create", "delete"]
				},
				{
					apiGroups: ["apiextensions.k8s.io"]
					resources: ["customresourcedefinitions"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: [""]
					resources: ["pods", "nodes", "services", "namespaces", "endpoints"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: ["discovery.k8s.io"]
					resources: ["endpointslices"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: ["networking.k8s.io"]
					resources: ["ingresses", "ingressclasses"]
					verbs: ["get", "list", "watch"]
				},
				{
					apiGroups: ["networking.k8s.io"]
					resources: ["ingresses/status"]
					verbs: ["*"]
				},
				{
					apiGroups: [""]
					resources: ["configmaps"]
					verbs: ["create", "get", "list", "watch", "update"]
				},
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
				{
					apiGroups: ["gateway.networking.k8s.io", "gateway.networking.x-k8s.io"]
					resources: ["*"]
					verbs: ["get", "watch", "list"]
				},
				{
					apiGroups: ["gateway.networking.x-k8s.io"]
					resources: ["xbackendtrafficpolicies/status"]
					verbs: ["update", "patch"]
				},
				{
					apiGroups: ["gateway.networking.k8s.io"]
					resources: ["backendtlspolicies/status", "gatewayclasses/status", "gateways/status", "grpcroutes/status", "httproutes/status", "referencegrants/status", "tcproutes/status", "tlsroutes/status", "udproutes/status", "listenersets/status"]
					verbs: ["update", "patch"]
				},
				{
					apiGroups: ["gateway.networking.k8s.io"]
					resources: ["gatewayclasses"]
					verbs: ["create", "update", "patch", "delete"]
				},
				{
					apiGroups: ["inference.networking.k8s.io"]
					resources: ["inferencepools"]
					verbs: ["get", "watch", "list"]
				},
				{
					apiGroups: ["inference.networking.k8s.io"]
					resources: ["inferencepools/status"]
					verbs: ["update", "patch"]
				},
				{
					apiGroups: [""]
					resources: ["secrets"]
					verbs: ["get", "watch", "list"]
				},
				{
					apiGroups: ["multicluster.x-k8s.io"]
					resources: ["serviceexports"]
					verbs: ["get", "watch", "list", "create", "delete"]
				},
				{
					apiGroups: ["multicluster.x-k8s.io"]
					resources: ["serviceimports"]
					verbs: ["get", "watch", "list"]
				},
			]

			subjects: [{name: "istiod"}]
		}
	}

	"istiod-gateway-controller-rbac": {
		res.#Role

		spec: role: {
			name:  "istiod-gateway-controller-\(#config.namespace.name)"
			scope: "cluster"

			rules: [
				{
					apiGroups: ["apps"]
					resources: ["deployments"]
					verbs: ["get", "watch", "list", "update", "patch", "create", "delete"]
				},
				{
					apiGroups: ["autoscaling"]
					resources: ["horizontalpodautoscalers"]
					verbs: ["get", "watch", "list", "update", "patch", "create", "delete"]
				},
				{
					apiGroups: ["policy"]
					resources: ["poddisruptionbudgets"]
					verbs: ["get", "watch", "list", "update", "patch", "create", "delete"]
				},
				{
					apiGroups: [""]
					resources: ["services"]
					verbs: ["get", "watch", "list", "update", "patch", "create", "delete"]
				},
				{
					apiGroups: [""]
					resources: ["serviceaccounts"]
					verbs: ["get", "watch", "list", "update", "patch", "create", "delete"]
				},
			]

			subjects: [{name: "istiod"}]
		}
	}

	"istiod-role": {
		res.#Role

		spec: role: {
			name:  "istiod"
			scope: "namespace"

			rules: [
				{
					apiGroups: ["networking.istio.io"]
					resources: ["gateways"]
					verbs: ["create"]
				},
				{
					apiGroups: [""]
					resources: ["secrets"]
					verbs: ["create", "get", "watch", "list", "update", "delete"]
				},
				{
					apiGroups: [""]
					resources: ["configmaps"]
					verbs: ["delete"]
				},
				{
					apiGroups: ["coordination.k8s.io"]
					resources: ["leases"]
					verbs: ["get", "update", "patch", "create"]
				},
			]

			subjects: [{name: "istiod"}]
		}
	}
}
