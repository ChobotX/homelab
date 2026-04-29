/* eslint-disable */
// =============================================================================
// Tdarr_Plugin_homelab_hevc_nvenc_streaming
// -----------------------------------------------------------------------------
// HEVC NVENC re-encode targeting a fixed maximum total bitrate so finished
// files stream comfortably over a metered home WAN (default cap = 12 Mbps
// video + 640 kbps audio + ~50 kbps subs ≈ 13 Mbps total).
//
// Why custom (vs Migz1FFMPEG):
//   - Migz hard-codes `-cq:v 19` (very high quality) and target = source/2,
//     which leaves the encoder free to spend up to ~maxrate. For a 30 Mbps
//     1080p Remux that produces a 21 Mbps HEVC output — too fat for a
//     20 Mbps remote link.
//   - Migz also `-c:a copy`s the audio. DTS-HD MA passthrough is ~3 Mbps
//     lossless. We want to re-encode multichannel to E-AC3 640 kbps so the
//     remote-stream bandwidth budget is predictable and direct-plays on
//     every modern Jellyfin client (Apple TV, Android TV, browsers).
//
// Encoder profile (Pascal P2000 NVENC gen 6):
//   -c:v hevc_nvenc -profile:v main10 -pix_fmt p010le
//   -cq:v <video_cq>           — quality target inside maxrate envelope
//   -b:v <target>k             — VBR target ≈ 85% of maxrate
//   -maxrate <video_maxrate>k  — hard ceiling
//   -bufsize <2*maxrate>k      — VBV buffer
//   -spatial-aq 1              — adaptive quant, gives more bits to detail
//   -rc-lookahead 32           — quality bump, costs negligible time on Pascal
//   (no -bf — Pascal can't do HEVC B-frames; setting it errors out)
//
// Audio policy:
//   - channels >= 6  → eac3 @ <audio_bitrate>k, downmix kept at 5.1
//   - channels == 2  → aac @ 192k stereo (universal compat)
//   - already in eac3/ac3/aac at <= bitrate cap → copy (don't re-encode lossy)
//
// Subtitles + chapters + attachments: -c:s copy, all preserved.
// =============================================================================

const details = () => ({
  id: 'Tdarr_Plugin_homelab_hevc_nvenc_streaming',
  Stage: 'Pre-processing',
  Name: 'Homelab — HEVC NVENC with streaming bitrate cap',
  Type: 'Video',
  Operation: 'Transcode',
  Description:
    'Re-encode video to HEVC main10 via Pascal NVENC capped at <video_maxrate> ' +
    'kbps. Multichannel audio (>= 5.1) re-encoded to E-AC3 at <audio_bitrate>k; ' +
    'stereo to AAC 192k. Already-efficient lossy audio (eac3/ac3/aac under ' +
    'cap) is copied. Subs + chapters preserved.',
  Version: '1.0.0',
  Tags: 'pre-processing,ffmpeg,nvidia,hevc,homelab',
  Inputs: [
    {
      name: 'video_maxrate_kbps',
      type: 'string',
      defaultValue: '12000',
      inputUI: { type: 'text' },
      tooltip:
        'Hard cap on video bitrate in kbps. 12000 ≈ 12 Mbps, fits a ' +
        '20 Mbps WAN with audio + buffering headroom.',
    },
    {
      name: 'video_cq',
      type: 'string',
      defaultValue: '24',
      inputUI: { type: 'text' },
      tooltip:
        'NVENC HEVC quality target (lower = better quality, larger files). ' +
        '22-24 is visually transparent for 1080p; 26-28 for aggressive size.',
    },
    {
      name: 'audio_bitrate_kbps',
      type: 'string',
      defaultValue: '640',
      inputUI: { type: 'text' },
      tooltip:
        'Bitrate for re-encoded multichannel audio (E-AC3). 640k = full DD+ ' +
        'quality, common AppleTV/AndroidTV direct-play target.',
    },
    {
      name: 'container',
      type: 'string',
      defaultValue: 'mkv',
      inputUI: { type: 'text' },
      tooltip: 'Output container. mkv supports HEVC + EAC3 + PGS subs cleanly.',
    },
    {
      name: 'skip_if_total_bitrate_under',
      type: 'string',
      defaultValue: '0',
      inputUI: { type: 'text' },
      tooltip:
        'Skip files whose total bitrate is already below this kbps. 0 = ' +
        'no skip. Note: an upstream Filter By Bitrate plugin handles this ' +
        'better; keep at 0 unless used standalone.',
    },
  ],
});

