#!/bin/bash

sudo apt update
sudo apt install -y docker.io

sudo ufw allow 8080
sudo ufw allow 5050
sudo ufw allow 32768:65535/tcp
sudo ufw allow 32768:65535/udp
sudo ufw --force enable

docker run eclipse/che info --network

docker run -it -e CHE_MULTIUSER=true -e CHE_HOST=YOUR_SERVER_IP --rm -v /var/run/docker.sock:/var/run/docker.sock -v /root/EclipseChe/:/data eclipse/che start
