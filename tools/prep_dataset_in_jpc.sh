#!/bin/bash
# vi: expandtab sw=2 ts=2
#
# "Prepare a dataset, by deploying to JPC"
#
# This is called for "appliance" image/dataset builds to: (a) provision
# a new zone of a given image, (b) drop in an fs tarball and
# optionally some other tarballs, and (c) make an image out of this.
#

export PS4='${BASH_SOURCE}:${LINENO}: ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
if [[ -z "$(echo "$*" | grep -- '-h' || /bin/true)" ]]; then
  # Try to avoid xtrace goop when print help/usage output.
  set -o xtrace
fi
set -o errexit



#---- globals, config

CREATED_MACHINE_UUID=
CREATED_MACHINE_IMAGE_UUID=
TOP=$(cd $(dirname $0)/../ >/dev/null; pwd)
JSON=${TOP}/tools/json
export PATH="${TOP}/node_modules/manta/bin:${TOP}/node_modules/smartdc/bin:${PATH}"
image_package="g3-standard-2-smartos"

if [[ -z ${SDC_ACCOUNT} ]]; then
  export SDC_ACCOUNT="Joyent_Dev"
fi
if [[ -z ${SDC_URL} ]]; then
  # Manta locality, use east
  export SDC_URL="https://us-east-1.api.joyentcloud.com"
fi

if [[ -z ${SDC_KEY_ID} ]]; then
  export SDC_KEY_ID="$(ssh-keygen -l -f ~/.ssh/id_rsa.pub | awk '{print $2}' | tr -d '\n')"
fi

if [[ -z ${MANTA_USER} ]]; then
  export MANTA_USER=${SDC_ACCOUNT}
fi
if [[ -z ${MANTA_URL} ]]; then
  export MANTA_URL=https://us-east.manta.joyent.com
fi

if [[ -z ${MANTA_KEY_ID} ]]; then
  export MANTA_KEY_ID="${SDC_KEY_ID}"
fi

# UUID of the created image/dataset.
uuid=""

image_uuid=""
tarballs=""
packages=""
output=""


#---- functions

function fatal {
  echo "$(basename $0): error: $1"

  cleanup 1
}

function cleanup() {
  local exit_status=${1:-$?}
  if [[ -n ${CREATED_MACHINE_UUID} ]]; then
    sdc-deletemachine ${CREATED_MACHINE_UUID}
  fi
  if [[ -n ${CREATED_MACHINE_IMAGE_UUID} ]]; then
    sdc-deleteimage ${CREATED_MACHINE_IMAGE_UUID}
  fi
  exit ${exit_status}
}

function usage() {
  if [[ -n "$1" ]]; then
    echo "error: $1"
    echo ""
  fi
  echo "Usage:"
  echo "  prep_dataset.sh [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  -h              Print this help and exit."
  echo "  -i IMAGE_UUID   The base image UUID."
  echo "  -t TARBALL      Space-separated list of tarballs to unarchive into"
  echo "                  the new image. A tarball is of the form:"
  echo "                    TARBALL-ABSOLUTE-PATH-PATTERN[:SYSROOT]"
  echo "                  The default 'SYSROOT' is '/'. A '/' sysroot is the"
  echo "                  typical fs tarball layout with '/root' and '/site'"
  echo "                  base dirs. This can be called multiple times for"
  echo "                  more tarballs."
  echo "  -p PACKAGES     Space-separated list of pkgsrc package to install."
  echo "                  This can be called multiple times."

  echo "  -P PACKAGE      Package (instance / limit) name to use (eg sdc_256)"
  echo "  -o OUTPUT       Image output path. Should be of the form:"
  echo "                  '/path/to/name.manta'."
  echo "  -v VERSION      Version for produced image manifest."
  echo "  -n NAME         NAME for the produced image manifest."
  echo "  -d DESCRIPTION  DESCRIPTION for the produced image manifest."
  echo ""
  exit 1
}


#---- mainline

trap cleanup ERR

