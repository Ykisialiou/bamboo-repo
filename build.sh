#! /bin/bash

set -e
source "cf-deployment/shared-functions.sh"

function configure_build() {

    # Get vars from bamboo
    nexus_url=${nexus_url}

    info "Config variables"

    artifacts="WORKSPACE"
    if [ -d $artifacts ] ; then
	info "Remove old artifacts directory"    
        rm -r $artifacts	    
	mkdir $artifacts 
    else
        mkdir $artifacts
    fi	    
    info "Build artifacts will be stored in $artifacts"
   
    ci_repo="deployment-ci/ci"
    cf_deployment_repo="cf-deployment-upstream"

    if ! [ -d "$ci_repo/build-configs" ]; then
        mkdir "$ci_repo/build-configs"
    else
        rm -r "$ci_repo/build-configs"
        mkdir "$ci_repo/build-configs"
    fi	    

    rename_releases_var_path="$ci_repo/build-configs/releases-urls.var"
    rename_releases_ops_path="$ci_repo/ops_files/rename-releases-urls-ops.yml"
    ops_files="$ci_repo/ops_files"
    misc_file="$ci_repo/misc"
    cf_deployment_generated="$ci_repo/cf-deployment-new.yml"
    cf_deployment_base="$cf_deployment_repo/cf-deployment.yml"
    urls_list="$ci_repo/urls_list.yml"
} 

function update_ops_files() {
# Function will copy cf-deployment managed ops_files from cf-deployment repo to ci repo
#   inputs: ci_repo, cf_deployment_repo

    info "Check if some of necessary ops_files
                are updated in new cf-deployment repo"

    for ops in $(ls -1 $ci_repo/ops_files); do
        new_ops=$(find $cf_deployment_repo/operations/ -name $ops)
        if ! [ -z $new_ops ]; then
            debug "New version of ops-file $ops found.
	    Copy $new_ops to $ci_repo/ops_files"

            cp $new_ops $ci_repo/ops_files/

	    # Temporary fix, while PR to ofitial repo still not
            # accepted	    
	    if [[ "$ops" == "rename-network.yml" ]]; then
                cat $ci_repo/ops_files/$ops | \
		sed s/name=singleton-blobstore/name=singleton-blobstore\?/ > tmp
	        mv tmp $ci_repo/ops_files/$ops 	
            fi
        
        fi	
    done
}

function generate_deployment_manifest() {
# Function will generate manifest, using cf-deployment.yml from cf-deployment 
# repo, provided var_files, ops_files and env_specific config options. It still
# have default releases URL for future processing
#   inputs:  cf_deployment_repo

    info "Generate cf-deployment manifest. 
    Generated manifest will be in $cf_deployment_generated"

    update_ops_files 
    bosh int $cf_deployment_base \
    -o $ops_files/change-cell-count-opsfile.yml  \
    -o $ops_files/change-smoke-tests-logs-opsfile.yml \
    -o $ops_files/use-ldap-provider.yml  \
    -o $ops_files/disable-router-tls-termination.yml \
    -o $ops_files/keep-static-ips-opsfile.yml  \
    -o $ops_files/keep-router-ips-opsfile.yml  \
    -o $ops_files/change-active-key-label-opsfile.yml \
    -o $ops_files/use-minio-blobstore.yml \
    -o $ops_files/remove-vm-extensions-opsfile.yml \
    -o $ops_files/rename-vm-type-opsfile.yml \
    -o $ops_files/remove-z3-opsfile.yml \
    -o $ops_files/use-trusted-ca-cert-for-apps.yml  \
    -o $ops_files/override-app-domains.yml \
    -o $ops_files/rename-network.yml \
    -o $ops_files/rename-deployment.yml \
    -o $ops_files/customize-persistance-disk-opsfile.yml \
    -o $ops_files/use-external-dbs.yml  \
    -o $ops_files/override-loggregator-ports.yml \
    -o $ops_files/enable-component-syslog.yml \
    -o $ops_files/add-bosh-dns.yml \
    -o $ops_files/isolation-segment.yml \
    -o $ops_files/use-trusted-ca-cert-for-isolation-apps.yml \
    -o $ops_files/bosh-dns-isolated-segment-config.yml \
    > $cf_deployment_generated 

}

function count_releases() {
# Helper funtion. Counts releases and calculates max index for future use
   
    deployment_manifest=$1
    releases_num=$(bosh int $deployment_manifest --path /releases |\
	    grep -e "^- name:" | wc -l)
    info "There are $releases_num releases in manifest"
    releases_max_index=$(($releases_num-1))
}

function transform_tarball_name() {
# Helper function. Transform release name to more convinient format
#   inputs: release URL
#   ouputs: release name 

    url=$1
     
    tarball_name=$(echo $url | awk -F'/' '{print $NF}' | 
	sed -E 's/\?v=(.*)/-\1.tgz/')
    debug "Tarball name converted. New name is $tarball_name"
}

function generate_release_ops() {
# Function will update releases ops file that will be used with bosh int
#    inputs: release_name, rename_releases_ops_path

  release_name=$1

  debug "Generatng  $rename_releases_ops_path for $1"

    echo "     
- type: replace          
  path: /releases?/name=$1/url
  value: (($1))" >> $rename_releases_ops_path
}

function generate_release_var() {
# Function update var file with release URL from nexus
#    inputs: releases_urls_var_path, release_name, tarball_name
    
    release_name=$1
    tarball_name=$2
    if [ -z $nexus_url ]; then
        error "Nexus URL not provided, but is's necessary"
	exit 35
    fi

    debug "Generatng $rename_releases_var_path for $1"
    
    echo "$1: $nexus_url/$2" >> $rename_releases_var_path 
}

function prepare_releases_files() {
# Function will found url in manifest and download tarball to tmp directory,
# tarball name will be changed to more convinient

    count_releases $cf_deployment_generated

    if [ -f $rename_releases_ops_path ] ; then
        rm $rename_releases_ops_path
    fi
    if [ -f $rename_releases_var_path ] ; then
        rm $rename_releases_var_path 
    fi
    if [ -f $urls_list ] ; then
	rm $urls_list    
    fi 

    for index in $(seq 0 $releases_max_index); do
        url=$(bosh int $deployment_manifest --path /releases/$index/url)
	name=$(bosh int $deployment_manifest --path /releases/$index/name)
        transform_tarball_name $url
        generate_release_ops $name
	generate_release_var $name $tarball_name
	echo "$tarball_name $url" >> $urls_list
    done    
}

function prepare_artifacts() {

   info "Copiing build artifacts to separate folder"	
   cp -r $ops_files $artifacts
   cp -r $misc_file $artifacts
   cp -r $ci_repo/build-configs $artifacts  
   cp $cf_deployment_base $artifacts/ 
   cp $urls_list $artifacts/   
}

function main () {
# Main function, where all other functions called	
    configure_build
    update_ops_files
    check_bin_prerequsites bosh
    generate_deployment_manifest
    prepare_releases_files
    prepare_artifacts
}

main
