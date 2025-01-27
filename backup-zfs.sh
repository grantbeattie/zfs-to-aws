#!/usr/bin/env bash

set -o nounset
set -o pipefail

readonly SCRIPT_VERSION=1.1

readonly META_SNAPSHOT="snapshot"
readonly META_FULL_SNAPSHOT="full-snapshot"
readonly META_LAST_FULL="last-full-snapshot"
readonly META_LAST_FULL_FILE="last-full-snapshot-file"
readonly META_INCREMENT_FROM="increment-from"
readonly META_INCREMENT_FROM_FILE="increment-from-file"
readonly META_SNAPSHOT_CREATION="snapshot-creation"
readonly META_BACKUP_SEQ="backup-sequence"
readonly META_SCRIPT_VERSION="backup-script-version"
readonly META_DEDUP="deduplification"
readonly META_LZ4="compression-lz4"
readonly META_COMPLETE_TAG='{"TagSet":[{"Key":"upload_state","Value":"complete"}]}'
readonly META_COMPLETE_KEY="upload_state"
readonly META_COMPLETE_VALUE="complete"

BUCKET=
AWS_REGION=
ENDPOINT_URL=
PREFIX_ENDPOINT=
RATE_LIMIT=0
BACKUP_PATH=$(hostname -f)

DEFAULT_INCREMENTAL_FROM_INCREMENTAL=0
DEFAULT_MAX_INCREMENTAL_BACKUPS=100
DEFAULT_SNAPSHOT_TYPES="zfs-auto-snap_monthly"

OPT_CONFIG_FILE='backup-zfs.conf'
OPT_DEBUG=''
OPT_PREFIX="zfs-backup"
OPT_QUIET=''
OPT_SYSLOG=''
OPT_VERBOSE=''
OPT_FORCE=0

EXIT_STATUS=0

readonly ZFS=$(which zfs)
readonly AWS=$(which aws)

function print_usage
{
    echo "Usage: $0 [options]
  -c, --config FILE  Get config from FILE
  -d, --debug        Print debugging messages
  -f, --force        Force upload ignoring version/completeness checks
  -h, --help         Print this usage message
  -q, --quiet        Suppress warnings and notices at the console
  -s, --syslog       Write messages into the system log
  -v, --verbose      Print info messages
"
}

function check_set_ENDPOINT_URL
{
    if [[ -n $1 ]]
    then
    ENDPOINT_URL=$1
    PREFIX_ENDPOINT=--endpoint-url
    fi

}
function check_set
{
    if [[ -z ${2:-} ]]
    then
        print_log critical $1
        exit 1
    fi
}

function check_dep
{
    dep=$1
    which $1 > /dev/null
    if [[ $? -gt 0 ]]
    then
        print_log critical "required dependency $1 not available"
        exit 1
    fi
}

function print_log # level, message, ...
{
    local level=$1
    shift 1

    case $level in
        (eme*)
            test -n "$OPT_SYSLOG" && logger -t "$OPT_PREFIX" -p daemon.emerge $*
            echo Emergency: $* 1>&2
            ;;
        (ale*)
            test -n "$OPT_SYSLOG" && logger -t "$OPT_PREFIX" -p daemon.alert $*
            echo Alert: $* 1>&2
            ;;
        (cri*)
            test -n "$OPT_SYSLOG" && logger -t "$OPT_PREFIX" -p daemon.crit $*
            echo Critical: $* 1>&2
            ;;
        (err*)
            test -n "$OPT_SYSLOG" && logger -t "$OPT_PREFIX" -p daemon.err $*
            echo Error: $* 1>&2
            ;;
        (war*)
            test -n "$OPT_SYSLOG" && logger -t "$OPT_PREFIX" -p daemon.warning $*
            test -z "$OPT_QUIET" && echo Warning: $* 1>&2
            ;;
        (not*)
            test -n "$OPT_SYSLOG" && logger -t "$OPT_PREFIX" -p daemon.notice $*
            test -z "$OPT_QUIET" && echo $*
            ;;
        (inf*)
            test -n "$OPT_SYSLOG" && logger -t "$OPT_PREFIX" -p daemon.info $*
            test -z ${OPT_QUIET} && test -n "$OPT_VERBOSE" && echo $*
            ;;
        (deb*)
            # test -n "$OPT_SYSLOG" && logger -t "$OPT_PREFIX" -p daemon.debug $*
            test -n "$OPT_DEBUG" && echo Debug: $*
            ;;
        (*)
            test -n "$OPT_SYSLOG" && logger -t "$OPT_PREFIX" $*
            echo $* 1>&2
            ;;
    esac
}

