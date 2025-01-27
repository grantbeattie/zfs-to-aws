#!/usr/bin/env bash

#Generate this config file
CONFIGFILE="/usr/local/etc/backup-zfs.conf"
#Which datasets do we want to backup
datasets="zroot pool0 pool1 pool4 pool5"

configBoilerplate='
###############################################################################
# DO NOT EDIT THIS FILE, USE $(basename $0)
# Config file for zfs aws uploader

# general options must be specified first
# then datasets in the format:
# [dataset]
# name=<name of dataset>
# max_incremental_backups=<number of incremental backups to take before taking a full one> (optional)
# incremental_incremental=[1|0] (1 means the increment will be off of the last upload, 0 means it will be off of the last full upload. Optional)
# snapshot_types=<pattern to match against snapshot names> (optional)
#  - typical types include: zfs-auto-snap_frequent\|zfs-auto-snap_hourly\|zfs-auto-snap_daily\|zfs-auto-snap_weekly\|zfs-auto-snap_monthly
#
#

bucket=wandering-base
aws_region=sthlm
endpoint_url=
#rate_limit=1024K
'

#Set zfs
ZFS=$(which zfs)

#Print head of config file
printf "${configBoilerplate}" > ${CONFIGFILE}

datasetConfig="

#snapshot types are from zfsnap, https://www.zfsnap.org
[dataset]
snapshot_types=hourly\|daily\|weekly\|monthly
max_incremental_backups=40
"

#List datasets recursive
for dataset in $datasets;
do
	#Filter away pool from result
	datasetArray=$(${ZFS} list -Hr -o name -s creation -t filesystem,volume ${dataset}|grep "/")
	for datasetArrayMem in $datasetArray;
	do
		printf "${datasetConfig}" >> ${CONFIGFILE}
		printf "name=${datasetArrayMem}" >> ${CONFIGFILE}
	done
done
