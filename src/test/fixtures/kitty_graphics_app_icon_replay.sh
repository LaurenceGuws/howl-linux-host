#!/usr/bin/env bash
set -eu

# Mirror the finalized Howl app-icon Kitty direct upload truth so host replay
# and VT proof the same stream shape.
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
image_path="${script_dir}/../../../assets/icon/howl_window_icon.png"
encoded=$(base64 -w0 "$image_path")
chunk_size=4096
encoded_len=${#encoded}
offset=0
first_chunk=1

while [ "$offset" -lt "$encoded_len" ]; do
  chunk=${encoded:$offset:$chunk_size}
  offset=$((offset + ${#chunk}))
  more=0
  if [ "$offset" -lt "$encoded_len" ]; then
    more=1
  fi

  if [ "$first_chunk" -eq 1 ]; then
    printf '\033_Gi=4242,f=100,t=d,a=T,c=8,r=4,m=%d;%s\033\\' "$more" "$chunk"
    first_chunk=0
  else
    printf '\033_Gm=%d;%s\033\\' "$more" "$chunk"
  fi
done

# Keep the child process alive briefly so the host replay proofs can observe the
# placed image before the command exits.
read -r -t 1 _ || true
