#!/bin/bash
sudo echo "deb http://repo.mongodb.org/apt/ubuntu xenial/mongodb-org/3.4 multiverse" > /etc/apt/sources.list.d/mongodb-org-3.4.list
sudo echo "deb http://repo.pritunl.com/stable/apt xenial main" > /etc/apt/sources.list.d/pritunl.list
sudo apt-key adv --keyserver hkp://keyserver.ubuntu.com --recv 0C49F3730359A14518585931BC711F9BA15703C6
sudo apt-key adv --keyserver hkp://keyserver.ubuntu.com --recv 7568D9BB55FF9E5287D586017AE645C0CF8E292A
sudo apt-get --assume-yes update
sudo apt-get --assume-yes upgrade
sudo apt-get --assume-yes install pritunl mongodb-org
sudo systemctl start pritunl mongod
sudo systemctl enable pritunl mongod

sudo ufw allow 80
sudo ufw allow 443
sudo ufw --force enable

IP="$(hostname --ip-address)"

echo ""
echo "Connect to: https://$IP/"
echo ""

