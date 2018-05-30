#! /bin/bash

set -e
source "cf-deployment/shared-functions.sh" 

function configure_build() {

    info "Configuring build"	
    urls_list="WORKSPACE/urls_list.yml"
    tmp_releases="tmp_releases"
    nexus_url=${nexus_url}
    nexus_login=${nexus_login}
    nexus_password=${nexus_password}

    if ! [ -d $tmp_releases ] ; then
        mkdir $tmp_releases	    
    fi	    
}

function download_and_upload_release () {

    info "Releases download URLs in $urls_list. They will be uploaded to nexus"	
    while IFS='' read -r line ; do
        
	url=$(echo $line | sed 's/^.* //')
	tarball_name=$(echo $line | sed 's/ .*$//')

	debug "Download $tarball_name from $url to $tmp_releases"
	echo "wget -q --show-progres $url -O $tmp_releases/$tarball_name"

        debug "Uploading release from $tarball_path to $nexus_url"
    
    	echo "curl -v -u $nexus_login:$nexus_password \
        --upload-file $tmp_releases/$tarball_name $nexus_url/$tarball_name"

    done < $urls_list	    
}

function main () {
    configure_build
    download_and_upload_release    
}

main