// eslint-disable-next-line no-unused-vars
const plugin = (file, librarySettings, inputs, otherArguments) => {
  const lib = require('../methods/lib')();
  // eslint-disable-next-line no-unused-vars,no-param-reassign
  inputs = lib.loadDefaultValues(inputs, details);

  const response = {
    processFile: false,
    preset: '',
    container: `.${inputs.container}`,
    handBrakeMode: false,
    FFmpegMode: true,
    reQueueAfter: false,
    infoLog: '',
  };

  const videoMaxrate = parseInt(inputs.video_maxrate_kbps, 10);
  const videoCq = parseInt(inputs.video_cq, 10);
  const audioBitrate = parseInt(inputs.audio_bitrate_kbps, 10);
  const skipUnder = parseInt(inputs.skip_if_total_bitrate_under, 10);

  if (!Number.isFinite(videoMaxrate) || videoMaxrate <= 0) {
    response.infoLog += `☒ Invalid video_maxrate_kbps: ${inputs.video_maxrate_kbps}\n`;
    return response;
  }

  const totalBitrate = parseInt(file.bit_rate || (file.ffProbeData && file.ffProbeData.format && file.ffProbeData.format.bit_rate) || 0, 10) / 1000;
  if (skipUnder > 0 && totalBitrate > 0 && totalBitrate < skipUnder) {
    response.infoLog += `☑ Total bitrate ${Math.round(totalBitrate)} kbps already below skip threshold ${skipUnder}. Skipping.\n`;
    return response;
  }

  const videoStream = (file.ffProbeData && file.ffProbeData.streams || []).find((s) => s.codec_type === 'video');
  if (!videoStream) {
    response.infoLog += '☒ No video stream found.\n';
    return response;
  }

  // Per-stream audio decision. Index audio outputs separately so -c:a:N flags
  // map onto the correct output stream (mkv writes audio in source order).
  const audioStreams = (file.ffProbeData.streams || []).filter((s) => s.codec_type === 'audio');
  const audioCopyableCodecs = new Set(['aac', 'eac3', 'ac3']);
  const audioFlags = [];
  audioStreams.forEach((s, idx) => {
    const channels = parseInt(s.channels, 10) || 2;
    const inBitrate = parseInt(s.bit_rate, 10) / 1000 || 0;
    const isMultichannel = channels >= 6;

    if (isMultichannel) {
      // Lossless / DTS-HD MA / TrueHD / FLAC: re-encode to eac3.
      // Already eac3 at or below cap: copy.
      if (s.codec_name === 'eac3' && inBitrate > 0 && inBitrate <= audioBitrate * 1.1) {
        audioFlags.push(`-c:a:${idx} copy`);
      } else {
        audioFlags.push(`-c:a:${idx} eac3 -b:a:${idx} ${audioBitrate}k -ac:a:${idx} 6`);
      }
    } else {
      // Stereo / mono. Copy if already aac/ac3/eac3 small enough; else aac 192k.
      if (audioCopyableCodecs.has(s.codec_name) && inBitrate > 0 && inBitrate <= 224) {
        audioFlags.push(`-c:a:${idx} copy`);
      } else {
        audioFlags.push(`-c:a:${idx} aac -b:a:${idx} 192k -ac:a:${idx} 2`);
      }
    }
  });
  const audioPreset = audioFlags.join(' ');

  const target = Math.round(videoMaxrate * 0.85);
  const minrate = Math.round(videoMaxrate * 0.5);
  const bufsize = videoMaxrate * 2;

  // <io> is Tdarr's placeholder for `-i <input> ... <output>`. The hwaccel
  // flags must come BEFORE -i, hence the manual layout. scale_cuda forces
  // p010le (10-bit pixel format) — Pascal HEVC encoder needs the input on
  // GPU in 10-bit before NVENC accepts profile main10.
  const preset =
    ` -hwaccel cuda -hwaccel_output_format cuda <io>` +
    ` -map 0` +
    ` -c:v hevc_nvenc -profile:v main10 -pix_fmt p010le` +
    ` -cq:v ${videoCq}` +
    ` -b:v ${target}k -minrate ${minrate}k -maxrate ${videoMaxrate}k -bufsize ${bufsize}k` +
    ` -spatial-aq 1 -rc-lookahead 32` +
    ` -vf scale_cuda=format=p010le` +
    ` ${audioPreset}` +
    ` -c:s copy` +
    ` -max_muxing_queue_size 9999`;

  response.processFile = true;
  response.preset = preset;
  response.infoLog +=
    `☑ HEVC NVENC streaming target: maxrate=${videoMaxrate}k, cq=${videoCq}, ` +
    `audio=${audioBitrate}k (${audioStreams.length} audio stream${audioStreams.length === 1 ? '' : 's'}). ` +
    `Source total bitrate=${Math.round(totalBitrate)} kbps.\n`;
  return response;
};

module.exports.details = details;
module.exports.plugin = plugin;
