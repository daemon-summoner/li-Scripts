#!/bin/bash

# NOTE: You will need to create a /root/.my.cnf with the mysql username and password first.
# FORMAT:
#
# [mysqldump]
# user=<username>
# password=<password>
#
# Now add a crontab entry for root to backup every Sunday at 5 AM 
# 0 5 * * 7 sudo bash /root/li-scripts/wp_backup.sh 
# 
# OPTIONAL: Setup vmtouch to cache wordpress file directory in RAM
# vmtouch -dlv /var/www/html/
# vmtouch -dlv /var/lib/apache2/
# vmtouch -dlv /var/lib/mysql/
# vmtouch -dlv /etc/apache2/
# 
# To backup offsite, setup RSA keypair and put this in as crontab job on backup machine
# 30 5 * * * rsync -chavzP --stats user@example.com:/home/dbuser/.wp_backup/ /home/youruser/wp_backup/



# Database credentials
user="dbuser"
#password=""
host="localhost"
db_name="wp_myblog"

# Other options
backup_path=/home/$user/.wp_backup/
date=$(date +"%d-%b-%Y")
backup_days="180"

# Create backup directory if it does not already exist
sudo mkdir -p "$backup_path/tmp/"

# Set default file permissions (not for root use)
# umask 177

# Dump database into SQL file
sudo mysqldump --host=$host $db_name > $backup_path/tmp/$db_name-$date.sql

# Copy wordpress files and apache config backups to the backup folder
sudo cp -R /var/www/html/ $backup_path/tmp/
sudo cp -R /etc/apache2/ $backup_path/tmp/

# Compress all the files into a tar
tar -zcf $backup_path/wp_backup_$date.tar.gz $backup_path/tmp/

# Cleanup all the files
sudo rm -rf $backup_path/tmp/

# Delete files older than <backup_days>
sudo find $backup_path/* -mtime +$backup_days -exec rm {} \;

# Change ownership of files to user
chown -R $user:$user $backup_path


