#!/bin/bash
if [ $(( $(date +%W) % 2 )) -eq 1 ]; then
    /home/pi/nextcloud_restore_test.sh
fi
