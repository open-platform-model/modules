package istio_ambient

import (
	res "opmodel.dev/catalogs/opm/resources/v1beta1"
)

// Shared projection from a vendored upstream CRD struct to #CRDSchema.
//
// selectableFields is not cosmetic: the API server rejects a --field-selector
// on a field the CRD does not declare, so dropping it breaks
// `kubectl get orders --field-selector spec.issuerRef.name=...` style queries
// that controllers depend on.
#ProjectCRDs: {
	#in!: _

	out: {
		for crdName, raw in #in {
			(crdName): {
				// Load-bearing for the Gateway API set: gateway.networking.k8s.io
				// is a PROTECTED group, and the API server rejects any CRD in a
				// *.k8s.io group that lacks api-approved.kubernetes.io — which
				// fails the whole ModuleInstance atomically at dry-run, not just
				// the eight offending CRDs. The Istio CRDs live in *.istio.io
				// (unprotected) and carry no annotations at all, hence the guard.
				if raw.metadata.annotations != _|_ {annotations: raw.metadata.annotations}

				group: raw.spec.group
				names: {
					kind:   raw.spec.names.kind
					plural: raw.spec.names.plural
					if raw.spec.names.listKind != _|_ {listKind: raw.spec.names.listKind}
					if raw.spec.names.singular != _|_ {singular: raw.spec.names.singular}
					if raw.spec.names.shortNames != _|_ {shortNames: raw.spec.names.shortNames}
					if raw.spec.names.categories != _|_ {categories: raw.spec.names.categories}
				}
				scope: raw.spec.scope
				versions: [for v in raw.spec.versions {
					name:    v.name
					served:  v.served
					storage: v.storage
					if v.schema != _|_ {schema: v.schema}
					if v.subresources != _|_ {subresources: v.subresources}
					if v.additionalPrinterColumns != _|_ {additionalPrinterColumns: v.additionalPrinterColumns}
					if v.selectableFields != _|_ {selectableFields: v.selectableFields}
				}]
			}
		}
	}
}

#components: {
	// The 15 Istio CRDs from the base chart at 1.30.3. 1.30 adds
	// trafficextensions.extensions.istio.io over the 1.28 line.
	crds: {
		res.#CRDs

		spec: crds: (#ProjectCRDs & {#in: _istioCRDs}).out
	}

	// Gateway API standard channel v1.5.1 — 8 CRDs. NOT part of the ambient
	// chart; see #config.gatewayAPI.enabled.
	if #config.gatewayAPI.enabled {
		"crds-gatewayapi": {
			res.#CRDs

			spec: crds: (#ProjectCRDs & {#in: _gwapiCRDs}).out
		}
	}
}

/////////////////////////////////////////////////////////////////
//// Guards
////
//// Asserted against the vendored data rather than the rendered components,
//// deliberately. #components["crds-gatewayapi"] only exists when the flag is
//// on, and a guard that references a non-existent field is merely incomplete
//// — which plain `cue vet` accepts, so it would pass no matter what the
//// projection did. Verified: breaking the count on the gated component
//// produced no error at all.
/////////////////////////////////////////////////////////////////

_istioCRDCount: (len(_istioCRDs) + 0) & 15
_gwapiCRDCount: (len(_gwapiCRDs) + 0) & 8

// The projection itself is exercised ungated, so it is covered whether or not
// the Gateway API component is switched on.
_gwapiProjected: (#ProjectCRDs & {#in: _gwapiCRDs}).out
_gwapiProjectedCount: (len(_gwapiProjected) + 0) & 8

// ALL EIGHT Gateway API CRDs must carry api-approved.kubernetes.io. Without it
// the API server rejects them, and because the operator applies a module
// atomically that failure takes down the entire ModuleInstance — the mesh
// included, not just the Gateway API. Counted rather than named: arithmetic
// forces resolution, so a projection that dropped the annotation cannot have
// the value handed back to it by unification.
_gwapiApprovedCount: (len([
	for _, crd in _gwapiProjected
	if crd.annotations != _|_
	if crd.annotations["api-approved.kubernetes.io"] != _|_ {crd},
]) + 0) & 8

// listKind is carried: it is optional in #CRDSchema, so a dropped passthrough
// would be an absent field, which arithmetic cannot catch.
_gwapiListKindCarried: [
	if _gwapiProjected["httproutes.gateway.networking.k8s.io"].names.listKind != _|_ {
		_gwapiProjected["httproutes.gateway.networking.k8s.io"].names.listKind
	},
] & ["HTTPRouteList"]
