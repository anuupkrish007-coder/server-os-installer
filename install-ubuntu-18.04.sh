#!/bin/bash

echo "=========================================="
echo " Ubuntu 18.04 Rescue Installer"
echo " Detection Mode"
echo "=========================================="
echo

echo "=== Disks ==="
lsblk -d -o NAME,SIZE,TYPE,MODEL,SERIAL

echo
echo "=== Network Interfaces ==="
ip -br link

echo
echo "=== IPv4 Addresses ==="
ip -4 -br addr

echo
echo "=== Routing ==="
ip route

echo
echo "=========================================="
echo " Detection complete - NO changes made."
echo "=========================================="
