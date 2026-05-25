// gstreamer_presets.cue defines vendor-keyed GStreamer pipeline presets
// (#GstreamerPresetNvidia, #GstreamerPresetIntelAmd) that the Wolf module
// applies to #config.gstreamer based on #config.gpu.type. Releases that need
// custom pipelines can still set their own #config.gstreamer to override the
// preset entirely.
package wolf

// _gstreamerCommonAudio is shared verbatim by all vendor presets — Opus over
// RTP/UDP. Independent of GPU vendor.
_gstreamerCommonAudio: #GstreamerAudioConfig & {
	default_audio_params: "queue max-size-buffers=3 leaky=downstream ! audiorate ! audioconvert"
	default_opus_encoder: "opusenc bitrate={bitrate} bitrate-type=cbr frame-size={packet_duration} bandwidth=fullband audio-type=restricted-lowdelay max-payload-size=1400"
	default_sink: """
		rtpmoonlightpay_audio name=moonlight_pay packet_duration={packet_duration} encrypt={encrypt} aes_key="{aes_key}" aes_iv="{aes_iv}" !
		appsink name=wolf_udp_sink
		"""
	default_source: "interpipesrc name=interpipesrc_{}_audio listen-to={session_id}_audio is-live=true stream-sync=restart-ts max-bytes=0 max-buffers=3 block=false"
}

// _gstreamerCommonVideoSink — RTP packetizer for moonlight; vendor-agnostic.
_gstreamerCommonVideoSink: """
	rtpmoonlightpay_video name=moonlight_pay payload_size={payload_size} fec_percentage={fec_percentage} min_required_fec_packets={min_required_fec_packets} !
	appsink sync=false name=wolf_udp_sink
	"""

// _gstreamerCommonVideoSource — interpipesrc reader for moonlight session video.
_gstreamerCommonVideoSource: "interpipesrc name=interpipesrc_{}_video listen-to={session_id}_video is-live=true stream-sync=restart-ts max-bytes=0 max-buffers=1 leaky-type=downstream"

// _videoDefaultsNvcodec — NVIDIA CUDA pre-processing pipeline fragments.
_videoDefaultsNvcodec: #VideoDefaults & {
	video_params: """
		cudaupload !
		cudaconvertscale add-borders=true !
		video/x-raw(memory:CUDAMemory), width={width}, height={height}, chroma-site={color_range}, format=NV12, colorimetry={color_space}, pixel-aspect-ratio=1/1
		"""
	video_params_zero_copy: """
		cudaupload !
		cudaconvertscale add-borders=true !
		video/x-raw(memory:CUDAMemory),format=NV12, width={width}, height={height}, pixel-aspect-ratio=1/1
		"""
}

// _videoDefaultsQsv — Intel QuickSync pre-processing pipeline fragments.
_videoDefaultsQsv: #VideoDefaults & {
	video_params: """
		videoconvertscale !
		video/x-raw, chroma-site={color_range}, width={width}, height={height}, format=NV12,
		colorimetry={color_space}, pixel-aspect-ratio=1/1
		"""
	video_params_zero_copy: """
		vapostproc add-borders=true !
		video/x-raw(memory:VAMemory), format=NV12, width={width}, height={height}, pixel-aspect-ratio=1/1
		"""
}

// _videoDefaultsVa — Mesa VA-API pre-processing pipeline fragments.
// Zero-copy path: vapostproc handles DMABuf with LINEAR modifier and outputs
// VAMemory NV12 directly to the VA-API encoder.
_videoDefaultsVa: #VideoDefaults & {
	video_params: """
		vapostproc add-borders=true !
		video/x-raw, chroma-site={color_range}, width={width}, height={height}, format=NV12,
		colorimetry={color_space}, pixel-aspect-ratio=1/1
		"""
	video_params_zero_copy: """
		vapostproc add-borders=true !
		video/x-raw(memory:VAMemory), format=NV12, width={width}, height={height}, pixel-aspect-ratio=1/1
		"""
}

// === Encoder pipeline fragments ===

_encNvAv1: #EncoderEntry & {
	check_elements: ["nvav1enc", "cudaconvertscale", "cudaupload"]
	encoder_pipeline: """
		nvav1enc gop-size=-1 bitrate={bitrate} rc-mode=cbr zerolatency=true preset=p1 tune=ultra-low-latency multi-pass=two-pass-quarter !
		av1parse !
		video/x-av1, stream-format=obu-stream, alignment=frame, profile=main
		"""
	plugin_name: "nvcodec"
}

