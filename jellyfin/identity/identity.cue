// Package identity is the single source of this module's path and version
// (core #IdentityPackage, enhancements 0010 D38 / 0011 D12). It sits at the
// bottom of the module's import graph — no intra-module imports, no core
// import; validation is external (a publishing tool unifies this package
// against core's #IdentityPackage).
package identity

// ModulePath is the module's complete CUE module path, major suffix included
// — byte-identical to cue.mod's `module:` field. Major v3: the v1 train
// already publishes opmodel.dev/modules/jellyfin at major v2 (cross-train
// major separation).
ModulePath: "opmodel.dev/modules/jellyfin@v3"

// Version is the module's bare SemVer; its major must agree with ModulePath's.
// A concrete literal, never a defaulted disjunction: the kernel's loader gate
// requires a value, and core's #IdentityPackage (which publish unifies this
// package against) supplies the SemVer constraint.
Version: "3.0.2"
