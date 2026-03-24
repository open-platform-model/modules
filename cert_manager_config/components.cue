// Components for the cert-manager-config module.
//
// Three dynamic component sets, each driven by an optional #config map:
//   clusterIssuers — one #ClusterIssuerComponent per entry in #config.clusterIssuers
//   certificates   — one #CertificateComponent per entry in #config.certificates
//   issuers        — one #IssuerComponent per entry in #config.issuers
//
// All three sets are optional — omit a map in #config to skip that resource type entirely.
package cert_manager_config

import (
	cm_security "opmodel.dev/cert_manager/v1alpha1/resources/security@v1"
)

#components: {

	/////////////////////////////////////////////////////////////////
	//// ClusterIssuers — cluster-scoped certificate authorities
	////
	//// Deploys one ClusterIssuer per entry in #config.clusterIssuers.
	//// ClusterIssuers are cluster-scoped; namespace is not applicable.
	//// Common backends: selfSigned, ca, acme (Let's Encrypt), vault.
	/////////////////////////////////////////////////////////////////

	if #config.clusterIssuers != _|_ {
		for name, issuerSpec in #config.clusterIssuers {
			(name): {
				cm_security.#ClusterIssuerComponent
				spec: clusterIssuer: issuerSpec
			}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Certificates — TLS certificate requests
	////
	//// Deploys one Certificate per entry in #config.certificates.
	//// Each Certificate references an Issuer or ClusterIssuer via
	//// spec.certificate.issuerRef. The signed cert is stored in the
	//// Secret named by spec.certificate.secretName.
	/////////////////////////////////////////////////////////////////

	if #config.certificates != _|_ {
		for name, certSpec in #config.certificates {
			(name): {
				cm_security.#CertificateComponent
				spec: certificate: certSpec
			}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// Issuers — namespace-scoped certificate authorities
	////
	//// Deploys one Issuer per entry in #config.issuers.
	//// Issuers are namespace-scoped and deploy into defaultNamespace.
	//// Use ClusterIssuers instead when cross-namespace signing is needed.
	/////////////////////////////////////////////////////////////////

	if #config.issuers != _|_ {
		for name, issuerSpec in #config.issuers {
			(name): {
				cm_security.#IssuerComponent
				spec: issuer: issuerSpec
			}
		}
	}
}
