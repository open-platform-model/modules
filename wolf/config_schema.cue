// config_schema.cue defines the CUE schema for Wolf's config.toml structure.
//
// #WolfTomlConfig is the top-level schema used by components.cue to validate
// the value passed to encoding/toml.Marshal(). It does NOT include paired_clients —
// that section is managed by Wolf at runtime as clients connect and pair.
package wolf

// #EncoderEntry represents one entry in the av1_encoders, h264_encoders, or
// hevc_encoders arrays under [gstreamer.video]. Wolf probes check_elements at
// startup to determine which encoders are available on the host GPU.
#EncoderEntry: {
	// GStreamer plugin elements to probe for availability (e.g. ["nvh264enc", "cudaupload"])
	check_elements: [...string]

	// GStreamer pipeline fragment used to encode the video stream
	encoder_pipeline: string

	// Short name for the GStreamer plugin providing this encoder (e.g. "nvcodec", "va", "qsv")
	plugin_name: string

	// Optional video pre-processing pipeline fragment (used when encoder lacks built-in scaling)
	video_params?: string

	// Optional zero-copy video pre-processing pipeline fragment (GPU memory path)
	video_params_zero_copy?: string
}

// #VideoDefaults holds GPU-backend-specific video pre-processing pipeline
// fragments for one backend (nvcodec, qsv, or va). These are used as defaults
// when an individual encoder entry does not define its own video_params.
#VideoDefaults: {
	// Video pre-processing pipeline fragment for this backend
	video_params: string

	// Zero-copy video pre-processing pipeline fragment (GPU memory path)
	video_params_zero_copy: string
}

// #GstreamerVideoDefaults groups per-backend video defaults under
// [gstreamer.video.defaults]. Each backend is optional — Wolf only applies
// the defaults for backends present on the host.
#GstreamerVideoDefaults: {
	// NVIDIA CUDA-based encoder backend defaults
	nvcodec?: #VideoDefaults

	// Intel Quick Sync Video encoder backend defaults
	qsv?: #VideoDefaults

	// VA-API (Intel/AMD) encoder backend defaults
	va?: #VideoDefaults
}

// #GstreamerAudioConfig maps [gstreamer.audio] in config.toml.
// These GStreamer pipeline fragments control how Wolf captures, converts,
// encodes, and transmits audio to Moonlight clients.
#GstreamerAudioConfig: {
	// Audio pre-processing pipeline inserted before the Opus encoder
	default_audio_params: string

	// Opus encoder pipeline fragment with bitrate and frame-size interpolation placeholders
	default_opus_encoder: string

	// RTP packetizer and appsink pipeline that delivers encoded audio over UDP
	default_sink: string

	// interpipesrc pipeline fragment that reads from the per-session audio source
	default_source: string
}

// #GstreamerVideoConfig maps [gstreamer.video] in config.toml.
// Defines the video pipeline structure and all available hardware encoder options.
// Wolf probes each encoder's check_elements at startup and selects the first
// working encoder per codec.
#GstreamerVideoConfig: {
	// RTP packetizer and appsink pipeline that delivers encoded video over UDP
	default_sink: string

	// interpipesrc pipeline fragment that reads from the per-session video source
	default_source: string

	// Per-backend video pre-processing defaults (optional — Wolf has built-in fallbacks)
	defaults?: #GstreamerVideoDefaults

	// AV1 encoder candidates in priority order
	av1_encoders: [...#EncoderEntry]

	// H.264 encoder candidates in priority order
	h264_encoders: [...#EncoderEntry]

	// HEVC (H.265) encoder candidates in priority order
	hevc_encoders: [...#EncoderEntry]
}

// #GstreamerConfig maps the [gstreamer] section in config.toml.
#GstreamerConfig: {
	// Audio pipeline configuration
	audio: #GstreamerAudioConfig

	// Video pipeline configuration including encoder lists
	video: #GstreamerVideoConfig
}

// #AudioSourceOverride overrides the GStreamer audio source for a specific app.
// Used to provide a synthetic or app-specific audio source (e.g. audiotestsrc).
#AudioSourceOverride: {
	// GStreamer source pipeline fragment (replaces the default interpipesrc)
	source: string
}

// #VideoSourceOverride overrides the GStreamer video source for a specific app.
// Used to provide a synthetic or app-specific video source (e.g. videotestsrc).
#VideoSourceOverride: {
	// GStreamer source pipeline fragment (replaces the default interpipesrc)
	source: string
}

