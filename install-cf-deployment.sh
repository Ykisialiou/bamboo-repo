#! /bin/bash

set -e


function get_vars_from_bamboo() {

    env_name=${env_name}
    ci_repo="deployment-ci/ci"
    cf_deployment_repo="cf-deployment"

    # Configuration URLs

    vars_file_url=${vars_file_url}
    config_file_url=${config_file_url}

    if [ -z $env_name ]; then
        error "env_name doesn't set up. Please configure it"	    
    else
        info "$env_name will be used."
    fi
} 

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

    preq_bins=('bosh' 'wget')

    for preq_bin in ${preq_bins[@]}; do
        if ! which $preq_bin >/dev/null; then
            echo << EOF
This script requires that the '$1' binary has been installed and can be found 
in $PATH
EOF
            exit 2
        fi
    done
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
        fi	
    done
}

function configure_build() {
# Helper function that setting up necessary variables

    # Set up build flow vars

    rename_releases_var_path="$ci_repo/var_files/releases-urls.var"
    rename_releases_ops_path="$ci_repo/ops_files/rename-releases-urls-ops.yml"
    tmp_ops_files="$ci_repo/tmp_ops_files"
    cf_deployment_generated="cf-deployment-new.yml"
    cf_deployment_base="$cf_deployment_repo/cf-deployment.yml"
    tmp_releases_path="$ci_repo/tmp_releases"

    # Download config and vars files

    if ! [ -d $ci_repo/build-config ]; then
        mkdir $ci_repo/build-config
        debug "$ci_repo/build-config created"	
    fi

    wget "$vars_file_url" -O  "$ci_repo/build-config/all-vars-file.yml"
    wget "$config_file_url" -O "$ci_repo/build-config/build-config.sh"

    # Get vars from files
    source "$ci_repo/build-config/build-config.sh"
}

