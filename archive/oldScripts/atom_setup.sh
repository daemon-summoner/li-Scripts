#!/bin/bash

# Initialization
cppChoice="n"
pythonChoice="y"

# Iterate through every argument passed by user
for arg in "$@"
do
	if [[ $arg == "-cpp" ]]; then
		cppChoice="y"
	fi

	if [[ $arg == "-python" ]]; then
		pythonChoice="y"
	fi
done


if [[ $cppChoice != "y" && $cppChoice != "n" ]]; then
	echo "Would you like to install C++ packages? <Y/n>"
	cppChoice="y"
	read cppChoice
fi

if [[ $pythonChoice != "y" && $pythonChoice != "n" ]]; then
	echo "Would you like to install Python packages? <Y/n>"
	pythonChoice="y"
	read pythonChoice
fi


# Install Atom's Ubuntu package
#sudo add-apt-repository -y ppa:webupd8team/atom
sudo apt update
#sudo apt install -y atom
sudo snap install --classic atom


# Install Atom packages
apm install linter
apm install highlight-selected
apm install git-plus
apm install local-history
apm install remote-ftp

apm install minimap
apm install minimap-find-and-replace
apm install minimap-pigments
apm install minimap-cursorline
apm install minimap-highlight-selected

apm install atom-beautify


# User option check
if [[ $cppChoice == "y" || $cppChoice == "Y" || $cppChoice == "yes" || $cppChoice == "YES" || $cppChoice == "Yes" || $cppChoice == "" ]]; then
	sudo apt install -y clang

	apm install autocomplete-clang
	apm install linter-clang
	apm install switch-header-source
	apm install clang-format
fi


if [[ $pythonChoice == "y" || $pythonChoice == "Y" || $pythonChoice == "yes" || $pythonChoice == "YES" || $pythonChoice == "Yes" || $pythonChoice == "" ]]; then
	sudo apt install -y python3-pip
	sudo pip3 install --upgrade pip

	sudo pip3 install pylama pylama-pylint autopep8

	apm install python-tools
	apm install python-indent
	apm install autocomplete-python
	apm install linter-pylama

fi