while getopts ht:p:P:i:o:n:v:d: opt; do
  case ${opt} in
  h)
    usage
    ;;
  t)
    if [[ -n ${OPTARG} ]]; then
      tarballs="${tarballs} ${OPTARG}"
    fi
    ;;
  p)
    if [[ -n ${OPTARG} ]]; then
      packages="${packages} ${OPTARG}"
    fi
    ;;
  P)
    if [[ -n ${OPTARG} ]]; then
      image_package="${OPTARG}"
    fi
    ;;
  i)
    if [[ -n ${OPTARG} ]]; then
        image_uuid=${OPTARG}
    fi
    ;;
  o)
    if [[ -n ${OPTARG} ]]; then
        output="${OPTARG}"
    fi
    ;;
  n)
    if [[ -n ${OPTARG} ]]; then
        image_name=${OPTARG}
    fi
    ;;
  v)
    if [[ -n ${OPTARG} ]]; then
        image_version=${OPTARG}
    fi
    ;;
  d)
    if [[ -n ${OPTARG} ]]; then
        image_description="${OPTARG}"
    fi
    ;;
  \?)
    echo "Invalid flag"
    exit 1;
  esac
done

if [[ -z ${output} ]]; then
  fatal "No output file specified. Use '-o' option."
fi

[[ -n ${image_name} ]] || fatal "No image name, use '-n NAME'."
[[ -n ${image_version} ]] || fatal "No image version, use '-v VERSION'."
[[ -n ${image_description} ]] || image_description="${image_name}"

if [[ -z ${image_uuid} ]]; then
  fatal "No image_uuid provided. Use the '-i' option."
fi

# Create the machine in the specified DC
package=$(sdc-listpackages | ${JSON} -c "this.name == '${image_package}'" 0.id)
[[ -n ${package} ]] || fatal "cannot find package \"${image_package}\""

machine=$(sdc-createmachine --dataset ${image_uuid} --package ${package} --name "TEMP-${image_name}-$(date +%s)"  | json id)
[[ -n ${machine} ]] || fatal "cannot get uuid for new VM."

# Set this here so from here out fatal() can try to destroy too.
CREATED_MACHINE_UUID=${machine}

state=$(sdc-getmachine ${machine} | json 'state')
while [[ ${state} == 'provisioning' ]]; do
  sleep 1
  state=$(sdc-getmachine ${machine} | json 'state')
done

machine_json=$(sdc-getmachine ${machine})

if [[ ${state} != 'running' ]]; then
  echo "Problem with machine ${machine}"
  exit 1
fi
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$(echo "${machine_json}" | json ips.0)"

# Wait for the broken networking in east to settle (EASTONE-111)
# we'll wait up to 10 minutes then attempt to delete the VM
waited=0
while [[ ${waited} -lt 600 && -z $(${SSH} zonename) ]]; do
  sleep 5
  waited=$((${waited} + 5))
done
if [[ ${waited} -ge 600 ]]; then
  sdc-deletemachine ${machine}
  fatal "VM ${machine} still unavailable after ${waited} seconds."
fi


# "tarballs" is a list of:
#   TARBALL-ABSOLUTE-PATH-PATTERN[:SYSROOT]
# e.g.:
#   /root/joy/mountain-gorilla/bits/amon/amon-agent-*.tgz:/opt
for tb_info in ${tarballs}; do
  tb_tarball=$(echo "${tb_info}" | awk -F':' '{print $1}')
  tb_sysroot=$(echo "${tb_info}" | awk -F':' '{print $2}')
  [[ -z "${tb_sysroot}" ]] && tb_sysroot=/

  bzip=$(echo ${tb_tarball} | grep "bz2$" || true)
  if [[ -n ${bzip} ]]; then
    uncompress=bzcat
  else
    uncompress=gzcat
  fi

  echo "Copying tarball '${tb_tarball}' to zone '${uuid}'."
  if [[ ${tb_sysroot} == "/" ]]; then
    # Special case: for tb_sysroot == '/' we presume these are fs-tarball
    # style tarballs with "/root/..." and "/site/...". We strip
    # appropriately.
    cat ${tb_tarball} | ${SSH} "cd / ; ${uncompress} | gtar --strip-components 1 -xf - root"
  else
    cat ${tb_tarball} | ${SSH} "cd ${tb_sysroot} ; ${uncompress} | gtar -xf -"
  fi
