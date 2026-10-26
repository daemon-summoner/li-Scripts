#!/bin/bash

sudo sed -i "/DefaultDesktopCommand/c\DefaultDesktopCommand \"/etc/X11/Xsession 'gnome-session --session=gnome'\"" /usr/NX/etc/node.cfg

