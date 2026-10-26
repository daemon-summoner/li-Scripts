#!/usr/bin/python

# You will need to generate the certs beforehand
# openssl req -new -newkey rsa:4096 -x509 -sha256 -days 3650 -nodes -out server.crt -keyout server.key

# Initialize as a client to download a file in the directory this file was run:
# while true; do sudo wget --no-check-certificate --no-proxy --delete-after  https://192.168.1.20:4430/test.txt; done
# You might need to type in the key file password on the server once a client request is made

import BaseHTTPServer, SimpleHTTPServer
import ssl
import argparse
import os.path


parser = argparse.ArgumentParser()
parser.add_argument("-port", dest="port", type=int, default=4430, help="Port to run the server on. (Default: 4430)")
parser.add_argument("-cert", dest="cert", type=str, default="/local/labuser/certs/server.crt", help="SSL certificate file to use.")
parser.add_argument("-key", dest="key", type=str, default="/local/labuser/certs/server.key", help="SSL key file to use.")
settings = parser.parse_args()

if not os.path.isfile(settings.cert):
        print("Certificate file does not exist: ({0})".format(settings.cert))
        print("Provide the file path to the cert file using -cert")
        exit(1)
if not os.path.isfile(settings.key):
        print("Key file does not exist: ({0})".format(settings.key))
        print("Provide the file path to the key file using -key")
        exit(1)


httpd = BaseHTTPServer.HTTPServer(('0.0.0.0', settings.port), SimpleHTTPServer.SimpleHTTPRequestHandler)
httpd.socket = ssl.wrap_socket(httpd.socket, certfile=settings.cert, keyfile=settings.key, server_side=True)

print("")
print("-------- HTTPS Server Started --------")
print("Port: {0}".format(settings.port))
print("Cert: {0}".format(settings.cert))
print("Key : {0}".format(settings.key))
print("--------------------------------------")
print("")

httpd.serve_forever()
