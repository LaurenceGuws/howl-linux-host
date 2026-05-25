#!/usr/bin/env bash
set -eu

# Legacy synthetic stress fixture only. This is not the canonical app-icon
# replay proof input anymore.

chunk=$(printf 'A%.0s' {1..4095})

printf '\033_Gi=7,s=1,v=1365,t=d,f=24,m=1;%s\033\\' "$chunk"

count=0
while [ "$count" -lt 350 ]; do
  printf '\033_Gm=1;%s\033\\' "$chunk"
  count=$((count + 1))
done

# Keep the child process alive briefly so host replay proofs can observe the
# rendered state before the command exits.
read -r -t 1 _ || true