function prepare_ops_files() {
# Function will generate some ops_files, that are not necessary for 
# particular env, such as isolation_segment related files
#   inputs: tmp_ops_files, isolation_segment, disable_bosh_dns, 
#           keep_ips, ci_repo 

    # Generated ops files (mostly for isolation segments) 
    # will go to tmp_ops_files directory

    if ! [ -d "$tmp_ops_files" ]; then
      mkdir $tmp_ops_files
    else
      rm -r  $tmp_ops_files
      mkdir $tmp_ops_files  
    fi

    # Empty ops files are doing nothing, so we'll initiate them
    
    > $tmp_ops_files/use-trusted-ca-cert-for-isolation-apps.yml
    > $tmp_ops_files/isolation-segment.yml
    > $tmp_ops_files/bosh-dns-isolated-segment-config.yml
    
    # Copy optional ops_files to tmp folder. They may or may not be empty
    
    cp ops_files/add-bosh-dns.yml $tmp_ops_files/add-bosh-dns.yml
    cp ops_files/keep-static-ips-opsfile.yml \
        $tmp_ops_files/keep-static-ips-opsfile.yml
    
    # Isolation segment ops_files generation
    
    if ! [ -z $isolation_segment ]; then

      info  "Isolation segment will be used, so it's ops_files 
      will be generated. misc/isolation-segment.tmpl is expected to be 
      filled properly"

      # clean up if tmp exists
      if [ -f isolation-var.tmp ]; then
          rm isolation-var.tmp
      fi
      while read -r data
      do
        IFS='=' read -r dname dcount dvm <<< "$data"
    
        # This code will generate additional ops_files, 
	# which are nesessary for isolation_segment
    
        echo "isolation_segment_name: $dname" \
	   >> $tmp_ops_files/isolation-var.tmp
        echo "isolation_segment_count: $dcount" \
	   >> $tmp_ops_files/isolation-var.tmp
        echo "isolation_segment_vm: $dvm" \
	   >> $tmp_ops_files/isolation-var.tmp
    
        # Generate use-trusted-ca-cert-for-isolation-apps  
        bosh int ops_files/use-trusted-ca-cert-for-isolation-apps.yml \
	-l $tmp_ops_files/isolation-var.tmp \
	>> $tmp_ops_files/use-trusted-ca-cert-for-isolation-apps.yml
   
        info "$tmp_ops_files/use-trusted-ca-cert-for-isolation-apps.yml 
	generated for $dname segment"

        # Generate isolation-segment
    
        bosh int ops_files/isolation-segment.yml \
	-l $tmp_ops_files/isolation-var.tmp \
	>> $tmp_ops_files/isolation-segment.yml

	debug "$tmp_ops_files/isolation-segment.yml 
	generated for $dname segment"
    
        # Merged opsfile for all bosh-dns isolation segment work
    
        bosh int ops_files/bosh-dns-isolated-segment-config.yml \
	-l $tmp_ops_files/isolation-var.tmp \
	>> $tmp_ops_files/bosh-dns-isolated-segment-config.yml

	debug "$tmp_ops_files/bosh-dns-isolated-segment-config.yml 
	generated for $dname segment"

    
      done < misc/isolation-segment.tmpl
    
    else
    
      # clean up isolated segments ops_files, if they are somehow
      # became not empty
      isolation_segment_opses=( \
        $tmp_ops_files/use-trusted-ca-cert-for-isolation-apps.yml \
        $tmp_ops_files/isolation-segment.yml \
        $tmp_ops_files/bosh-dns-isolated-segment-config.yml )
    
      for filename in "${isolation_segment_opses[@]}"; do
        if ! [ -s filename ]; then
          > $filename
        fi
      done
    fi
    # If bosh-dns is not necessary, empty bosh-dns ops files
     
    if ! [ -z $disable_bosh_dns ]; then
      info "bosh-dns feature disabled, 
      so bosh-dns related ops_files will be changed. Be carefull!" 

      bosh_dns_opses=( \
        $tmp_ops_files/bosh-dns-isolated-segment-config.yml \
        $tmp_ops_files/add-bosh-dns.yml) 
     
      for filename in "${bosh_dns_opses[@]}"; do
        if ! [ -s filename ]; then
          > $filename
        fi
      done
    fi
     
    # If not necessary to store static IP's, empty it's ops_file
    if [ -z $keep_ips ]; then
        static_ips_filename=$tmp_ops_files/keep-static-ips-opsfile.yml
        if ! [ -s $static_ips_filename ]; then
          > $static_ips_filename
        fi
    fi
      
}

function generate_deployment_manifest() {
# Function will generate manifest, using cf-deployment.yml from cf-deployment 
# repo, provided var_files, ops_files and env_specific config options. It still
# have default releases URL for future processing
#   inputs:  cf_deployment_repo

    info "Generate cf-deployment manifest. 
    Generated manifest will be in $cf_deployment_generated"

    update_ops_files 
    prepare_ops_files

    bosh int $cf_deployment_base \
    -o ops_files/change-cell-count-opsfile.yml -l var_files/general.var \
    -o ops_files/change-smoke-tests-logs-opsfile.yml \
    -o ops_files/use-ldap-provider.yml -l var_files/ldap.var \
    -o ops_files/disable-router-tls-termination.yml \
    -o $tmp_ops_files/keep-static-ips-opsfile.yml -l var_files/static-ips.var \
    -o ops_files/keep-router-ips-opsfile.yml -l var_files/static-ips.var \
    -o ops_files/change-active-key-label-opsfile.yml \
    -o ops_files/remove-vm-extensions-opsfile.yml \
    -o ops_files/rename-vm-type-opsfile.yml -l var_files/vm-types.var \
    -o ops_files/remove-z3-opsfile.yml \
    -o ops_files/use-trusted-ca-cert-for-apps.yml -l var_files/trusted_certs.var \
    -o ops_files/override-app-domains.yml -l var_files/app-domains.var \
    -o ops_files/use-minio-blobstore.yml -l var_files/minio.var \
    -o ops_files/rename-network.yml -l var_files/general.var \
    -o ops_files/rename-deployment.yml -l var_files/general.var \
    -o ops_files/customize-persistance-disk-opsfile.yml \
    -o ops_files/use-external-dbs.yml -l var_files/ext-db.var \
    -o ops_files/override-loggregator-ports.yml \
    -o ops_files/enable-component-syslog.yml -l var_files/syslog.var \
    -o $tmp_ops_files/add-bosh-dns.yml -l var_files/bosh-dns.var \
    -o $tmp_ops_files/isolation-segment.yml \
    -o $tmp_ops_files/use-trusted-ca-cert-for-isolation-apps.yml -l var_files/trusted_certs.var \
    -o $tmp_ops_files/bosh-dns-isolated-segment-config.yml \
    > $cf_deployment_generated 

}

