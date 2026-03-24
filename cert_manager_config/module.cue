// cert-manager-config — deploys cert-manager custom resources into an existing installation.
// Manages ClusterIssuers, Certificates, and Issuers via optional keyed maps — omit a map
// entirely to skip that resource type.
//
// Requires cert-manager to already be running (use the cert-manager module first).
// https://cert-manager.io/docs/configuration/  |  https://cert-manager.io/docs/usage/certificate/
package cert_manager_config

import (
	m           "opmodel.dev/core/v1alpha1/module@v1"
	cm_security "opmodel.dev/cert_manager/v1alpha1/resources/security@v1"
)

m.#Module

metadata: {
	modulePath:       "opmodel.dev/modules"
	name:             "cert-manager-config"
	version:          "0.1.0"
	description:      "cert-manager custom resources — deploys ClusterIssuers, Certificates, and Issuers into an existing cert-manager installation"
	defaultNamespace: "cert-manager"
	labels: {
		"app.kubernetes.io/component": "certificate-management"
	}
}

#config: {
	// ClusterIssuers — cluster-scoped certificate authorities (e.g. Let's Encrypt, self-signed, CA).
	// Key is the ClusterIssuer resource name; value is the issuer spec.
	clusterIssuers?: {[string]: cm_security.#ClusterIssuerDefaults}

	// Certificates — TLS certificate requests bound to an Issuer or ClusterIssuer.
	// Key is the Certificate resource name; value is the certificate spec.
	certificates?: {[string]: cm_security.#CertificateDefaults}

	// Issuers — namespace-scoped certificate authorities.
	// Key is the Issuer resource name; value is the issuer spec.
	issuers?: {[string]: cm_security.#IssuerDefaults}
}

// debugValues exercises the full #config surface for local `cue vet` / `cue eval`.
debugValues: {
	clusterIssuers: {
		"selfsigned": {
			selfSigned: {}
		}
		"letsencrypt-staging": {
			acme: {
				server: "https://acme-staging-v02.api.letsencrypt.org/directory"
				email:  "admin@example.com"
				privateKeySecretRef: {name: "letsencrypt-staging-key"}
				solvers: [{http01: {ingress: {class: "istio"}}}]
			}
		}
	}
	certificates: {
		"gateway-tls": {
			secretName: "gateway-tls"
			dnsNames: ["gon1-nas2.local"]
			issuerRef: {name: "selfsigned", kind: "ClusterIssuer"}
		}
	}
	issuers: {
		"namespace-selfsigned": {
			selfSigned: {}
		}
	}
}
