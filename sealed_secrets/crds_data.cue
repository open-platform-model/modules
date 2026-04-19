// SealedSecret CRD definition — bitnami-labs/sealed-secrets v0.36.6.
// Full openAPIV3Schema preserved verbatim from the upstream controller.yaml
// so the apiserver performs field-level validation on user-authored
// SealedSecret manifests.
//
// Source: https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.36.6/controller.yaml
package sealed_secrets

#crd_sealedsecrets_bitnami_com: {
	apiVersion: "apiextensions.k8s.io/v1"
	kind:       "CustomResourceDefinition"
	metadata: name: "sealedsecrets.bitnami.com"
	spec: {
		group: "bitnami.com"
		names: {
			kind:     "SealedSecret"
			listKind: "SealedSecretList"
			plural:   "sealedsecrets"
			singular: "sealedsecret"
		}
		scope: "Namespaced"
		versions: [{
			name:    "v1alpha1"
			served:  true
			storage: true
			subresources: status: {}
			schema: openAPIV3Schema: {
				description: """
					SealedSecret is the K8s representation of a "sealed Secret" - a
					regular k8s Secret that has been sealed (encrypted) using the
					controller's key.
					"""
				type: "object"
				required: ["spec"]
				properties: {
					apiVersion: {
						description: """
							APIVersion defines the versioned schema of this representation of an object.
							Servers should convert recognized schemas to the latest internal value, and
							may reject unrecognized values.
							More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
							"""
						type: "string"
					}
					kind: {
						description: """
							Kind is a string value representing the REST resource this object represents.
							Servers may infer this from the endpoint the client submits requests to.
							Cannot be updated.
							In CamelCase.
							More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
							"""
						type: "string"
					}
					metadata: type: "object"
					spec: {
						description: "SealedSecretSpec is the specification of a SealedSecret."
						type:        "object"
						required: ["encryptedData"]
						properties: {
							data: {
								description: "Data is deprecated and will be removed eventually. Use per-value EncryptedData instead."
								format:      "byte"
								type:        "string"
							}
							encryptedData: {
								additionalProperties: type: "string"
								type:                                   "object"
								"x-kubernetes-preserve-unknown-fields": true
							}
							template: {
								description: """
									Template defines the structure of the Secret that will be
									created from this sealed secret.
									"""
								type: "object"
								properties: {
									data: {
										additionalProperties: type: "string"
										description: "Keys that should be templated using decrypted data."
										nullable:    true
										type:        "object"
									}
									immutable: {
										description: """
											Immutable, if set to true, ensures that data stored in the Secret cannot
											be updated (only object metadata can be modified).
											If not set to true, the field can be modified at any time.
											Defaulted to nil.
											"""
										type: "boolean"
									}
									metadata: {
										description: """
											Standard object's metadata.
											More info: https://git.k8s.io/community/contributors/devel/api-conventions.md#metadata
											"""
										nullable: true
										type:     "object"
										properties: {
											annotations: {
												additionalProperties: type: "string"
												type: "object"
											}
											finalizers: {
												items: type: "string"
												type: "array"
											}
											labels: {
												additionalProperties: type: "string"
												type: "object"
											}
											name: type:      "string"
											namespace: type: "string"
										}
										"x-kubernetes-preserve-unknown-fields": true
									}
									type: {
										description: "Used to facilitate programmatic handling of secret data."
										type:        "string"
									}
								}
							}
						}
					}
					status: {
						description: "SealedSecretStatus is the most recently observed status of the SealedSecret."
						type:        "object"
						properties: {
							conditions: {
								description: "Represents the latest available observations of a sealed secret's current state."
								type:        "array"
								items: {
									description: "SealedSecretCondition describes the state of a sealed secret at a certain point."
									type:        "object"
									required: ["status", "type"]
									properties: {
										lastTransitionTime: {
											description: "Last time the condition transitioned from one status to another."
											format:      "date-time"
											type:        "string"
										}
										lastUpdateTime: {
											description: "The last time this condition was updated."
											format:      "date-time"
											type:        "string"
										}
										message: {
											description: "A human readable message indicating details about the transition."
											type:        "string"
										}
										reason: {
											description: "The reason for the condition's last transition."
											type:        "string"
										}
										status: {
											description: """
												Status of the condition for a sealed secret.
												Valid values for "Synced": "True", "False", or "Unknown".
												"""
											type: "string"
										}
										type: {
											description: """
												Type of condition for a sealed secret.
												Valid value: "Synced"
												"""
											type: "string"
										}
									}
								}
							}
							observedGeneration: {
								description: "ObservedGeneration reflects the generation most recently observed by the sealed-secrets controller."
								format:      "int64"
								type:        "integer"
							}
						}
					}
				}
			}
		}]
	}
}