function load_config
{
    if [[ ! -f $OPT_CONFIG_FILE ]]
    then
        print_log critical "Missing config file $OPT_CONFIG_FILE"
        exit 1
    fi

    local in_ds=0
    local ds_name=''
    local ds_ss_types=$DEFAULT_SNAPSHOT_TYPES
    local ds_ssinc_types=''
    local ds_max_inc=$DEFAULT_MAX_INCREMENTAL_BACKUPS
    local ds_inc_inc=$DEFAULT_INCREMENTAL_FROM_INCREMENTAL

    IFS=$'\n'; for line in $( cat $OPT_CONFIG_FILE )
    do
        arg=$(echo $line | awk -F= {'print $1'})
        val=$(echo $line | awk -F= {'print $2'})

        print_log debug "config line: $line"
        print_log debug " -- has arg \"$arg\" and val \"$val\""

        if [[ $in_ds == 0  && $arg == 'bucket' ]]
        then
            BUCKET=$val
        elif [[ $in_ds == 0 && $arg == 'region' ]]
        then
            AWS_REGION=$val
        elif [[ $in_ds == 0 && $arg == 'endpoint_url' ]]
        then
            ENDPOINT_URL=$val
        elif [[ $in_ds == 0 && $arg == 'backup_path' ]]
        then
            BACKUP_PATH=$val
	elif [[ $in_ds == 0 && $arg == 'rate_limit' ]]
	then
	    RATE_LIMIT=${val:-$RATE_LIMIT}
        elif [[ $arg == '[dataset]' ]]
        then
        check_set_ENDPOINT_URL "$ENDPOINT_URL"
            # Checking bucket here as this is the opportunity when the non-dataset config has finally been loaded
            if [[ $in_ds == 0 ]]
            then
                check_aws_bucket
                check_partial_uploads
            elif [[ $in_ds == 1 && $ds_name ]]
            then
                if [[ -z $ds_ssinc_types ]]
                then
                    ds_ssinc_types=$ds_ss_types
                fi
                print_log debug "Running dataset with: \"$ds_name\" \"$ds_ss_types\" \"$ds_ssinc_types\" \"$ds_max_inc\" \"$ds_inc_inc\""
                backup_dataset "$ds_name" "$ds_ss_types" "$ds_ssinc_types" "$ds_max_inc" "$ds_inc_inc"
            fi
            in_ds=1
            ds_name=''
            ds_ss_types=$DEFAULT_SNAPSHOT_TYPES
            ds_ssinc_types=''
            ds_max_inc=$DEFAULT_MAX_INCREMENTAL_BACKUPS
            ds_inc_inc=$DEFAULT_INCREMENTAL_FROM_INCREMENTAL
        elif [[ $arg == 'name' ]]
        then
            ds_name=$val
        elif [[ $arg == 'snapshot_types' ]]
        then
            ds_ss_types=$val
        elif [[ $arg == 'snapshot_incremental_types' ]]
        then
            ds_ssinc_types=$val
        elif [[ $arg == 'max_incremental_backups' ]]
        then
            ds_max_inc=$val
        elif [[ $arg == 'incremental_incremental' ]]
        then
            ds_inc_inc=$val
        fi
    done

    print_log debug "Finished reading config file"

    if [[ $in_ds == 1 && $ds_name ]]
    then
        if [[ -z $ds_ssinc_types ]]
        then
            ds_ssinc_types=$ds_ss_types
        fi
        print_log debug "Running dataset with: \"$ds_name\" \"$ds_ss_types\" \"$ds_ssinc_types\" \"$ds_max_inc\" \"$ds_inc_inc\""
        backup_dataset "$ds_name" "$ds_ss_types" "$ds_ssinc_types" "$ds_max_inc" "$ds_inc_inc"
    fi
}

