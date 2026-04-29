/* eslint-disable */
// =============================================================================
// Tdarr_Plugin_homelab_skip_hardlinked
// -----------------------------------------------------------------------------
// Skip any file that still has more than one hardlink (st_nlink > 1).
//
// Why this is the keystone safety wire for the homelab:
//   - /opt/torrents and /opt/media live on the same btrfs filesystem.
//   - Sonarr/Radarr import via hardlink: one inode, two paths.
//   - qBittorrent keeps seeding from /opt/torrents until the per-category
//     ratio (2.0) or seed-time (14 days) is met, then removes the torrent
//     and its file. Removal drops the link count from 2 → 1.
//   - If Tdarr re-encodes /opt/media/<file> while qBit still seeds it, the
//     transcode writes a NEW inode at /opt/media; the seeded copy at
//     /opt/torrents keeps the original alive, leaving us with two files
//     instead of saving space.
//
// This plugin makes Tdarr wait for qBit's cleanup naturally — by skipping
// every file whose nlink is still > 1. No event bus, no API calls, no n8n.
// The hardlink count is the signal.
// =============================================================================

const details = () => ({
  id: 'Tdarr_Plugin_homelab_skip_hardlinked',
  Stage: 'Pre-processing',
  Name: 'Homelab — Skip hardlinked files (still seeding)',
  Type: 'Video',
  Operation: 'Filter',
  Description:
    'Skip files where st_nlink > 1. These are still hardlinked into ' +
    '/opt/torrents and being seeded by qBittorrent. Re-encoding now would ' +
    'create a second inode and double disk usage until qBit drops the seed.',
  Version: '1.0.0',
  Tags: 'pre-processing,filter,homelab',
  Inputs: [],
});

// eslint-disable-next-line no-unused-vars
const plugin = (file, librarySettings, inputs, otherArguments) => {
  const lib = require('../methods/lib')();
  // eslint-disable-next-line no-unused-vars,no-param-reassign
  inputs = lib.loadDefaultValues(inputs, details);

  const response = {
    processFile: false,
    preset: '',
    container: `.${file.container}`,
    handBrakeMode: false,
    FFmpegMode: false,
    reQueueAfter: false,
    infoLog: '',
  };

  // Tdarr's `file` object exposes `file.file` (full path). Use Node's fs.statSync
  // to read st_nlink. Tdarr nodes have Node.js available.
  let nlink = 0;
  try {
    // eslint-disable-next-line global-require
    const fs = require('fs');
    nlink = fs.statSync(file.file).nlink;
  } catch (err) {
    response.infoLog += `☒ statSync failed for ${file.file}: ${err.message}. ` +
      'Refusing to process to avoid replacing a file we cannot inspect.\n';
    return response;
  }

  if (nlink > 1) {
    response.infoLog +=
      `☒ File has ${nlink} hardlinks — still seeding from /opt/torrents. ` +
      'Skipping until qBittorrent removes the torrent (ratio 2.0 or 14d).\n';
    return response;
  }

  response.processFile = true;
  response.infoLog += `☑ nlink=${nlink} — safe to process.\n`;
  return response;
};

module.exports.details = details;
module.exports.plugin = plugin;
