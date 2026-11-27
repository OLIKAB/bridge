#!/bin/sh
# Lays a quiet ambient pad under the website's full demo recording.
# The loop on the page autoplays muted, so only the recording opened by a click
# gets sound. The pad is synthesized here (no licensed track to keep track of):
# three slowly crossfading chords (D, Bm, G), low-passed with a little echo,
# faded in and out and normalized to -20 LUFS so it stays in the background.
#
# Usage: ./scripts/add-demo-audio.sh [video]   (default website/assets/demo-full.mp4)
# Run it again after re-recording the demo; an existing audio track is replaced.
set -eu

video="${1:-website/assets/demo-full.mp4}"
duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$video")
fade_out=$(echo "$duration - 3.5" | bc)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# One note: the fundamental, a slightly detuned copy for width, a soft octave.
note='sin(2*PI*F*t)+0.5*sin(2*PI*F*1.003*t)+0.15*sin(4*PI*F*t)'
chord() {
  out=""
  for f in "$@"; do
    out="$out+$(echo "$note" | sed "s/F/$f/g")"
  done
  echo "${out#+}"
}
d=$(chord 146.83 220 329.63 369.99)
bm=$(chord 123.47 185 293.66 440)
g=$(chord 98 196 293.66 369.99)
pad="0.04*( ($d)*max(0,cos(2*PI*t/24))^2 + ($bm)*max(0,sin(2*PI*t/24))^2 + ($g)*max(0,-cos(2*PI*t/24))^2 )*(0.85+0.15*sin(2*PI*t/5))"

ffmpeg -y -v error -f lavfi -i "aevalsrc='$pad|$pad':s=48000:d=$duration" \
  -af "lowpass=f=1800,aecho=0.8:0.7:400|700:0.35|0.25,afade=t=in:d=2.5,afade=t=out:st=$fade_out:d=3.5,loudnorm=I=-20:TP=-2" \
  -c:a pcm_s16le "$tmp/pad.wav"

ffmpeg -y -v error -i "$video" -i "$tmp/pad.wav" -map 0:v -map 1:a \
  -c:v copy -c:a aac -b:a 128k -ar 48000 -shortest -movflags +faststart "$tmp/out.mp4"
mv "$tmp/out.mp4" "$video"
echo "Added ambient audio to $video"
