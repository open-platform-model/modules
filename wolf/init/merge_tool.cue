package init

// merge_tool.cue — Wolf config-init CUE tool.
//
// Runs inside the config-init init container on every pod start.
// Merges the immutable ConfigMap config with preserved paired_clients
// from the persistent on-disk config.
//
// Mount layout (set by the config-init init container spec):
//   /etc/wolf-init/cfg/config.toml  — incoming config from ConfigMap (read-only)
//   /etc/wolf/cfg/config.toml       — on-disk config on the persistent PVC (read-write)
//
// Merge logic:
//   1. Copy the incoming ConfigMap file verbatim to a temp output path.
//   2. If the existing PVC file has content, extract every [[paired_clients]]
//      block from it with awk and append those blocks to the temp output.
//   3. Atomically rename temp output → /etc/wolf/cfg/config.toml.
//
// Bypasses encoding/toml.Unmarshal entirely to avoid a CUE v0.12 bug where
// nested array-of-tables ([[profiles.apps]] / [profiles.apps.runner]) are
// rejected with "duplicate key" even though they are valid TOML.
//
// First start: existing file is empty (touched by entrypoint) — the -s test
// is false, so no paired_clients are appended and the incoming config is
// written as-is.

import (
	"tool/cli"
	"tool/exec"
)

// cue cmd merge
command: merge: {
	doMerge: exec.Run & {
		cmd: ["sh", "-c", """
			set -eu

			incoming=/etc/wolf-init/cfg/config.toml
			existing=/etc/wolf/cfg/config.toml
			output=/etc/wolf/cfg/config.toml.tmp

			# Start from the authoritative incoming config (ConfigMap).
			cp "$incoming" "$output"

			# Append any paired_clients blocks preserved on the PVC.
			# The -s test guards against the empty-file first-start case.
			if [ -s "$existing" ]; then
				awk '
					/^\\[\\[paired_clients\\]\\]/ { in_pc=1 }
					/^\\[\\[/ && !/^\\[\\[paired_clients\\]\\]/ { in_pc=0 }
					in_pc { print }
				' "$existing" >> "$output"
			fi

			# Atomic replace — avoids Wolf reading a partially-written file.
			mv "$output" "$existing"
			"""]
	}

	confirm: cli.Print & {
		text:   "config-init: merge complete"
		$after: doMerge
	}
}
