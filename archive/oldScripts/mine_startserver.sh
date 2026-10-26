#!/bin/bash
# Starts the Minecraft server in a loop
# Loop forces restart automatically on crash
while :
do
	xfce4-terminal -e 'bash /home/youruser/Minecraft/ServerStart.sh'
done