function check_aws_bucket
{
    print_log debug "Starting check that AWS bucket exists"
    check_set "AWS bucket name not set" $BUCKET
    local bucket_ls=$( $AWS $PREFIX_ENDPOINT $ENDPOINT_URL s3 ls $BUCKET 2>&1 )
    if [[ $bucket_ls =~ 'An error occurred (AccessDenied)' ]]
    then
        print_log error "Access denied attempting to access bucket $BUCKET"
        exit 1
    elif [[ $bucket_ls =~ 'An error occurred (NoSuchBucket)' ]]
    then
        print_log notice "Creating bucket $BUCKET in region $AWS_REGION"
        $AWS $PREFIX_ENDPOINT $ENDPOINT_URL s3api create-bucket --bucket $BUCKET --region $AWS_REGION --create-bucket-configuration LocationConstraint=$AWS_REGION --acl private
        $AWS $PREFIX_ENDPOINT $ENDPOINT_URL s3api put-bucket-encryption --bucket $BUCKET --server-side-encryption-configuration '{"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]}'
    else
        print_log info "Bucket \"$BUCKET\" exists and we have access to it"
    fi
}

function check_aws_folder
{
    local backup_path=${1-NO_DATASET}
    local dir_list=$($AWS $PREFIX_ENDPOINT $ENDPOINT_URL s3 ls $BUCKET/$backup_path 2>&1)
    if [[ $dir_list =~ 'An error occurred (AccessDenied)' ]]
    then
        print_log error "Access denied attempting to access $backup_path"
        exit 1
    elif [[ $dir_list == '' ]]
    then
        print_log notice "Creating remote folder $backup_path"
        $AWS $PREFIX_ENDPOINT $ENDPOINT_URL s3api put-object --bucket $BUCKET --key $backup_path/
    fi
}

function check_partial_uploads
{
    local current_mp_uploads=$( $AWS $PREFIX_ENDPOINT $ENDPOINT_URL s3api list-multipart-uploads --bucket $BUCKET )
    if [[ $current_mp_uploads != '' ]]
    then
        print_log warning "Incomplete multi-part uploads exists for $BUCKET"
    fi
}

function incremental_backup
{
    local snapshot=${1-}
    local backup_path=${2-}
    local filename=${3-}
    local last_full_snapshot=${4-}
    local last_full_snapshot_file=${5-}
    local increment_from=${6-}
    local increment_from_file=${7-}
    local backup_seq=${8-}
    local snapshot_time=${9-}

    #return if the dataset deos not contain any snapshots
    local snapshot_check=$( ${ZFS} list -t snapshot $snapshot )
    if [[ $snapshot_check =~ 'no datasets available' ]] 
    then
        return false
    fi

    local snapshot_size=$( ${ZFS} send --raw -nvPci $increment_from $snapshot | awk '/size/ {print $2}' )
    local snapshot_size_iec=$(bytesToHumanReadable $snapshot_size)

    print_log notice "Performing incremental backup of $snapshot from $increment_from ($snapshot_size_iec)"

    ${ZFS} send --raw -cpi $increment_from $snapshot | pv -s $snapshot_size -L $RATE_LIMIT | $AWS $PREFIX_ENDPOINT $ENDPOINT_URL s3 cp - s3://$BUCKET/$backup_path/$filename\
        --expected-size $snapshot_size \
        --metadata=$META_FULL_SNAPSHOT=false,\
$META_SNAPSHOT=$snapshot,\
$META_LAST_FULL=$last_full_snapshot,\
$META_LAST_FULL_FILE=$last_full_snapshot_file,\
$META_INCREMENT_FROM=$increment_from,\
$META_INCREMENT_FROM_FILE=$increment_from_file,\
$META_SNAPSHOT_CREATION=$snapshot_time,\
$META_BACKUP_SEQ=$backup_seq,\
$META_SCRIPT_VERSION=$SCRIPT_VERSION,\
$META_DEDUP=false,$META_LZ4=true

    if [[ $? == 0 ]]
    then
        print_log debug "Backup $filename uploaded, setting as complete"
        $AWS $PREFIX_ENDPOINT $ENDPOINT_URL s3api put-object-tagging --bucket $BUCKET --key $backup_path/$filename --tagging "$META_COMPLETE_TAG"
    else
        print_log critical "Error uploading $filename"
        EXIT_STATUS=1
    fi
}

