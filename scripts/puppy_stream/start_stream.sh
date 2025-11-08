#!/bin/bash

SCRIPT_DIR="/home/carpenters/puppy_stream"
LOG_FILE="$SCRIPT_DIR/stream_log.log"

source "$SCRIPT_DIR/.env"

if [ -z "$RTSP_URL" ] || [ -z "$RTMP_URL" ]; then
    echo "ERROR: RTSP_URL or RTMP_URL is not set. Check .env file." >> $LOG_FILE
    exit 1
fi

touch $LOG_FILE
chmod 644 $LOG_FILE

echo "------------------------------------------------------" >> $LOG_FILE
echo "Stream script started at $(date)" >> $LOG_FILE
echo "------------------------------------------------------" >> $LOG_FILE

while true
do
    echo "Starting ffmpeg at $(date)..." >> $LOG_FILE

    ffmpeg \
        -hide_banner \
        -loglevel debug \
        -report \
        -loglevel error \
        -rtsp_transport tcp \
        -hwaccel cuvid \
        -hwaccel_output_format cuda \
        -c:v h264_cuvid \
        -i "$RTSP_URL" \
        -c:a copy \
        -c:v h264_nvenc -preset p5 -b:v 4M \
        -f flv "$RTMP_URL" >> $LOG_FILE 2>&1

    echo "FFmpeg exited with code $?. Reconnecting in 5 seconds... $(date)" >> $LOG_FILE
    sleep 5
done
