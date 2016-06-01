#!/bin/bash

# This script builds and runs Cosmic and deploys a data center using the supplied Marvin config.
# When KVM is used, RPMs are built and installed on the hypervisor.

# As building is now done locally, packages which were installed in CS1
# now need to be installed "locally":
#
# yum -y install maven tomcat mkisofs python-paramiko jakarta-commons-daemon-jsvc jsvc ws-commons-util genisoimage gcc python MySQL-python openssh-clients wget git python-ecdsa bzip2 python-setuptools mariadb-server mariadb python-devel vim nfs-utils screen setroubleshoot openssh-askpass java-1.8.0-openjdk-devel.x86_64 rpm-build rubygems nc libffi-devel openssl-devel
# yum -y install http://mirror.karneval.cz/pub/linux/fedora/epel/epel-release-latest-7.noarch.rpm
# yum --enablerepo=epel -y install sshpass mariadb mysql-connector-python
# yum -y install nmap
#
# If agreed, this needs to be moved to the bubble-cookbook
#

# Source the helper functions
. `dirname $0`/helperlib.sh


function usage {
  printf "\nUsage: %s: -e workspace -m marvinCfg [ -s -v -t -T <mvn -T flag> ]\n\n" $(basename $0) >&2
  printf "\t-T:\tPass 'mvn -T ...' flags\n" >&2
  printf "\nFeature flags:\n" >&2
  printf "\t-D:\tEnable remote debugging on tomcat (port 1043)\n" >&2
  printf "\nSkip flags:\n" >&2
  printf "\t-s:\tSkip maven build and RPM packaging\n" >&2
  printf "\t-t:\tSkip maven build\n" >&2
  printf "\t-u:\tSkip RPM packaging\n" >&2
  printf "\t-v:\tSkip prepare infra (VM creation)\n" >&2
  printf "\t-w:\tSkip setup infra (rpm installs)\n" >&2
  printf "\t-x:\tSkip deployDC\n" >&2
  printf "\nScenario\'s (will combine/override skip flags):\n" >&2
  printf "\t-a:\tMaven build and WAR (only) deploy\n" >&2
  printf "\n" >&2
}
function maven_build {
  build_dir=$1
  compile_threads=$2
  # Compile Cosmic
  cwd=$(pwd)
  cd "${build_dir}"
  echo "Compiling Cosmic"
  date
  mvn clean install -P developer,systemvm,sonar-ci-cosmic ${compile_threads} -Dcosmic.dir=${build_dir}
  if [ $? -ne 0 ]; then
    date
    echo "Build failed, please investigate!"
    exit 1
  fi
  cd "${pwd}"
  date
}

function rpm_package {
  PACKAGING_BUILD_PATH=$1
  COSMIC_BUILD_PATH=$2
  cwd=$(pwd)
  date
  cd "$1"

  # Clean up better
  rm -rf dist/rpmbuild/RPMS/
  # CentOS7 is hardcoded for now
  ./package_cosmic.sh -d centos7 -f ${COSMIC_BUILD_PATH}
  if [ $? -ne 0 ]; then
    date
    echo "RPM build failed, please investigate!"
    exit 1
  fi
  cd "${pwd}"
}

# deploy_cloudstack_war should be sourced from ci-deploy-infra.sh, but contains executing code
# so should be moved to a "library" sh script which can be sourced
function deploy_cloudstack_war {
  csip=$1
  csuser=$2
  cspass=$3
  dbscripts_dir="$4"
  war_file="$5"

  # SSH/SCP helpers
  ssh_base="sshpass -p ${cspass} ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=quiet -t "
  scp_base="sshpass -p ${cspass} scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=quiet "

  ${ssh_base} ${csuser}@${csip} mkdir -p ~tomcat/db
  ${scp_base} ${dbscripts_dir} ${csuser}@${csip}:~tomcat/db/
  ${scp_base} ${war_file} ${csuser}@${csip}:~tomcat/webapps/client.war
  ${ssh_base} ${csuser}@${csip} service tomcat start
}
# If this Jenkins-like build_run_deploy script is aproved, move function below to library script file
function undeploy_cloudstack_war {
  csip=$1
  csuser=$2
  cspass=$3

  # SSH/SCP helpers
  ssh_base="sshpass -p ${cspass} ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=quiet -t "
  ${ssh_base} ${csuser}@${csip} service tomcat stop
  ${ssh_base} ${csuser}@${csip} rm -rf ~tomcat/db
  ${ssh_base} ${csuser}@${csip} rm -rf ~tomcat/webapps/client*
}

function enable_remote_debug_war {
  csip=$1
  csuser=$2
  cspass=$3

  # SSH/SCP helpers
  ssh_base="sshpass -p ${cspass} ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=quiet -t "
  echo "Waiting 10 seconds as a deploy may just have happened; giving time to unpack jar"
  sleep 10
  ${ssh_base} ${csuser}@${csip} service tomcat stop
  ${ssh_base} ${csuser}@${csip} 'echo '\''CATALINA_OPTS="-agentlib:jdwp=transport=dt_socket,address=1043,server=y,suspend=n"'\'' >> /etc/tomcat/tomcat.conf'
  ${ssh_base} ${csuser}@${csip} service tomcat start
}