function full_backup
{
    local snapshot=${1-}
    local backup_path=${2-}
    local filename=${3-}
    local snapshot_time=${4-}

    #return if the dataset deos not contain any snapshots
    local snapshot_check=$( ${ZFS} list -t snapshot $snapshot )
    if [[ $snapshot_check =~ 'no datasets available' ]] 
    then
        return false
    fi

    local snapshot_size=$( ${ZFS} send --raw -nvPc $snapshot | awk '/size/ {print $2}' )
    local snapshot_size_iec=$(bytesToHumanReadable $snapshot_size)

    print_log notice "Performing full backup of $snapshot ($snapshot_size_iec)"

    ${ZFS} send --raw -cp $snapshot | pv -s $snapshot_size -L $RATE_LIMIT | $AWS $PREFIX_ENDPOINT $ENDPOINT_URL s3 cp - s3://$BUCKET/$backup_path/$filename\
        --expected-size $snapshot_size \
        --metadata=$META_FULL_SNAPSHOT=true,\
$META_SNAPSHOT=$snapshot,\
$META_LAST_FULL=$snapshot,\
$META_LAST_FULL_FILE=$filename,\
$META_INCREMENT_FROM=$snapshot,\
$META_INCREMENT_FROM_FILE=$filename,\
$META_SNAPSHOT_CREATION=$snapshot_time,\
$META_BACKUP_SEQ=0,\
$META_SCRIPT_VERSION=$SCRIPT_VERSION,\
$META_DEDUP=false,$META_LZ4=true

    if [[ $? == 0 ]]
    then
        print_log debug "Backup $filename uploaded, setting as complete"
        $AWS $PREFIX_ENDPOINT $ENDPOINT_URL s3api put-object-tagging --bucket $BUCKET --key $backup_path/$filename --tagging "$META_COMPLETE_TAG"
    else
        print_log critical "Error uploading $filename"
        EXIT_STATUS=1
    fi
}