// #DockerRunner configures a Docker container-based app. Wolf asks the DinD
// daemon to create and start the container when a Moonlight client launches the app.
#DockerRunner: {
	// Discriminator — must be "docker" to distinguish from #ProcessRunner
	type: "docker"

	// Docker image reference (e.g. "ghcr.io/games-on-whales/firefox:edge")
	image: string

	// Container name assigned by Wolf (must be unique per Wolf instance)
	name: string

	// Environment variables injected into the container (format: "KEY=VALUE")
	env: [...string]

	// Host device paths to pass into the container (e.g. "/dev/dri/renderD128")
	devices: [...string]

	// Bind mount specs in Docker format (e.g. "/host/path:/container/path")
	mounts: [...string]

	// Port mappings in Docker format (e.g. "8080:80/tcp")
	ports: [...string]

	// Optional JSON string merged into the Docker container create request.
	// Used to set HostConfig fields like CapAdd, DeviceCgroupRules, IpcMode, etc.
	base_create_json?: string
}

// #ProcessRunner configures a host process-based app. Wolf spawns the command
// directly on the host (inside the Wolf container) rather than via Docker.
#ProcessRunner: {
	// Discriminator — must be "process" to distinguish from #DockerRunner
	type: "process"

	// Shell command to execute when the app is launched
	run_cmd: string
}

// #AppConfig represents one [[profiles.apps]] entry. Each app is a streamable
// application that Moonlight clients can launch from the session app grid.
#AppConfig: {
	// Display name shown in the Moonlight app grid
	title: string

	// URL or path to a PNG icon shown in the Moonlight app grid
	icon_png_path?: string

	// Start a Wayland virtual compositor session for this app
	start_virtual_compositor?: bool

	// Start the PulseAudio server for this app (set false to use a synthetic audio source)
	start_audio_server?: bool

	// App runner — either a Docker container or a host process
	runner: #DockerRunner | #ProcessRunner

	// Optional per-app GStreamer audio source override (replaces the default interpipesrc)
	audio?: #AudioSourceOverride

	// Optional per-app GStreamer video source override (replaces the default interpipesrc)
	video?: #VideoSourceOverride
}

// #ProfileConfig represents one [[profiles]] entry. A profile groups a set of
// apps and is associated with one or more paired Moonlight clients.
#ProfileConfig: {
	// Stable identifier for this profile (referenced by paired_clients at runtime)
	id: string

	// Human-readable display name for this profile (optional — some profiles are unnamed)
	name?: string

	// Apps available to Moonlight clients using this profile
	apps: [...#AppConfig]
}

// #WolfTomlConfig is the top-level schema for Wolf's config.toml, covering all
// fields that OPM writes at deploy time. paired_clients is intentionally omitted
// — Wolf manages that section itself as clients connect and pair via Moonlight.
//
// Note: ... (open struct) is required here so that #WolfFullConfig can extend
// this type with the runtime-managed paired_clients field via struct embedding.
// Without ..., CUE's closed-struct constraint would reject paired_clients when
// validating the merged output in the init container.
#WolfTomlConfig: {
	// Wolf config file format version (currently 6)
	config_version: int

	// Hostname advertised to Moonlight clients in the host discovery list
	hostname: string

	// Stable UUID for this Wolf instance — required for consistent Moonlight pairing.
	// Changing this UUID breaks all existing paired clients.
	uuid: string

	// GStreamer audio/video pipeline configuration (optional — Wolf uses built-in defaults if absent)
	gstreamer?: #GstreamerConfig

	// Streaming profiles and their associated app definitions
	profiles: [...#ProfileConfig]

	...
}

// #PairedClientSettings holds per-client input/output device settings written
// by Wolf at runtime when a Moonlight client pairs successfully.
#PairedClientSettings: {
	controllers_override: [...string]
	h_scroll_acceleration: float
	mouse_acceleration:    float
	run_gid:               int
	run_uid:               int
	v_scroll_acceleration: float
}

// #PairedClientConfig represents one [[paired_clients]] entry in config.toml.
// Wolf writes these entries when a Moonlight client pairs via the PIN flow.
// OPM never writes paired_clients — only the init container preserves them.
#PairedClientConfig: {
	app_state_folder: string
	client_cert:      string
	settings?:        #PairedClientSettings
}

// #WolfFullConfig is the complete on-disk config schema, combining the static
// fields written by OPM (#WolfTomlConfig) with the runtime-managed
// [[paired_clients]] section written by Wolf. Used by the init container to
// validate the merged output before writing it to disk.
#WolfFullConfig: {
	#WolfTomlConfig
	paired_clients?: [...#PairedClientConfig]
}
