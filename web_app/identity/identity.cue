// Package identity is the single source of this module's path and version
// (core #IdentityPackage, enhancements 0010 D38 / 0011 D12). It sits at the
// bottom of the module's import graph — no intra-module imports, no core
// import; validation is external (a publishing tool unifies this package
// against core's #IdentityPackage).
package identity

// #VersionType mirrors core.#VersionType (SemVer 2.0), duplicated so this
// package stays import-free.
#VersionType: string & =~"^\\d+\\.\\d+\\.\\d+(-[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?(\\+[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?$"

// ModulePath is the module's complete CUE module path, major suffix included
// — byte-identical to cue.mod's `module:` field. Major v1: the v1 train
// already publishes opmodel.dev/modules/web_app at major v0 (cross-train
// major separation).
ModulePath: "opmodel.dev/modules/web_app@v1"

// Version is the module's bare SemVer; its major must agree with ModulePath's.
Version: #VersionType | *"1.0.0"
