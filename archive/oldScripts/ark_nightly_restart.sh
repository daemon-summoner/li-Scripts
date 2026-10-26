#!/bin/bash
# Does a backup, OS update, update on arkmanager, update on
# ARK, then stops the server and restarts the machine.
sudo -u steam -H sh -c "arkmanager backup"
sudo apt-get -y update && sudo apt-get -y upgrade
sudo -u steam -H sh -c "arkmanager upgrade"
sudo -u steam -H sh -c "arkmanager update --safe"
sudo -u steam -H sh -c "arkmanager stop"
sudo reboot
