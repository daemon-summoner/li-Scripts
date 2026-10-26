#!/bin/bash
# Installs Teamspeak. Requires some entries into MySQL as outlined.
echo "!!! NOTE: Check for Ubuntu Teamspeak .deb updates and update script. !!!"
sudo apt install mariadb-client mariadb-server libmariadb2
echo "Set password, but default for all other options."
/usr/bin/mysql_secure_installation
echo "Enter these commands: "
echo "create database teamspeak3;"
echo "GRANT ALL PRIVILEGES ON teamspeak3.* TO teamspeak3@localhost IDENTIFIED BY 'PASSWORD';"
echo "flush privileges;"
echo "quit"
sudo mysql -u root -p
sudo useradd -d /opt/teamspeak3-server -m teamspeak3-user
sudo wget http://dl.4players.de/ts/releases/3.0.13.3/teamspeak3-server_linux_amd64-3.0.13.3.tar.bz2
sudo tar -xvf teamspeak3-server_linux_amd64-3.0.13.3.tar.bz2
sudo mv teamspeak3-server_linux_amd64/* /opt/teamspeak3-server
sudo chown teamspeak3-user:teamspeak3-user /opt/teamspeak3-server -R

sudo rm -r teamspeak3-server_linux_amd64
sudo rm teamspeak3-server_linux_amd64-3.0.13.3.tar.bz2

# Setup autostart script
# NOTE: Insert this into file STARTING HERE
# #! /bin/sh
# ### BEGIN INIT INFO
# # Provides:          ts3
# # Required-Start:    $network mysql
# # Required-Stop:     $network
# # Default-Start:     2 3 4 5
# # Default-Stop:      0 1 6
# # Short-Description: TeamSpeak3 Server Daemon
# # Description:       Starts/Stops/Restarts the TeamSpeak Server Daemon
# ### END INIT INFO
#
# set -e
#
# PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
# DESC="TeamSpeak3 Server"
# NAME=teamspeak3-server
# USER=teamspeak3-user
# DIR=/opt/teamspeak3-server
# OPTIONS=inifile=ts3server.ini
# DAEMON=$DIR/ts3server_startscript.sh
# #PIDFILE=/var/run/$NAME.pid
# SCRIPTNAME=/etc/init.d/$NAME
#
# # Gracefully exit if the package has been removed.
# test -x $DAEMON || exit 0
#
# sleep 2
# sudo -u $USER $DAEMON $1 $OPTIONS
# NOTE: ENDING HERE

sudo nano /etc/init.d/ts3
sudo chmod a+x /etc/init.d/ts3
sudo chmod a+x /opt/teamspeak3-server/ts3server_startscript.sh
sudo chmod a+x /opt/teamspeak3-server/ts3server_minimal_runscript.sh
sudo update-rc.d ts3 defaults
sudo /etc/init.d/ts3 start >> TSAdminInfo.txt

# Other key location: /opt/teamspeak3-server/logs

# Setup firewall
sudo ufw allow 9987/udp
sudo ufw allow 10011/tcp
sudo ufw allow 30033/tcp
sudo ufw enable