_encVaAv1: #EncoderEntry & {
	check_elements: ["vaav1enc", "vapostproc"]
	encoder_pipeline: """
		vaav1enc ref-frames=1 bitrate={bitrate} cpb-size={bitrate} key-int-max=1024 rate-control=cqp target-usage=6 !
		av1parse !
		video/x-av1, stream-format=obu-stream, alignment=frame, profile=main
		"""
	plugin_name: "va"
}

_encVaAv1Lp: #EncoderEntry & {
	check_elements: ["vaav1lpenc", "vapostproc"]
	encoder_pipeline: """
		vaav1lpenc ref-frames=1 bitrate={bitrate} cpb-size={bitrate} key-int-max=1024 rate-control=cqp target-usage=6 !
		av1parse !
		video/x-av1, stream-format=obu-stream, alignment=frame, profile=main
		"""
	plugin_name: "va"
}

_encQsvAv1: #EncoderEntry & {
	check_elements: ["qsvav1enc", "vapostproc"]
	encoder_pipeline: """
		qsvav1enc gop-size=0 ref-frames=1 bitrate={bitrate} rate-control=cbr low-latency=1 target-usage=6 !
		av1parse !
		video/x-av1, stream-format=obu-stream, alignment=frame, profile=main
		"""
	plugin_name: "qsv"
}

_encAomAv1: #EncoderEntry & {
	check_elements: ["av1enc"]
	encoder_pipeline: """
		av1enc usage-profile=realtime end-usage=vbr target-bitrate={bitrate} !
		av1parse !
		video/x-av1, stream-format=obu-stream, alignment=frame, profile=main
		"""
	plugin_name: "aom"
	video_params: """
		videoconvertscale !
		videorate !
		video/x-raw, width={width}, height={height}, framerate={fps}/1, format=I420,
		chroma-site={color_range}, colorimetry={color_space}
		"""
	video_params_zero_copy: """
		videoconvertscale !
		videorate !
		video/x-raw, width={width}, height={height}, framerate={fps}/1, format=I420,
		chroma-site={color_range}, colorimetry={color_space}
		"""
}

_encNvH264: #EncoderEntry & {
	check_elements: ["nvh264enc", "cudaconvertscale", "cudaupload"]
	encoder_pipeline: """
		nvh264enc preset=low-latency-hq zerolatency=true gop-size=0 rc-mode=cbr-ld-hq bitrate={bitrate} aud=false !
		h264parse !
		video/x-h264, profile=main, stream-format=byte-stream
		"""
	plugin_name: "nvcodec"
}

_encVaH264: #EncoderEntry & {
	check_elements: ["vah264enc", "vapostproc"]
	encoder_pipeline: """
		vah264enc aud=false b-frames=0 ref-frames=1 num-slices={slices_per_frame} bitrate={bitrate} cpb-size={bitrate} key-int-max=1024 rate-control=cqp target-usage=6 !
		h264parse !
		video/x-h264, profile=main, stream-format=byte-stream
		"""
	plugin_name: "va"
}

_encVaH264Lp: #EncoderEntry & {
	check_elements: ["vah264lpenc", "vapostproc"]
	encoder_pipeline: """
		vah264lpenc aud=false b-frames=0 ref-frames=1 num-slices={slices_per_frame} bitrate={bitrate} cpb-size={bitrate} key-int-max=1024 rate-control=cqp target-usage=6 !
		h264parse !
		video/x-h264, profile=main, stream-format=byte-stream
		"""
	plugin_name: "va"
}

_encQsvH264: #EncoderEntry & {
	check_elements: ["qsvh264enc", "vapostproc"]
	encoder_pipeline: """
		qsvh264enc b-frames=0 gop-size=0 idr-interval=1 ref-frames=1 bitrate={bitrate} rate-control=cbr target-usage=6  !
		h264parse !
		video/x-h264, profile=main, stream-format=byte-stream
		"""
	plugin_name: "qsv"
}

_encX264H264: #EncoderEntry & {
	check_elements: ["x264enc"]
	encoder_pipeline: """
		x264enc pass=qual tune=zerolatency speed-preset=superfast b-adapt=false bframes=0 ref=1
		sliced-threads=true threads={slices_per_frame} option-string="slices={slices_per_frame}:keyint=infinite:open-gop=0"
		b-adapt=false bitrate={bitrate} aud=false !
		video/x-h264, profile=high, stream-format=byte-stream
		"""
	plugin_name: "x264"
}

_encNvH265: #EncoderEntry & {
	check_elements: ["nvh265enc", "cudaconvertscale", "cudaupload"]
	encoder_pipeline: """
		nvh265enc gop-size=-1 bitrate={bitrate} aud=false rc-mode=cbr zerolatency=true preset=p1 tune=ultra-low-latency multi-pass=two-pass-quarter !
		h265parse !
		video/x-h265, profile=main, stream-format=byte-stream
		"""
	plugin_name: "nvcodec"
}

