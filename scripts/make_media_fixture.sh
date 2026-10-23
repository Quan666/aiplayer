#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="${1:-/tmp/aiplayer-media-fixture}"
mkdir -p "$fixture_dir"
cat > "$fixture_dir/subtitle.ass" <<'EOF'
[Script Info]
ScriptType: v4.00+
PlayResX: 640
PlayResY: 360
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Noto Sans SC,28,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,20,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:00:30.00,Default,,0,0,0,,{\c&H00FFFF&}字幕样式验证 · AIPlayer
EOF
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i testsrc2=size=640x360:rate=24 -f lavfi -i sine=frequency=440:sample_rate=48000 \
  -i "$fixture_dir/subtitle.ass" -t 30 -map 0:v -map 1:a -map 2:s \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -c:s ass \
  -attach "$task_root/client/assets/fonts/NotoSansSC-Regular.ttf" \
  -metadata:s:t mimetype=application/x-truetype-font "$fixture_dir/Example S01E01.mkv"