function create_tmp_dir() {
# Helper function. Creates tmp directory for downloaded tars
# If directory exists, creates one more with random suffix

    if [ ! -d $tmp_releases_path ] ; then
        mkdir $tmp_releases_path
    else
        suffix=$(tr -dc 'a-z0-9' < /dev/urandom | fold -w 7 | head -n 1)
        tmp_releases_path="$tmp_releases_path-$suffix"
        mkdir "$tmp_releases_path"
    fi
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

    debug "Generatng $rename_releases_var_path for $1"
    
    echo "$1: $nexus_url/$2" >> $rename_releases_var_path 
}

function upload_release() {
# Function will upload release tarball to provided NEXUS URL 
#   inputs: release_path, nexus_url, nexus_login, nexus_password

    tarball_path=$1

    debug "Uploading release from $tarball_path to $nexus_url"
    #curl -v -u $nexus_login:$nexus_password \
    #    --upload-file $tarball_path $nexus_url/$tarball_name
    
}

function get_releases() {
# Function will found url in manifest and download tarball to tmp directory,
# tarball name will be changed to more convinient

    count_releases $cf_deployment_generated

    if [ -f $rename_releases_ops_path ] ; then
        rm $rename_releases_ops_path
    fi
    if [ -f $rename_releases_var_path ] ; then
        rm $rename_releases_var_path 
    fi

    for index in $(seq 0 $releases_max_index); do
        url=$(bosh int $deployment_manifest --path /releases/$index/url)
	name=$(bosh int $deployment_manifest --path /releases/$index/name)
        transform_tarball_name $url
        generate_release_ops $name
	echo "Downloading release $url to $tmp_releases_path/$tarball_name"
        #wget -q --show-progress $url -O $tmp_releases_path/$tarball_name
        upload_release $tmp_releases_path/$tarball_name
	generate_release_var $name $tarball_name
    done    
}

function rename_releases_urls() {
# Function will use generated releases_url ops and var files to change releases 
# URLs in manifest.

    debug "Using generated $rename_releases_ops_path 
    and $rename_releases_var_path" 
    
    cp $cf_deployment_generated $cf_deployment_generated.tmp

    bosh int $cf_deployment_generated.tmp \
    -o $rename_releases_ops_path -l $rename_releases_var_path \
    > $cf_deployment_generated 

    rm $cf_deployment_generated.tmp
    info "Finally generated deployment manifest is in 
    $cf_deployment_generated and will be used 
    for deploing CF in the following steps"  
}

function deploy_cf(){
# Function deploys cf-deployment using generated manifest and bosh CLI

    info "Now CF will be deployed. \ 
    $env_name will be used as bosh env in deployment command"

    echo "bosh -e $env_name -d $deployment_name deploy $cf_deployment_generated"
}

#function run_errands(){
# Function will run smoke-tests errand

#}

#cd $ci_repo
#update_ops_files
get_vars_from_bamboo
configure_build
cd $ci_repo
generate_deployment_manifest
#check_bin_prerequsites
#create_tmp_dir
get_releases
rename_releases_urls
deploy_cf
