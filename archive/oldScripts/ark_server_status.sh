#!/bin/bash
# Loops checking for server status (useful when waiting for the server to come up)
for i in `seq 1 100000`;
        do	
                sudo -u steam -H sh -c "arkmanager status"
		echo ------------------------------
		sleep 0.5
        done
