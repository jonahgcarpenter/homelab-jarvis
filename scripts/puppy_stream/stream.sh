#!/bin/bash

if [ -z "$RTSP_URL" ] || [ -z "$RTMP_URL" ]; then
    echo "ERROR: RTSP_URL or RTMP_URL is not set!"
    exit 1
fi

echo "Starting stream at $(date)..."
ffmpeg \
  -hide_banner \
  -loglevel error \
  -rtsp_transport tcp \
  -hwaccel cuvid \
  -hwaccel_output_format cuda \
  -c:v h264_cuvid \
  -i "$RTSP_URL" \
  -an \
  -c:v h264_nvenc \
  -preset p5 \
  -tune ll \
  -bf 0 \
  -g 60 \
  -keyint_min 60 \
  -b:v 4M \
  -maxrate 4M \
  -bufsize 8M \
  -f flv "$RTMP_URL"