function backup_dataset
{
    local dataset=${1-}
    if [[ -z $( ${ZFS} list -Ho name | grep "^$dataset$" ) ]]
    then
        print_log error "Requested dataset $dataset from $OPT_CONFIG_FILE does not exist"
        return
    fi

    local snapshot_types=${2-$DEFAULT_SNAPSHOT_TYPES}
    local snapshot_incremental_types=${3-$DEFAULT_SNAPSHOT_TYPES}
    local max_incremental_backups=${4-$DEFAULT_MAX_INCREMENTAL_BACKUPS}
    local incremental_from_incremental=${5-$DEFAULT_INCREMENTAL_FROM_INCREMENTAL}

    print_log info ""
    print_log info "Running backup for dataset: $dataset, ss_types: $snapshot_types, ss_inctypes: $snapshot_incremental_types, max_increment: $max_incremental_backups, inc_from_inc: $incremental_from_incremental"

    local backup_path="$BACKUP_PATH/$dataset"
    check_aws_folder $backup_path

    local latest_remote_file=$( $AWS $PREFIX_ENDPOINT $ENDPOINT_URL s3 ls $BUCKET/$backup_path/ | grep -v \/\$ | sort -r | head -1 | awk '{print $4}' )
    # todo: check if completed correctly
    local latest_full_snapshot=$( ${ZFS} list -Ht snap -o name,creation -p |grep "^$dataset@"| grep $snapshot_types | sort -n -k2 | tail -1 | awk '{print $1}' )
    local latest_incremental_snapshot=$( ${ZFS} list -Ht snap -o name,creation -p |grep "^$dataset@"| grep $snapshot_incremental_types | sort -n -k2 | tail -1 | awk '{print $1}' )
    local latest_full_snapshot_time=$( ${ZFS} list -Ht snap -o creation -p $latest_full_snapshot )
    local latest_incremental_snapshot_time=$( ${ZFS} list -Ht snap -o creation -p $latest_incremental_snapshot )
    local remote_full_filename=$( echo $latest_full_snapshot | sed 's/\//./g' )
    local remote_incrumental_filename=$( echo $latest_incremental_snapshot | sed 's/\//./g' )

    # If there are no matches for this, there is no point looking for the possibility of an
    # incremental upload as it should be based off of this (or one like it). If doing increment on an increment
    # it might be ok, but for now let's assume it's not
    if [[ -z $latest_full_snapshot ]]
    then
        print_log error "No full snapshots found for $dataset"
        EXIT_STATUS=1
    elif [[ -z $latest_remote_file ]]
    then
        print_log info "No remote file for $dataset found. Performing full backup"
        full_backup $latest_full_snapshot $backup_path $remote_full_filename $latest_full_snapshot_time
    else
        # todo: check if completed correctly
        local remote_meta=$( $AWS $PREFIX_ENDPOINT $ENDPOINT_URL s3api head-object --bucket $BUCKET --key $backup_path/$latest_remote_file )
        local last_full=$(echo $remote_meta| jq -r ".Metadata.\"$META_LAST_FULL\"")
        local last_full_filename=$(echo $remote_meta| jq -r ".Metadata.\"$META_LAST_FULL_FILE\"")
        local backup_seq=$(( $(echo $remote_meta | jq -r ".Metadata.\"$META_BACKUP_SEQ\"" ) + 1 ))
        local increment_from=$(echo $remote_meta | jq -r ".Metadata.\"$META_SNAPSHOT\"")
        local script_version=$(echo $remote_meta | jq -r ".Metadata.\"$META_SCRIPT_VERSION\"")
        local increment_from_filename=$latest_remote_file
        local completed_upload=$( $AWS $PREFIX_ENDPOINT $ENDPOINT_URL s3api get-object-tagging --bucket $BUCKET --key $backup_path/$latest_remote_file | jq -r '.TagSet[] | select(.Key == "upload_state") | .Value' )
        local do_incremental_backup=1

        if [[ $OPT_FORCE -eq 0 && $completed_upload != $META_COMPLETE_VALUE ]]
        then
            # Fail the backup if there's an invalid file already uploaded as we don't know what
            # would be a better course of action at this stage (choose older? full backup?)
            print_log critical "Latest server upload $latest_remote_file either failed or still in progress"
            EXIT_STATUS=1
        elif [[ $OPT_FORCE -eq 0 && $script_version != "$SCRIPT_VERSION" ]]
        then
            print_log critical "Previous upload $latest_remote_file from version $script_version (current version: $SCRIPT_VERSION)"
            EXIT_STATUS=1
        else
            if [[ $incremental_from_incremental -ne 1 ]]
            then
                print_log info "Incremental incrementals turned off"
                increment_from=$last_full
                increment_from_filename=$last_full_filename
            elif [[ -z $( ${ZFS} list -Ht snap -o name | grep "^$increment_from$" ) ]]
            then
                print_log error "Previous snapshot missing ($increment_from) for $dataset reverting to last known full snapshot ($last_full)"
                increment_from=$last_full
                increment_from_filename=$last_full_filename
            fi

            if [[ $backup_seq -gt $max_incremental_backups ]]
            then
                print_log notice "Max number of incrementals reached for $dataset"
                do_incremental_backup=0
            elif [[ -z $( ${ZFS} list -Ht snap -o name | grep "^$increment_from$" ) ]]
            then
                print_log error "Previous snapshot ($increment_from) missing, reverting to full snapshot"
                do_incremental_backup=0
            elif [[ -z $latest_incremental_snapshot ]]
            then
                print_log info "Unable to find any matching/in-scope incremental snapshots, performing full snapshot"
                do_incremental_backup=0
            fi

            if [[ $do_incremental_backup -ne 0 ]]
            then
                if [[ $latest_remote_file == $remote_incrumental_filename ]]
                then
                    print_log notice "$dataset remote backup is already at current version ($latest_incremental_snapshot)"
                else
                    print_log debug "Doing incremental backup from increment $latest_incremental_snapshot from $latest_full_snapshot"
                    incremental_backup $latest_incremental_snapshot \
                        $backup_path \
                        $remote_incrumental_filename \
                        $last_full \
                        $last_full_filename \
                        $increment_from \
                        $increment_from_filename \
                        $backup_seq \
                        $latest_incremental_snapshot_time
                fi
            else
                if [[ $latest_remote_file == $remote_full_filename ]]
                then
                    print_log notice "$dataset remote backup is already at current version ($latest_full_snapshot)"
                else
                    print_log debug "Doing full backup from $latest_full_snapshot"
                    full_backup $latest_full_snapshot \
                        $backup_path \
                        $remote_full_filename \
                        $latest_full_snapshot_time
                fi
            fi
        fi
    fi
}

