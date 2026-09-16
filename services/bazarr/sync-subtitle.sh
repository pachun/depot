#!/bin/sh
# Re-times a downloaded subtitle to its video. Blu-ray and DVD rips
# carry bitmap subtitle tracks (PGS, VobSub) whose cue times are exact
# for that cut, so when the video has one it is the reference and
# alass is free to split at every scene the two cuts differ in.
# Otherwise alass detects speech in the audio track, which is noisy
# enough that its default split penalty stays in place.
set -u

video="$1"
subtitle="$2"
require_bitmap_track="${REQUIRE_BITMAP_TRACK:-0}"

exact_reference_split_penalty=1
clear_packet_max_bytes=200
longest_plausible_cue_seconds=10

work_dir="$(mktemp -d)"
streams="$work_dir/streams.csv"
packets="$work_dir/packets.csv"
reference="$work_dir/reference.srt"
aligned="$subtitle.alass.srt"
trap 'rm -rf "$work_dir"' EXIT

dump_subtitle_streams() {
  ffprobe -v error -select_streams s \
    -show_entries stream=index,codec_name -of csv=p=0 "$video" > "$streams"
}

dump_subtitle_packets() {
  ffprobe -v error -select_streams s \
    -show_entries packet=stream_index,pts_time,size -of csv=p=0 "$video" > "$packets"
}

bitmap_track_with_most_cues() {
  awk -F, -v clear_max="$clear_packet_max_bytes" '
    FNR == NR { if ($2 == "hdmv_pgs_subtitle" || $2 == "dvd_subtitle") bitmap[$1] = 1; next }
    ($1 in bitmap) && $3 > clear_max { cues[$1]++ }
    END {
      for (track in cues) if (cues[track] > most) { most = cues[track]; chosen = track }
      if (chosen != "") print chosen
    }' "$streams" "$packets"
}

write_reference_from_track() {
  awk -F, -v track="$1" -v clear_max="$clear_packet_max_bytes" -v longest="$longest_plausible_cue_seconds" '
    function stamp(t) {
      return sprintf("%02d:%02d:%02d,%03d", int(t / 3600), int(t % 3600 / 60), int(t % 60), int((t - int(t)) * 1000 + 0.5))
    }
    function emit(from, to) {
      if (to - from > longest) to = from + longest
      printf "%d\n%s --> %s\nx\n\n", ++cue, stamp(from), stamp(to)
    }
    $1 != track { next }
    $3 > clear_max { if (showing) emit(start, $2); start = $2; showing = 1; next }
    showing { emit(start, $2); showing = 0 }
    END { if (showing) emit(start, start + longest) }
  ' "$packets" > "$reference"
}

align_to_bitmap_track() {
  dump_subtitle_streams && dump_subtitle_packets || return 1
  track="$(bitmap_track_with_most_cues)"
  [ -n "$track" ] || return 1
  write_reference_from_track "$track"
  alass --split-penalty "$exact_reference_split_penalty" "$reference" "$subtitle" "$aligned" \
    && echo "synced to bitmap subtitle track $track"
}

align_to_audio() {
  [ "$require_bitmap_track" = "0" ] || return 1
  alass "$video" "$subtitle" "$aligned" && echo "synced to audio"
}

if align_to_bitmap_track || align_to_audio; then
  mv "$aligned" "$subtitle"
else
  rm -f "$aligned"
  echo "not synced: $subtitle"
  exit 1
fi
