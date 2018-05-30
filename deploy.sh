#! /bin/bash

set -e
function configure_build() {
# Helper function that setting up necessary variables

    # Get vars from bamboo
    isolation_segment=${use_isolation_segment}
    disable_bosh_dns=${disable_bosh_dns}
    keep_ips=${keep_ips}
    vars_file_url=${vars_file_url}
    ci_repo=${ci_repo}
    artifacts=${artifacts_location}
    #isolation_segment="true"
    #vars_file_url="https://s3.amazonaws.com/ekiselev-smit-ci/test/all-vars.yml"
    # Set up build flow vars

    rename_releases_var_path="$artifacts/build-config/releases-urls.var"
    rename_releases_ops_path="$artifacts/ops_files/rename-releases-urls-ops.yml"   
    tmp_ops_files="$artifacts/tmp_ops_files"
    ops_files="$artifacts/ops_files"
    vars_file="$artifacts/build-configs/all-vars-file.yml"
    misc_file="$artifacts/misc"
    cf_deployment_generated="$artifacts/cf-deployment-new.yml"
    cf_deployment_base="$artifacts/cf-deployment.yml"

    # Source shared functions
    source $ci_repo/shared-functions.sh 

    # Download vars file
    echo $vars_file_url
    debug "Download vars_file"
    wget $vars_file_url -O $vars_file

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
    
    cp $ops_files/add-bosh-dns.yml $tmp_ops_files/add-bosh-dns.yml
    cp $ops_files/keep-static-ips-opsfile.yml \
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
        bosh int $ops_files/use-trusted-ca-cert-for-isolation-apps.yml \
	-l $tmp_ops_files/isolation-var.tmp \
	>> $tmp_ops_files/use-trusted-ca-cert-for-isolation-apps.yml
   
        info "$tmp_ops_files/use-trusted-ca-cert-for-isolation-apps.yml 
	generated for $dname segment"

        # Generate isolation-segment
    
        bosh int $ops_files/isolation-segment.yml \
	-l $tmp_ops_files/isolation-var.tmp \
	>> $tmp_ops_files/isolation-segment.yml

	debug "$tmp_ops_files/isolation-segment.yml 
	generated for $dname segment"
    
        # Merged opsfile for all bosh-dns isolation segment work
    
        bosh int $ops_files/bosh-dns-isolated-segment-config.yml \
	-l $tmp_ops_files/isolation-var.tmp \
	>> $tmp_ops_files/bosh-dns-isolated-segment-config.yml

	debug "$tmp_ops_files/bosh-dns-isolated-segment-config.yml 
	generated for $dname segment"

    
      done < $misc_file/isolation-segment.tmpl
    
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

    prepare_ops_files

    bosh int $cf_deployment_base \
    -o $ops_files/change-cell-count-opsfile.yml  \
    -o $ops_files/change-smoke-tests-logs-opsfile.yml \
    -o $ops_files/use-ldap-provider.yml  \
    -o $ops_files/disable-router-tls-termination.yml \
    -o $tmp_ops_files/keep-static-ips-opsfile.yml  \
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
    -o $tmp_ops_files/add-bosh-dns.yml \
    -o $tmp_ops_files/isolation-segment.yml \
    -o $tmp_ops_files/use-trusted-ca-cert-for-isolation-apps.yml \
    -o $tmp_ops_files/bosh-dns-isolated-segment-config.yml \
    -l $vars_file \
    > $cf_deployment_generated 

}

function deploy_cf(){
# Function deploys cf-deployment using generated manifest and bosh CLI

    info "Now CF will be deployed. \ 
    $env_name will be used as bosh env in deployment command"

    echo "bosh -e $env_name -d $deployment_name deploy $cf_deployment_generated"
}

function run_errands(){
# Function will run smoke-tests errand
    echo "bosh -e $env_name -d $deployment_name run-errand smoke-tests"
}

function main () {

    configure_build
    generate_deployment_manifest
    deploy_cf
    run_errands
}
main
