# Bundled FFmpeg

Static FFmpeg and FFprobe binaries for SwiftMaestro's Studio features (Stream Ingest, Broadcast, Stream Mixer, NDI Browser, Color Adjustments).

## Download

```bash
./scripts/download-ffmpeg.sh
```

This downloads the latest macOS Apple Silicon release from <https://ffmpeg.martin-riedl.de>, verifies its SHA256 checksum, and runs a two-stage malware scan (clamdscan quick + deep) if `clamav` is installed.

The binaries are staged in `BundledFFmpeg/` and embedded into the app bundle at build time by the `Bundle FFmpeg` post-build script in `project.yml`.

## Do not commit binaries

`BundledFFmpeg/` is git-ignored except for this file. Commit the script and `project.yml` changes, but not the downloaded binaries.
