#!/bin/sh
# Health check script for Keepalived to monitor HAProxy
curl -s -f http://127.0.0.1:8404/stats > /dev/null 2>&1 || exit 1