# Converts bytes value to human-readable string [$1: bytes value]
function bytesToHumanReadable
{
    local i=${1:-0} d="" s=0 S=("Bytes" "KiB" "MiB" "GiB" "TiB" "PiB" "EiB" "YiB" "ZiB")
    while ((i > 1024 && s < ${#S[@]}-1)); do
        printf -v d ".%02d" $((i % 1024 * 100 / 1024))
        i=$((i / 1024))
        s=$((s + 1))
    done
    echo "$i$d ${S[$s]}"
}

check_dep aws
check_dep jq
check_dep pv

check_set "zfs command not found in PATH" $ZFS
check_set "aws command not found in PATH" $AWS

getopt -T > /dev/null
if [ $? -eq 4 ]; then
    # GNU enhanced getopt is available
    GETOPT=$(getopt \
        --longoptions=force,config:,debug,help,quiet,syslog,verbose \
        --options=fc:dhqsv -- \
        "$@" ) \
        || exit 128
else
    # Original getopt is available (no long option names, no whitespace, no sorting)
    GETOPT=$(getopt fc:dhqsv "$@") || exit 128
fi

eval set -- "$GETOPT"

while [ "$#" -gt '0' ]
do
    case "$1" in
        (-f|--force)
            OPT_FORCE=1
            shift 1
            ;;
        (-c|--config)
            OPT_CONFIG_FILE=$2
            shift 2
            ;;
        (-d|--debug)
            OPT_DEBUG='1'
            OPT_QUIET=''
            OPT_VERBOSE='1'
            shift 1
            ;;
        (-h|--help)
            print_usage
            exit 0
            ;;
        (-q|--quiet)
            OPT_DEBUG=''
            OPT_QUIET='1'
            OPT_VERBOSE=''
            shift 1
            ;;
        (-s|--syslog)
            OPT_SYSLOG='1'
            shift 1
            ;;
        (-v|--verbose)
            OPT_QUIET=''
            OPT_VERBOSE='1'
            shift 1
            ;;
        (--)
            shift 1
            break
            ;;
    esac
done

load_config

exit $EXIT_STATUS