# Options
skip=0
skip_maven_build=0
skip_rpm_package=0
skip_prepare_infra=0
skip_setup_infra=0
skip_deploy_dc=0
run_tests=0
compile_threads=
scenario_build_deploy_new_war=0
enable_remote_debugging=0
while getopts 'aDe:m:T:stuvwx' OPTION
do
  case $OPTION in
  a)    scenario_build_deploy_new_war=1
        ;;
  m)    marvinCfg="$OPTARG"
        ;;
  s)    skip=1
        ;;
  t)    skip_maven_build=1
        ;;
  u)    skip_rpm_package=1
        ;;
  v)    skip_prepare_infra=1
        ;;
  w)    skip_setup_infra=1
        ;;
  x)    skip_deploy_dc=1
        ;;
  t)    run_tests=1
        ;;
  D)    enable_remote_debugging=1
        ;;
  T)    compile_threads="-T $OPTARG"
        ;;
  esac
done

echo "Received arguments:"
echo "enable_remote_debugging (-D) = ${enable_remote_debugging}"
echo "skip               (-s) = ${skip}"
echo "skip_maven_build   (-t) = ${skip_maven_build}"
echo "skip_rpm_package   (-u) = ${skip_rpm_package}"
echo "skip_prepare_infra (-v) = ${skip_prepare_infra}"
echo "skip_setup_infra   (-w) = ${skip_setup_infra}"
echo "skip_deploy_dc     (-x) = ${skip_deploy_dc}"
echo "run_tests          = ${run_tests}"
echo "marvinCfg          (-m) = ${marvinCfg}"
echo "compile_threads    (-T) = ${compile_threads}"
echo ""
echo "scenario_build_deploy_new_war (-a) = ${scenario_build_deploy_new_war}"

# Check if a marvin dc file was specified
if [ -z ${marvinCfg} ]; then
  echo "No Marvin config specified. Quiting."
  usage
  exit 1
else
  echo "Using Marvin config '${marvinCfg}'."
fi

if [ ! -f "${marvinCfg}" ]; then
    echo "Supplied Marvin config not found!"
    exit 1
fi

echo "Started!"
date
if [ ${scenario_build_deploy_new_war} -eq 1 ]; then
  skip=0
  skip_maven_build=0
  skip_rpm_package=1
  skip_prepare_infra=1
  skip_setup_infra=1
  skip_deploy_dc=1
fi

# 00080 Parse marvin config
parse_marvin_config ${marvinCfg}

# 000090 Set workspace
WORKSPACE=/data/git/${zone}
mkdir -p "${WORKSPACE}"
echo "Using workspace '${WORKSPACE}'."

COSMIC_BUILD_PATH=$WORKSPACE/cosmic
COSMIC_CORE_PATH=$COSMIC_BUILD_PATH/cosmic-core
PACKAGING_BUILD_PATH=$WORKSPACE/packaging
CI_SCRIPTS=/data/shared/ci


# 00060 We work from here
cd ${WORKSPACE}

# 00100 Checkout the code
cosmic_sources_retrieve ${WORKSPACE}

# 00110 Config nexus for maven
config_maven

# 00200 Build, unless told to skip
if [ ${skip} -eq 0 ] && [ ${skip_maven_build} -eq 0 ]; then
  # Compile Cosmic

  maven_build "$COSMIC_BUILD_PATH" "${compile_threads}"

  if [ $? -ne 0 ]; then echo "Maven build failed!"; exit;  fi
else
  echo "Skipped maven build"
fi

# 00300 Package RPMs
if [ ${skip} -eq 0 ] && [ ${skip_rpm_package} -eq 0 ]; then
  if [[ "${hypervisor}" == "kvm" ]]; then

    rpm_package "${PACKAGING_BUILD_PATH}" "${COSMIC_BUILD_PATH}"

    if [ $? -ne 0 ]; then echo "RPM package failed!"; exit;  fi
    [ -h "${COSMIC_BUILD_PATH}/dist" ] || ln -s "${PACKAGING_BUILD_PATH}/dist" "${COSMIC_BUILD_PATH}/dist"
  else
    echo "No RPM packages needed for ${hypervisor}"
  fi
else
  echo "Skipped RPM packaging"
fi

# 00400 Prepare Infra, create VMs
if [ ${skip_prepare_infra} -eq 0 ]; then

  "${CI_SCRIPTS}/ci-prepare-infra.sh" -m "${marvinCfg}"

else
  echo "Skipped prepare infra"
fi

# 00500 Setup Infra
if [ ${skip_setup_infra} -eq 0 ]; then
  cd "${COSMIC_BUILD_PATH}"
  rm -rf "$secondarystorage/*"

  "${CI_SCRIPTS}/ci-setup-infra.sh" -m "${marvinCfg}"

else
  echo "Skipped setup infra"
fi
# 00510 Setup only war deploy
if [ ${scenario_build_deploy_new_war} -eq 1 ]; then
  cd "${COSMIC_BUILD_PATH}"
  undeploy_cloudstack_war cs1 "root" "password"
  deploy_cloudstack_war cs1 "root" "password" 'cosmic-client/target/setup/db/db/*' 'cosmic-client/target/cloud-client-ui-*.war'
fi

if [ ${enable_remote_debugging} -eq 1 ]; then
  enable_remote_debug_war cs1 "root" "password"
fi


# 00600 Deploy DC
if [ ${skip_deploy_dc} -eq 0 ]; then
  cd ${WORKSPACE}
  rm -rf "$primarystorage/*"

  "${CI_SCRIPTS}/ci-deploy-data-center.sh" -m "${marvinCfg}"

else
  echo "Skipped deployDC"
fi
echo "Finished"

date