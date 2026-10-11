#!/usr/bin/env bash
# Waits for the nvidia download, then starts lvkp-pipeline.sh and its watchdog, both detached.
G="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; mkdir -p $G/logs/lvkp
until grep -q '^DONE' $G/logs/download-nvidia-nvfp4.log; do sleep 20; done
setsid nohup $G/lvkp-pipeline.sh > $G/logs/lvkp/pipeline.log 2>&1 < /dev/null & P=$!
sleep 2; setsid nohup $G/lvkp-watchdog.sh $P > $G/logs/lvkp/watchdog.log 2>&1 < /dev/null &
echo "started pipeline pid $P at $(date -Is)"
