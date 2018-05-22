#! /bin/bash

set -e

################################################################################
#  Script gets bosh-releases urls from cf-deployment.yml                       #
#  inputs: cf-deployment.yml, tmp_releases_dir, upload_path                    #
#  prerequsites: bosh CLI (>v2), wget                                          #
################################################################################

# Global vars
deployment_manifest="cf-deployment.yml"
tmp_releases_path="tmp"
upload_path=""
ci_repo="/home/eugene/workspace/cloudfoundry/ci"
cf_deployment_repo="/home/eugene/workspace/cf-deployment"
var_files_path="/home/eugene/workspace/cloudfoundry/var_files"
env_name="test" #test, or stage, or prod

# Env specific vars
isolation_segment="true"
disable_bosh_dns="false"
keep_ips="true"

cell_count=
deployment_name=
cell_network_name=
network_name=

function check_bin_prerequsites() {
# Helper function. Check if necessary SW installed, and exits if no prerequsites
# were found

    preq_bins=('bosh' 'wget1')

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

    for ops in $(ls -1 $ci_repo/ops_files); do
        new_ops=$(find $cf_deployment_repo/operations/ -name $ops)
        if ! [ -z $new_ops ]; then
            echo "DEBUG: New version of ops-file $ops found. Copy $new_ops to $ci_repo/ops_files"
            echo "cp $new_ops $ci_repo/ops_files/"
        fi		
    done
}

function get_env_specific_config() {
# Function will copy env specific var_files to ci repo directory
#   inputs: var_files_path, env_name, ci_repo 

    echo "DEBUG: copy var_files from $var_files_path/$env_name/var_files \
	  to $ci_repo/var_files"
    echo "cp $var_files_path/$env_name/var_files $ci_repo/var_files"
}

function prepare_ops_files() {
# Function will generate some ops_files, that are not necessary for 
# particular env, such as isolation_segment related files
#   inputs: isolation_segment, disable_bosh_dns, keep_ips, ci_repo 

    # Generated ops files (mostly for isolation segments) will go to tmp_ops_files 
    # directory
    tmp_ops_files="tmp_ops_files"
    
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
    cp ops_files/keep-static-ips-opsfile.yml $tmp_ops_files/keep-static-ips-opsfile.yml
    
    # Isolation segment ops_files generation
    
    if ! [ -z $isolation_segment ]; then
      # clean up
      rm isolation-var.tmp
    
      while read -r data
      do
        IFS='=' read -r dname dcount dvm <<< "$data"
    
        ### This code will generate additional ops_files, which are nesessary for isolation_segment
    
        echo "isolation_segment_name: $dname" >> $tmp_ops_files/isolation-var.tmp
        echo "isolation_segment_count: $dcount" >> $tmp_ops_files/isolation-var.tmp
        echo "isolation_segment_vm: $dvm" >> $tmp_ops_files/isolation-var.tmp
    
        # Generate use-trusted-ca-cert-for-isolation-apps  
        bosh int ops_files/use-trusted-ca-cert-for-isolation-apps.yml -l $tmp_ops_files/isolation-var.tmp >> $tmp_ops_files/use-trusted-ca-cert-for-isolation-apps.yml
    
        # Generate isolation-segment
    
        bosh int ops_files/isolation-segment.yml -l $tmp_ops_files/isolation-var.tmp >> $tmp_ops_files/isolation-segment.yml
    
        # Merged opsfile for all bosh-dns isolation segment work
    
        bosh int ops_files/bosh-dns-isolated-segment-config.yml -l $tmp_ops_files/isolation-var.tmp >> $tmp_ops_files/bosh-dns-isolated-segment-config.yml
    
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
    
    prepare_ops_files

    bosh int $cf_deployment_repo/cf-deployment.yml \
    -o ops_files/change-cell-count-opsfile.yml  cell_count=$cell_count \
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
    -o ops_files/rename-network.yml -v network_name=$network_name -v cell_network_name=$cell_network_name \
    -o ops_files/rename-deployment.yml -v deployment_name=$deployment_name \
    -o ops_files/customize-persistance-disk-opsfile.yml \
    -o ops_files/use-external-dbs.yml -l var_files/ext-db.var \
    -o ops_files/override-loggregator-ports.yml \
    -o ops_files/enable-component-syslog.yml -l var_files/syslog.var -l var_files/syslog-release.var \
    -o $tmp_ops_files/add-bosh-dns.yml -l var_files/bosh-dns.var \
    -o $tmp_ops_files/isolation-segment.yml \
    -o $tmp_ops_files/use-trusted-ca-cert-for-isolation-apps.yml -l var_files/trusted_certs.var \
    -o $tmp_ops_files/bosh-dns-isolated-segment-config.yml \
    > $new_manifest

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

    releases_num=$(bosh int $deployment_manifest --path /releases |\
	    grep -e "^- name:" | wc -l)
    echo "DEBUG:There are $releases_num releases in manifest"
    releases_max_index=$(($releases_num-1))
}

function transform_tarball_name() {
# Helper function. Transform release name to more convinient format
#   inputs: release URL
#   ouputs: release name 

url=$1

tarball_name=$(echo $url | awk -F'/' '{print $NF}' | 
	sed -E 's/\?v=(.*)/-\1.tgz/')
}

function generate_releases_ops() {
# Function will generate releases ops and var file and use them with bosh int
release_name=$1
rename_releases_ops_path=$ci_repo/ops_files/rename-releases-ops.yml
if [ -f $rename_releases_ops_path ] ; then
    rm $rename_releases_ops_path
fi

echo "     
- type: replace          
  path: /releases/name=$release_name/url
  value: (($release_name)) 
" >> $rename_releases_ops_path
}

function get_releases() {
# Function will found url in manifest and download tarball to tmp directory,
# tarball name will be changed to more convinient

    count_releases
   
    for index in $(seq 0 $releases_max_index); do
        url=$(bosh int $deployment_manifest --path /releases/$index/url)
	name=$(bosh int $deployment_manifest --path /releases/$index/name)
        generate_releases_ops $name
        transform_tarball_name $url
	echo "DEBUG: Downloading release $url to $tmp_releases_path/$tarball_name"
        #wget -q --show-progress $url -O $tmp_releases_path/$tarball_name
    done    
}

#function generate_releases_var() {
# Function will generate releases ops and var file and use them with bosh int
#}

cd $ci_repo
#function upload_releases() {
# Function uploads releases to NEXUS
#
#}
update_ops_files
get_env_specific_config
#check_bin_prerequsites
#create_tmp_dir
get_releases