_encVaH265: #EncoderEntry & {
	check_elements: ["vah265enc", "vapostproc"]
	encoder_pipeline: """
		vah265enc aud=false b-frames=0 ref-frames=1 num-slices={slices_per_frame} bitrate={bitrate} cpb-size={bitrate} key-int-max=1024 rate-control=cqp target-usage=6 !
		h265parse !
		video/x-h265, profile=main, stream-format=byte-stream
		"""
	plugin_name: "va"
}

_encVaH265Lp: #EncoderEntry & {
	check_elements: ["vah265lpenc", "vapostproc"]
	encoder_pipeline: """
		vah265lpenc aud=false b-frames=0 ref-frames=1 num-slices={slices_per_frame} bitrate={bitrate} cpb-size={bitrate} key-int-max=1024 rate-control=cqp target-usage=6 !
		h265parse !
		video/x-h265, profile=main, stream-format=byte-stream
		"""
	plugin_name: "va"
}

_encQsvH265: #EncoderEntry & {
	check_elements: ["qsvh265enc", "vapostproc"]
	encoder_pipeline: """
		qsvh265enc b-frames=0 gop-size=0 idr-interval=1 ref-frames=1 bitrate={bitrate} rate-control=cbr low-latency=1 target-usage=6 !
		h265parse !
		video/x-h265, profile=main, stream-format=byte-stream
		"""
	plugin_name: "qsv"
}

_encX265H265: #EncoderEntry & {
	check_elements: ["x265enc"]
	encoder_pipeline: """
		x265enc tune=zerolatency speed-preset=superfast bitrate={bitrate}
		option-string="info=0:keyint=-1:qp=28:repeat-headers=1:slices={slices_per_frame}:aud=0:annexb=1:log-level=3:open-gop=0:bframes=0:intra-refresh=0" !
		video/x-h265, profile=main, stream-format=byte-stream
		"""
	plugin_name: "x265"
	video_params: """
		videoconvertscale !
		videorate !
		video/x-raw, width={width}, height={height}, framerate={fps}/1, format=I420,
		chroma-site={color_range}, colorimetry={color_space}
		"""
	video_params_zero_copy: """
		videoconvertscale !
		videorate !
		video/x-raw, width={width}, height={height}, framerate={fps}/1, format=I420,
		chroma-site={color_range}, colorimetry={color_space}
		"""
}

// #GstreamerPresetNvidia — full GStreamer config for hosts running NVIDIA GPUs.
// Encoder priority: nvcodec (NVENC) → VA-API → software fallback. The VA-API
// entries cover dual-GPU setups (NVIDIA + integrated AMD/Intel) where Wolf
// might pick the iGPU encoder if NVENC probe fails for any reason.
#GstreamerPresetNvidia: #GstreamerConfig & {
	audio: _gstreamerCommonAudio
	video: {
		default_sink:   _gstreamerCommonVideoSink
		default_source: _gstreamerCommonVideoSource
		defaults: {
			nvcodec: _videoDefaultsNvcodec
			qsv:     _videoDefaultsQsv
			va:      _videoDefaultsVa
		}
		av1_encoders: [_encNvAv1, _encVaAv1, _encVaAv1Lp, _encQsvAv1, _encAomAv1]
		h264_encoders: [_encNvH264, _encVaH264, _encVaH264Lp, _encQsvH264, _encX264H264]
		hevc_encoders: [_encNvH265, _encVaH265, _encQsvH265, _encVaH265Lp, _encX265H265]
	}
}

// #GstreamerPresetIntelAmd — full GStreamer config for hosts running AMD or
// Intel GPUs (no NVIDIA). Encoder priority: VA-API (vaapi) → QuickSync (Intel
// only) → software fallback. AV1 encode requires Mesa 25.0+ (RDNA4 needs
// Mesa 25.2+). H.264/HEVC work on all AMD GPUs from Vega onward and all
// modern Intel GPUs.
#GstreamerPresetIntelAmd: #GstreamerConfig & {
	audio: _gstreamerCommonAudio
	video: {
		default_sink:   _gstreamerCommonVideoSink
		default_source: _gstreamerCommonVideoSource
		defaults: {
			qsv: _videoDefaultsQsv
			va:  _videoDefaultsVa
		}
		av1_encoders: [_encVaAv1, _encVaAv1Lp, _encQsvAv1, _encAomAv1]
		h264_encoders: [_encVaH264, _encVaH264Lp, _encQsvH264, _encX264H264]
		hevc_encoders: [_encVaH265, _encVaH265Lp, _encQsvH265, _encX265H265]
	}
}