done

##
# install packages
if [[ -n "${packages}" ]]; then
  echo "Installing these pkgsrc package: '${packages}'"

  ${SSH} "/opt/local/bin/pkgin -f -y update"
  ${SSH} "touch /opt/local/.dlj_license_accepted"
  ${SSH} "/opt/local/bin/pkgin -y in ${packages}"

  echo "Validating pkgsrc installation"
  for p in ${packages}
  do
    echo "Checking for ${p}"
    PKG_OK=$(${SSH} "/opt/local/bin/pkgin -y list | grep ${p} || true")
    if [[ -z "${PKG_OK}" ]]; then
      echo "error: pkgin install failed (${p})"
      exit 1
    fi
  done

fi

cat tools/clean-image.sh \
  | ${SSH} "cat > /tmp/clean-image.sh; /usr/bin/bash /tmp/clean-image.sh; shutdown -i5 -g0 -y;"

# And then turn it in to an image

sdc-stopmachine ${machine}

state=$(sdc-getmachine ${machine} | json 'state')
while [[ ${state} == 'running' ]]; do
  sleep 1
  state=$(sdc-getmachine ${machine} | json 'state')
done

image=$(sdc-createimagefrommachine --machine ${machine} --name ${image_name}-zfs --imageVersion ${image_version} --description ${image_description} --tags '{"smartdc_service": true}')
image_id=$(echo "${image}" | json -H 'id')

# Set this here so from here out fatal() can try to destroy too.
CREATED_MACHINE_IMAGE_UUID=${image_id}

for i in {100..1}; do
  sleep 5
  state=$(sdc-getimage ${image_id} | json 'state')
  if [[ ${state} != "creating" && ${state} != "unactivated" ]]; then
    break
  fi
done

sdc-deletemachine ${machine}

if [[ "$(sdc-getimage ${image_id} | json 'state')" != "active" ]]; then
  echo "Error creating image"
  exit 1
fi

mantapath=/${SDC_ACCOUNT}/stor/builds/${image_name}/$(echo ${image_version} | cut -d '-' -f1,2)/${image_name}
mmkdir -p ${mantapath}

manta_bits=/tmp/manta-exported-image.$$
sdc-exportimage --mantaPath ${mantapath} ${image_id} > ${manta_bits}

output_dir=$(dirname ${output})
image_path=$(json image_path < ${manta_bits})
manifest_path=$(json manifest_path < ${manta_bits})

image_filename=$(basename ${image_path})
image_manifest_filename=$(basename ${manifest_path})

# XXX we download back from manta now just so other scripts work and we can publish
# to updates. Obviously it makes more sense not to do this, but there is not time to
# fix everything at once.
mget -o ${output_dir}/${image_filename} ${image_path}
[[ -f ${output_dir}/${image_filename} ]] || fatal "Failed to download ${image_filename}"
mget -o ${output_dir}/${image_manifest_filename} ${manifest_path}
[[ -f ${output_dir}/${image_manifest_filename} ]] || fatal "Failed to download ${image_manifest_filename}"

# XXX we need to add a requirement on the manifest for networks but the API does
# not allow us to do that, so we have to change locally and push over the original.
cat ${output_dir}/${image_manifest_filename} \
    | json -e 'this.requirements.networks = {name: "net0", description: "admin"}' \
    > ${output_dir}/${image_manifest_filename}.new \
    && mv ${output_dir}/${image_manifest_filename}.new ${output_dir}/${image_manifest_filename} \
    && mput -f ${output_dir}/${image_manifest_filename} ${manifest_path}

sdc-deleteimage ${image_id}

cat ${manta_bits}

exit 0
