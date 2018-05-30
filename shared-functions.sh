#! /bin/bash

function debug() {
# Helper function that prints debug messages
    echo  "DEBUG:$1"
}

function info() {
# Helper function that prints log messages
    echo  "INFO:$1"
}

function error() {
# Helper function that prints error messages
    echo "ERROR:$1"
}

function check_bin_prerequsites() {
# Helper function. Check if necessary SW installed, and exits if no prerequsites
# were found
    preq_bin=$1
    if ! which $preq_bin >/dev/null; then
        echo << EOF
This script requires that the '$1' binary has been installed and can be found
in $PATH
EOF
        exit 2
    fi
}
