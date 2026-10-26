#!/bin/bash
# Autoupdate script (For running every 30 minutes)
# --safe parameter waits for the server to save first
sudo -u steam -H sh -c "arkmanager update --safe"
