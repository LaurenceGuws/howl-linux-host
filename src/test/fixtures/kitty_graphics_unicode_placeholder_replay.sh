#!/usr/bin/env bash
set -eu

# Emit a graphics-only Kitty Unicode-placeholder workload, then move the
# placeholder by rewriting ordinary text so the host can prove replay/present
# without any ordinary placement metadata.
payload=$(printf '\377\000\000\377\377\000\000\377' | base64 -w0)

printf '\033_Gq=2,i=7,p=9,U=1,C=1,s=1,v=2,c=1,r=1,a=T,t=d,f=32;%s\033\\' "$payload"
printf '\033[2;5H\033[38;5;7;58;5;9m\U0010EEEE\u0305\u0305\033[39;59m'
sleep 0.2

printf '\033[2;5H \033[4;10H\033[38;5;7;58;5;9m\U0010EEEE\u0305\u0305\033[39;59m'
sleep 0.2

read -r -t 1 _ || true
