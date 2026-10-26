from subprocess import call

import pip

call("sudo -H pip install --upgrade pip3", shell=True)

for dist in pip.get_installed_distributions():
    call("sudo -H pip3 install --upgrade " + dist.project_name, shell=True)
