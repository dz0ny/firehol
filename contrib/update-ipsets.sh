#!/bin/bash
#
# FireHOL - A firewall for humans...
#
#   Copyright
#
#       Copyright (C) 2003-2014 Costa Tsaousis <costa@tsaousis.gr>
#       Copyright (C) 2012-2014 Phil Whineray <phil@sanewall.org>
#
#   License
#
#       This program is free software; you can redistribute it and/or modify
#       it under the terms of the GNU General Public License as published by
#       the Free Software Foundation; either version 2 of the License, or
#       (at your option) any later version.
#
#       This program is distributed in the hope that it will be useful,
#       but WITHOUT ANY WARRANTY; without even the implied warranty of
#       MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
#       GNU General Public License for more details.
#
#       You should have received a copy of the GNU General Public License
#       along with this program. If not, see <http://www.gnu.org/licenses/>.
#
#       See the file COPYING for details.
#

# What this program does:
#
# 1. It downloads a number of IP lists
#    - respects network resource: it will download a file only if it has
#      been changed on the server (IF_MODIFIED_SINCE)
#    - it will not attempt to download a file too frequently
#      (it has a maximum frequency per download URL embedded, so that
#      even if a server does not support IF_MODIFIED_SINCE it will not
#      download the IP list too frequently).
#
# 2. Once a file is downloaded, it will convert it either to
#    an ip:hash or a net:hash ipset.
#    It can convert:
#    - text files
#    - snort rules files
#    - PIX rules files
#    - XML files (like RSS feeds)
#    - CSV files
#    - compressed files (zip, gz, etc)
#
# 3. For all file types it can keep a history of the processed sets
#    that can be merged with the new downloaded one, so that it can
#    populate the generated set with all the IPs of the last X days.
#
# 4. For each set updated, it will call firehol to update the ipset
#    in memory, without restarting the firewall.
#    It considers an update successful only if the ipset is updated
#    in kernel successfuly.
#    Keep in mind that firehol will create a new ipset, add all the
#    IPs to it and then swap the right ipset with the temporary one
#    to activate it. This means that the ipset is updated only if
#    it can be parsed completely.
#
# 5. It can commit all successfully updated files to a git repository.
#    If it is called with -g it will also push the committed changes
#    to a remote git server (to have this done by cron, please set
#    git to automatically push changes without human action).
#
#
# -----------------------------------------------------------------------------
#
# How to use it:
# 
# Please make sure the file ipv4_range_to_cidr.awk is in the same directory
# as this script. If it is not, certain lists that need it will be disabled.
# 
# 1. Make sure you have firehol v3 or later installed.
# 2. Run this script. It will give you instructions on which
#    IP lists are available and what to do to enable them.
# 3. Enable a few lists, following its instructions.
# 4. Run it again to update the lists.
# 5. Put it in a cron job to do the updates automatically.

# -----------------------------------------------------------------------------
# At the end of file you can find the configuration for each of the IP lists
# it supports.
# -----------------------------------------------------------------------------

base="/etc/firehol/ipsets"

# single line flock, from man flock
[ "${UPDATE_IPSETS_LOCKER}" != "${0}" ] && exec env UPDATE_IPSETS_LOCKER="$0" flock -en "${base}/.lock" "${0}" "${@}" || :

PATH="${PATH}:/sbin:/usr/sbin"

LC_ALL=C
umask 077

if [ ! "$UID" = "0" ]
then
	echo >&2 "Please run me as root."
	exit 1
fi
renice 10 $$ >/dev/null 2>/dev/null

program_pwd="${PWD}"
program_dir="`dirname ${0}`"
awk="$(which awk 2>/dev/null)"
CAN_CONVERT_RANGES_TO_CIDR=0
if [ ! -z "${awk}" -a -x "${program_dir}/ipv4_range_to_cidr.awk" ]
then
	CAN_CONVERT_RANGES_TO_CIDR=1
fi

ipv4_range_to_cidr() {
	cd "${program_pwd}"
	${awk} -f "${program_dir}/ipv4_range_to_cidr.awk"
	cd "${OLDPWD}"
}

GIT_COMPARE=0
IGNORE_LASTCHECKED=0
PUSH_TO_GIT=0
SILENT=0
while [ ! -z "${1}" ]
do
	case "${1}" in
		-s) SILENT=1;;
		-g) PUSH_TO_GIT=1;;
		-i) IGNORE_LASTCHECKED=1;;
		-c) GIT_COMPARE=1;;
		*) echo >&2 "Unknown parameter '${1}'".; exit 1 ;;
	esac
	shift
done

# find curl
curl="$(which curl 2>/dev/null)"
if [ -z "${curl}" ]
then
	echo >&2 "Please install curl."
	exit 1
fi

# create the directory to save the sets
if [ ! -d "${base}" ]
then
	mkdir -p "${base}" || exit 1
fi
cd "${base}" || exit 1

if [ ! -d ".git" -a ${PUSH_TO_GIT} -ne 0 ]
then
	echo >&2 "Git is not initialized in ${base}. Ignoring git support."
	PUSH_TO_GIT=0
fi

# convert a number of minutes to a human readable text
mins_to_text() {
	local days= hours= mins="${1}"

	if [ -z "${mins}" -o $[mins + 0] -eq 0 ]
		then
		echo "none"
		return 0
	fi

	days=$[mins / (24*60)]
	mins=$[mins - (days * 24 * 60)]

	hours=$[mins / 60]
	mins=$[mins - (hours * 60)]

	case ${days} in
		0) ;;
		1) printf "1 day " ;;
		*) printf "%d days " ${days} ;;
	esac
	case ${hours} in
		0) ;;
		1) printf "1 hour " ;;
		*) printf "%d hours " ${hours} ;;
	esac
	case ${mins} in
		0) ;;
		1) printf "1 min " ;;
		*) printf "%d mins " ${mins} ;;
	esac
	printf "\n"

	return 0
}

syslog() {
	echo >&2 "${@}"
	logger -p daemon.info -t "update-ipsets.sh[$$]" "${@}"
}

# Generate the README.md file and push the repo to the remote server
declare -A UPDATED_DIRS=()
declare -A UPDATED_SETS=()

check_git_committed() {
	git ls-files "${1}" --error-unmatch >/dev/null 2>&1
	if [ $? -ne 0 ]
		then
		git add "${1}"
	fi
}

commit_to_git() {
	if [ -d .git -a ! -z "${!UPDATED_SETS[*]}" ]
	then
		[ ${GIT_COMPARE} -eq 1 ] && compare_all_ipsets

		local d=
		for d in "${!UPDATED_DIRS[@]}"
		do
			[ ! -f ${d}/README-EDIT.md ] && touch ${d}/README-EDIT.md
			(
				cat ${d}/README-EDIT.md
				echo
				echo "The following list was automatically generated on `date -u`."
				echo
				echo "The update frequency is the maximum allowed by internal configuration. A list will never be downloaded sooner than the update frequency stated. A list may also not be downloaded, after this frequency expired, if it has not been modified on the server (as reported by HTTP \`IF_MODIFIED_SINCE\` method)."
				echo
				echo "name|info|type|entries|update|"
				echo ":--:|:--:|:--:|:-----:|:----:|"
				cat ${d}/*.setinfo
			) >${d}/README.md

			UPDATED_SETS[${d}/README.md]="${d}/README.md"
			check_git_committed "${d}/README.md"
		done

		echo >>README.md
		echo "# Comparison of ipsets" >>README.md
		echo >>README.md
		echo "Below we compare each ipset against all other." >>README.md
		echo >>README.md

		for d in `find . -name \*.comparison.md | sort`
		do
			echo >>README.md
			cat "${d}" >>README.md
			rm "${d}"
		done

		echo >&2 
		syslog "Committing ${UPDATED_SETS[@]} to git repository"
		git commit "${UPDATED_SETS[@]}" -m "`date -u` update"

		if [ ${PUSH_TO_GIT} -ne 0 ]
		then
			echo >&2 
			syslog "Pushing git commits to remote server"
			git push
		fi
	fi

	trap exit EXIT
	exit 0
}
# make sure we commit to git when we exit
trap commit_to_git EXIT
trap commit_to_git SIGHUP
trap commit_to_git INT

# touch a file to a relative date in the past
touch_in_the_past() {
	local mins_ago="${1}" file="${2}"

	local now=$(date +%s)
	local date=$(date -d @$[now - (mins_ago * 60)] +"%y%m%d%H%M.%S")
	touch -t "${date}" "${file}"
}
touch_in_the_past $[7 * 24 * 60] ".warn_if_last_downloaded_before_this"

# get all the active ipsets in the system
ipset_list_names() {
	( ipset --list -t || ipset --list ) | grep "^Name: " | cut -d ' ' -f 2
}

echo
echo "`date`: ${0} ${*}" 
echo

# find the active ipsets
echo >&2 "Getting list of active ipsets..."
declare -A sets=()
for x in $(ipset_list_names)
do
	sets[$x]=1
done
test ${SILENT} -ne 1 && echo >&2 "Found these ipsets active: ${!sets[@]}"


# -----------------------------------------------------------------------------

# check if a file is too old
check_file_too_old() {
	local ipset="${1}" file="${2}"

	if [ -f "${file}" -a ".warn_if_last_downloaded_before_this" -nt "${file}" ]
	then
		syslog "${ipset}: DATA ARE TOO OLD!"
		return 1
	fi
	return 0
}

history_manager() {
	local ipset="${1}" mins="${2}" file="${3}" \
		tmp= x= slot="`date +%s`.set"

	# make sure the directories exist
	if [ ! -d "history" ]
	then
		mkdir "history" || return 1
		chmod 700 "history"
	fi

	if [ ! -d "history/${ipset}" ]
	then
		mkdir "history/${ipset}" || return 2
		chmod 700 "history/${ipset}"
	fi

	# touch a reference file
	touch_in_the_past ${mins} "history/${ipset}/.reference" || return 3

	# move the new file to the rss history
	mv "${file}" "history/${ipset}/${slot}"
	touch "history/${ipset}/${slot}"

	# replace the original file with a concatenation of
	# all the files newer than the reference file
	for x in history/${ipset}/*.set
	do
		if [ "${x}" -nt "history/${ipset}/.reference" ]
		then
			test ${SILENT} -ne 1 && echo >&2 "${ipset}: merging history file '${x}'"
			cat "${x}"
		else
			rm "${x}"
		fi
	done | sort -u >"${file}"
	rm "history/${ipset}/.reference"

	return 0
}

# fetch a url
# the output file has the last modified timestamp
# of the server
# on the next run, the file is downloaded only
# if it has changed on the server
geturl() {
	local file="${1}" reference="${2}" url="${3}" ret=

	# copy the timestamp of the reference
	# to our file
	touch -r "${reference}" "${file}"

	${curl} -z "${reference}" -o "${file}" -s -L -R "${url}"
	ret=$?

	if [ ${ret} -eq 0 -a ! "${file}" -nt "${reference}" ]
	then
		return 99
	fi
	return ${ret}
}

# download a file if it has not been downloaded in the last $mins
DOWNLOAD_OK=0
DOWNLOAD_FAILED=1
DOWNLOAD_NOT_UPDATED=2
download_url() {
	local 	ipset="${1}" mins="${2}" url="${3}" \
		install="${1}" \
		tmp= now= date= check=

	tmp=`mktemp "${install}.tmp-XXXXXXXXXX"` || return ${DOWNLOAD_FAILED}

	# touch a file $mins ago
	touch_in_the_past "${mins}" "${tmp}"

	check="${install}.source"
	[ ${IGNORE_LASTCHECKED} -eq 0 -a -f "${install}.lastchecked" ] && check="${install}.lastchecked"

	# check if we have to download again
	if [ "${check}" -nt "${tmp}" ]
	then
		rm "${tmp}"
		echo >&2 "${ipset}: should not be downloaded so soon."
		return ${DOWNLOAD_NOT_UPDATED}
	fi

	# download it
	test ${SILENT} -ne 1 && echo >&2 "${ipset}: downlading from '${url}'..."
	geturl "${tmp}" "${install}.source" "${url}"
	case $? in
		0)	;;
		99)
			echo >&2 "${ipset}: file on server has not been updated yet"
			rm "${tmp}"
			touch_in_the_past $[mins / 2] "${install}.lastchecked"
			return ${DOWNLOAD_NOT_UPDATED}
			;;

		*)
			syslog "${ipset}: cannot download '${url}'."
			rm "${tmp}"
			return ${DOWNLOAD_FAILED}
			;;
	esac

	# we downloaded something - remove the lastchecked file
	[ -f "${install}.lastchecked" ] && rm "${install}.lastchecked"

	# check if the downloaded file is empty
	if [ ! -s "${tmp}" ]
	then
		# it is empty
		rm "${tmp}"
		syslog "${ipset}: empty file downloaded from url '${url}'."
		return ${DOWNLOAD_FAILED}
	fi

	# check if the downloaded file is the same with the last one
	diff -q "${install}.source" "${tmp}" >/dev/null 2>&1
	if [ $? -eq 0 ]
	then
		# they are the same
		test ${SILENT} -ne 1 && echo >&2 "${ipset}: downloaded file is the same with the previous one."

		# copy the timestamp of the downloaded to our file
		touch -r "${tmp}" "${install}.source"
		rm "${tmp}"
		return ${DOWNLOAD_NOT_UPDATED}
	fi

	# move it to its place
	test ${SILENT} -ne 1 && echo >&2 "${ipset}: saving downloaded file to ${install}.source"
	mv "${tmp}" "${install}.source" || return ${DOWNLOAD_FAILED}

	return ${DOWNLOAD_OK}
}

ips_in_set() {
	# the ipset/netset has to be
	# aggregated properly

	append_slash32 |\
		cut -d '/' -f 2 |\
		(
			local sum=0;
			while read i
			do
				sum=$[sum + (1 << (32 - i))]
			done
			echo $sum
		)		
}

# -----------------------------------------------------------------------------
# ipsets comparisons

declare -A IPSET_INFO=()
declare -A IPSET_SOURCE=()
declare -A IPSET_URL=()
declare -A IPSET_FILES=()
declare -A IPSET_ENTRIES=()
declare -A IPSET_IPS=()
declare -A IPSET_OVERLAPS=()
cache_save() {
	#echo >&2 "Saving cache"
	declare -p IPSET_SOURCE IPSET_URL IPSET_INFO IPSET_FILES IPSET_ENTRIES IPSET_IPS IPSET_OVERLAPS >"${base}/.cache"
}
if [ -f "${base}/.cache" ]
	then
	echo >&2 "Loading cache"
	source "${base}/.cache"
	cache_save
fi
cache_remove_ipset() {
	local ipset="${1}"
	echo >&2 "${ipset}: removing from cache"
	cache_clean_ipset "${ipset}"
	unset IPSET_INFO[${ipset}]
	unset IPSET_SOURCE[${ipset}]
	unset IPSET_URL[${ipset}]
	unset IPSET_FILES[${ipset}]
	unset IPSET_ENTRIES[${ipset}]
	cache_save
}
cache_clean_ipset() {
	local ipset="${1}"

	echo >&2 "${ipset}: Cleaning cache"
	unset IPSET_ENTRIES[${ipset}]
	unset IPSET_IPS[${ipset}]
	local x=
	for x in "${!IPSET_FILES[@]}"
	do
		unset IPSET_OVERLAPS[,${ipset},${x},]
		unset IPSET_OVERLAPS[,${x},${ipset},]
	done
	cache_save
}
cache_update_ipset() {
	local ipset="${1}"
	[ -z "${IPSET_ENTRIES[${ipset}]}" ] && IPSET_ENTRIES[${ipset}]=`cat "${IPSET_FILES[${ipset}]}" | remove_comments | wc -l`
	[ -z "${IPSET_IPS[${ipset}]}"     ] && IPSET_IPS[${ipset}]=`cat "${IPSET_FILES[${ipset}]}" | remove_comments | ips_in_set`
	return 0
}

print_last_digit_decimal() {
	local x="${1}" len= pl=
	len="${#x}"
	while [ ${len} -lt 2 ]
	do
		x="0${x}"
		len="${#x}"
	done
	pl="$[len - 1]"
	echo "${x:0:${pl}}.${x:${pl}:${len}}"
}

compare_ipset() {
	local ipset="${1}" file= readme= info= entries= ips=
	shift

	file="${IPSET_FILES[${ipset}]}"
	info="${IPSET_INFO[${ipset}]}"
	readme="${file/.ipset/}"
	readme="${readme/.netset/}"
	readme="${readme}.comparison.md"

	[[ "${file}" =~ ^geolite2.* ]] && return 1

	if [ -z "${file}" -o ! -f "${file}" ]
		then
		cache_remove_ipset "${ipset}"
		return 1
	fi
	
	cache_update_ipset "${ipset}"
	entries="${IPSET_ENTRIES[${ipset}]}"
	ips="${IPSET_IPS[${ipset}]}"

	if [ -z "${entries}" -o -z "${ips}" ]
		then
		echo >&2 "${ipset}: ERROR empty cache entries"
		return 1
	fi

	printf >&2 "${ipset}: Generating comparisons... "

	cat >${readme} <<EOFMD
## ${ipset}

${info}

Source is downloaded from [this link](${IPSET_URL[${ipset}]}).

The last time downloaded was found to be dated: `date -r "${IPSET_SOURCE[${ipset}]}" -u`.

The ipset \`${ipset}\` has **${entries}** entries, **${ips}** unique IPs.

The following table shows the overlaps of \`${ipset}\` with all the other ipsets supported. Only the ipsets that have at least 1 IP overlap are shown. if an ipset is not shown here, it does not have any overlap with \`${ipset}\`.

- \` them % \` is the percentage of IPs of each row ipset (them), found in \`${ipset}\`.
- \` this % \` is the percentage **of this ipset (\`${ipset}\`)**, found in the IPs of each other ipset.

ipset|entries|unique IPs|IPs on both| them % | this % |
:---:|:-----:|:--------:|:---------:|:------:|:------:|
EOFMD
	
	local oipset=
	for oipset in "${!IPSET_FILES[@]}"
	do
		[ "${ipset}" = "${oipset}" ] && continue

		local ofile="${IPSET_FILES[${oipset}]}"
		if [ ! -f "${ofile}" ]
			then
			cache_remove_ipset "${oipset}"
			continue
		fi

		[[ "${ofile}" =~ ^geolite2.* ]] && return 1

		cache_update_ipset "${oipset}"
		local oentries="${IPSET_ENTRIES[${oipset}]}"
		local oips="${IPSET_IPS[${oipset}]}"

		if [ -z "${oentries}" -o -z "${oips}" ]
			then
			echo >&2 "${oipset}: ERROR empty cache data"
			continue
		fi

		# echo >&2 "	Updating overlaps for ${ipset} compared to ${oipset}..."

		if [ -z "${IPSET_OVERLAPS[,${ipset},${oipset},]}${IPSET_OVERLAPS[,${oipset},${ipset},]}" ]
			then
			printf >&2 "+"
			local mips=`cat "${file}" "${ofile}" | remove_comments | append_slash32 | sort -u | aggregate4 | ips_in_set`
			IPSET_OVERLAPS[,${ipset},${oipset},]=$[(ips + oips) - mips]
			#echo "IPSET_OVERLAPS[,${ipset},${oipset},]=${IPSET_OVERLAPS[,${ipset},${oipset},]}" >>"${base}/.cache"
		else
			printf >&2 "."
		fi
		local overlap="${IPSET_OVERLAPS[,${ipset},${oipset},]}${IPSET_OVERLAPS[,${oipset},${ipset},]}"

		[ ${overlap} -gt 0 ] && echo "${overlap}|[${oipset}](#${oipset})|${oentries}|${oips}|${overlap}|$(print_last_digit_decimal $[overlap * 1000 / oips])%|$(print_last_digit_decimal $[overlap * 1000 / ips])%|" >>${readme}.tmp
	done
	cat "${readme}.tmp" | sort -n -r | cut -d '|' -f 2- >>${readme}
	rm "${readme}.tmp"

	echo >&2
	cache_save
}

compare_all_ipsets() {
	local x=
	for x in "${!IPSET_FILES[@]}"
	do
		compare_ipset "${x}" "${!IPSET_FILES[@]}"
	done
}

# -----------------------------------------------------------------------------

finalize() {
	local ipset="${1}" tmp="${2}" setinfo="${3}" src="${4}" dst="${5}" mins="${6}" history_mins="${7}" ipv="${8}" type="${9}" hash="${10}" url="${11}" info="${12}"

	# remove the comments from the existing file
	if [ -f "${dst}" ]
	then
		cat "${dst}" | grep -v "^#" > "${tmp}.old"
	else
		touch "${tmp}.old"
	fi

	# compare the new and the old
	diff -q "${tmp}.old" "${tmp}" >/dev/null 2>&1
	if [ $? -eq 0 ]
	then
		# they are the same
		rm "${tmp}" "${tmp}.old"
		test ${SILENT} -ne 1 && echo >&2 "${ipset}: processed set is the same with the previous one."
		
		# keep the old set, but make it think it was from this source
		touch -r "${src}" "${dst}"

		check_file_too_old "${ipset}" "${dst}"
		return 0
	fi
	rm "${tmp}.old"

	# calculate how many entries/IPs are in it
	local ipset_opts=
	local entries=$(wc -l "${tmp}" | cut -d ' ' -f 1)
	local size=$[ ( ( (entries * 130 / 100) / 65536 ) + 1 ) * 65536 ]

	# if the ipset is not already in memory
	if [ -z "${sets[$ipset]}" ]
	then
		# if the required size is above 65536
		if [ ${size} -ne 65536 ]
		then
			echo >&2 "${ipset}: processed file gave ${entries} results - sizing to ${size} entries"
			echo >&2 "${ipset}: remember to append this to your ipset line (in firehol.conf): maxelem ${size}"
			ipset_opts="maxelem ${size}"
		fi

		echo >&2 "${ipset}: creating ipset with ${entries} entries"
		ipset --create ${ipset} "${hash}hash" ${ipset_opts} || return 1
	fi

	# call firehol to update the ipset in memory
	firehol ipset_update_from_file ${ipset} ${ipv} ${type} "${tmp}"
	if [ $? -ne 0 ]
	then
		if [ -d errors ]
		then
			mv "${tmp}" "errors/${ipset}.${hash}set"
			syslog "${ipset}: failed to update ipset (error file left for you as 'errors/${ipset}.${hash}set')."
		else
			rm "${tmp}"
			syslog "${ipset}: failed to update ipset."
		fi
		check_file_too_old "${ipset}" "${dst}"
		return 1
	fi

	local ips= quantity=

	# find how many IPs are there
	ips=${entries}
	quantity="${ips} unique IPs"

	if [ "${hash}" = "net" ]
	then
		entries=${ips}
		ips=`cat "${tmp}" | ips_in_set`
		quantity="${entries} subnets, ${ips} unique IPs"
	fi

	# generate the final file
	# we do this on another tmp file
	cat >"${tmp}.wh" <<EOFHEADER
#
# ${ipset}
#
# ${ipv} hash:${hash} ipset
#
`echo "${info}" | fold -w 60 -s | sed "s/^/# /g"`
#
# Source URL: ${url}
#
# Source File Date: `date -r "${src}" -u`
# This File Date  : `date -u`
# Update Frequency: `mins_to_text ${mins}`
# Aggregation     : `mins_to_text ${history_mins}`
# Entries         : ${quantity}
#
# Generated by FireHOL's update-ipsets.sh
#
EOFHEADER

	cat "${tmp}" >>"${tmp}.wh"
	rm "${tmp}"
	touch -r "${src}" "${tmp}.wh"
	mv "${tmp}.wh" "${dst}" || return 1

	cache_clean_ipset "${ipset}"
	IPSET_FILES[${ipset}]="${dst}"
	IPSET_INFO[${ipset}]="${info}"
	IPSET_ENTRIES[${ipset}]="${entries}"
	IPSET_IPS[${ipset}]="${ips}"
	IPSET_URL[${ipset}]="${url}"
	IPSET_SOURCE[${ipset}]="${src}"

	UPDATED_SETS[${ipset}]="${dst}"
	local dir="`dirname "${dst}"`"
	UPDATED_DIRS[${dir}]="${dir}"

	if [ -d .git ]
	then
		echo >"${setinfo}" "[${ipset}](#${ipset})|${info}|${ipv} hash:${hash}|${quantity}|updated every `mins_to_text ${mins}` from [this link](${url})"
		check_git_committed "${dst}"
	fi

	return 0
}

update() {
	local 	ipset="${1}" mins="${2}" history_mins="${3}" ipv="${4}" type="${5}" url="${6}" processor="${7-cat}" info="${8}"
		install="${1}" tmp= error=0 now= date= pre_filter="cat" post_filter="cat" post_filter2="cat" filter="cat"
	shift 8

	case "${ipv}" in
		ipv4)
			post_filter2="filter_invalid4"
			case "${type}" in
				ip|ips)		hash="ip"
						type="ip"
						pre_filter="remove_slash32"
						filter="filter_ip4"
						;;

				net|nets)	hash="net"
						type="net"
						filter="filter_net4"
						post_filter="aggregate4"
						;;

				both|all)	hash="net"
						type=""
						filter="filter_all4"
						post_filter="aggregate4"
						;;

				split)		;;

				*)		echo >&2 "${ipset}: unknown type '${type}'."
						return 1
						;;
			esac
			;;
		ipv6)
			case "${type}" in
				ip|ips)		hash="ip"
						type="ip"
						pre_filter="remove_slash128"
						filter="filter_ip6"
						;;

				net|nets)	hash="net"
						type="net"
						filter="filter_net6"
						;;

				both|all)	hash="net"
						type=""
						filter="filter_all6"
						;;

				split)		;;

				*)		echo >&2 "${ipset}: unknown type '${type}'."
						return 1
						;;
			esac
			;;

		*)	syslog "${ipset}: unknown IP version '${ipv}'."
			return 1
			;;
	esac

	if [ ! -f "${install}.source" ]
	then
		echo >&2 "${ipset}: is disabled, to enable it run: touch -t 0001010000 '${base}/${install}.source'"
		return 1
	fi

	# download it
	download_url "${ipset}" "${mins}" "${url}"
	if [ $? -eq ${DOWNLOAD_FAILED} -o \( $? -eq ${DOWNLOAD_NOT_UPDATED} -a -f "${install}.${hash}set" \) ]
	then
		check_file_too_old "${ipset}" "${install}.${hash}set"
		return 1
	fi

	# support for older systems where hash:net cannot get hash:ip entries
	# if the .split file exists, create 2 ipsets, one for IPs and one for subnets
	if [ "${type}" = "split" -o \( -z "${type}" -a -f "${install}.split" \) ]
	then
		echo >&2 "${ipset}: spliting IPs and networks..."
		test -f "${install}_ip.source" && rm "${install}_ip.source"
		test -f "${install}_net.source" && rm "${install}_net.source"
		ln -s "${install}.source" "${install}_ip.source"
		ln -s "${install}.source" "${install}_net.source"
		update "${ipset}_ip" "${mins}" "${history_mins}" "${ipv}" ip  "${url}" "${processor}"
		update "${ipset}_net" "${mins}" "${history_mins}" "${ipv}" net "${url}" "${processor}"
		return $?
	fi

	# check if the source file has been updated
	if [ ! "${install}.source" -nt "${install}.${hash}set" ]
	then
		echo >&2 "${ipset}: not updated - no reason to process it again."
		check_file_too_old "${ipset}" "${install}.${hash}set"
		return 0
	fi

	# convert it
	test ${SILENT} -ne 1 && echo >&2 "${ipset}: converting with processor '${processor}'"
	tmp=`mktemp "${install}.tmp-XXXXXXXXXX"` || return 1
	${processor} <"${install}.source" |\
		trim |\
		${pre_filter} |\
		${filter} |\
		${post_filter} |\
		${post_filter2} |\
		sort -u >"${tmp}"
	
	if [ $? -ne 0 ]
	then
		rm "${tmp}"
		syslog "${ipset}: failed to convert file."
		check_file_too_old "${ipset}" "${install}.${hash}set"
		return 1
	fi

	if [ ! -s "${tmp}" ]
	then
		rm "${tmp}"
		syslog "${ipset}: processed file gave no results."

		# keep the old set, but make it think it was from this source
		touch -r "${install}.source" "${install}.${hash}set"

		check_file_too_old "${ipset}" "${install}.${hash}set"
		return 2
	fi

	if [ $[history_mins + 0] -gt 0 ]
	then
		history_manager "${ipset}" "${history_mins}" "${tmp}"
	fi


	finalize "${ipset}" "${tmp}" "${install}.setinfo" "${install}.source" "${install}.${hash}set" "${mins}" "${history_mins}" "${ipv}" "${type}" "${hash}" "${url}" "${info}"
	return $?
}


# -----------------------------------------------------------------------------
# INTERNAL FILTERS

aggregate4_warning=0
aggregate4() {
	local cmd=

	if [ -x "${base}/iprange" ]
		then
		"${base}/iprange" -J | append_slash32
		return $?
	fi

	cmd="`which iprange 2>/dev/null`"
	if [ ! -z "${cmd}" ]
	then
		${cmd} -J | append_slash32
		return $?
	fi
	
	cmd="`which aggregate-flim 2>/dev/null`"
	if [ ! -z "${cmd}" ]
	then
		${cmd}
		return $?
	fi

	cmd="`which aggregate 2>/dev/null`"
	if [ ! -z "${cmd}" ]
	then
		[ ${aggregate4_warning} -eq 0 ] && echo >&2 "The command aggregate installed is really slow, please install aggregate-flim or iprange (http://www.cs.colostate.edu/~somlo/iprange.c)."
		aggregate4_warning=1

		append_slash32 | ${cmd} -t
		return $?
	fi

	[ ${aggregate4_warning} -eq 0 ] && echo >&2 "Warning: Cannot aggregate ip-ranges. Please install 'aggregate'. Working wihout aggregate (http://www.cs.colostate.edu/~somlo/iprange.c)."
	aggregate4_warning=1

	cat
}

filter_ip4()  { egrep "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$"; }
filter_net4() { egrep "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$"; }
filter_all4() { egrep "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9\.]+(/[0-9]+)?$"; }

filter_ip6()  { egrep "^[0-9a-fA-F:]+$"; }
filter_net6() { egrep "^[0-9a-fA-F:]+/[0-9]+$"; }
filter_all6() { egrep "^[0-9a-fA-F:]+(/[0-9]+)?$"; }

remove_slash32() { sed "s|/32$||g"; }
remove_slash128() { sed "s|/128$||g"; }

append_slash32() {
	# this command appends '/32' to all the lines
	# that do not include a slash
	awk '/\// {print $1; next}; // {print $1 "/32" }'	
}

append_slash128() {
	# this command appends '/32' to all the lines
	# that do not include a slash
	awk '/\// {print $1; next}; // {print $1 "/128" }'	
}

filter_invalid4() {
	egrep -v "^(0\.0\.0\.0|0\.0\.0\.0/0|255\.255\.255\.255|255\.255\.255\.255/0)$"
}


# -----------------------------------------------------------------------------
# XML DOM PARSER

# excellent article about XML parsing is BASH
# http://stackoverflow.com/questions/893585/how-to-parse-xml-in-bash

XML_ENTITY=
XML_CONTENT=
XML_TAG_NAME=
XML_ATTRIBUTES=
read_xml_dom () {
	local IFS=\>
	read -d \< XML_ENTITY XML_CONTENT
	local ret=$?
	XML_TAG_NAME=${ENTITY%% *}
	XML_ATTRIBUTES=${ENTITY#* }
	return $ret
}

parse_rss_rosinstrument() {
	while read_xml_dom
	do
		if [ "${XML_ENTITY}" = "title" ]
		then
			if [[ "${XML_CONTENT}" =~ ^.*:[0-9]+$ ]]
			then
				local hostname="${XML_CONTENT/:*/}"

				if [[ "${hostname}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
				then
					# it is an IP already
					# echo "${hostname} # from ${XML_CONTENT}"
					echo "${hostname}"
				else
					# it is a hostname - resolve it
					local host=`host "${hostname}" | grep " has address " | cut -d ' ' -f 4`
					if [ $? -eq 0 -a ! -z "${host}" ]
					then
						# echo "${host} # from ${XML_CONTENT}"
						echo "${host}"
					#else
					#	echo "# Cannot resolve ${hostname} taken from ${XML_CONTENT}"
					fi
				fi
			fi
		fi
	done
}

parse_php_rss() {
	while read_xml_dom
	do
		if [ "${XML_ENTITY}" = "title" ]
		then
			if [[ "${XML_CONTENT}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+.*$ ]]
			then
				echo "${XML_CONTENT/|*/}"
			fi
		fi
	done
}

parse_xml_clean_mx() {
	while read_xml_dom
	do
		case "${XML_ENTITY}" in
			ip) echo "${XML_CONTENT}"
		esac
	done
}


# -----------------------------------------------------------------------------
# CONVERTERS
# These functions are used to convert from various sources
# to IP or NET addresses

subnet_to_bitmask() {
	sed	-e "s|/255\.255\.255\.255|/32|g" -e "s|/255\.255\.255\.254|/31|g" -e "s|/255\.255\.255\.252|/30|g" \
		-e "s|/255\.255\.255\.248|/29|g" -e "s|/255\.255\.255\.240|/28|g" -e "s|/255\.255\.255\.224|/27|g" \
		-e "s|/255\.255\.255\.192|/26|g" -e "s|/255\.255\.255\.128|/25|g" -e "s|/255\.255\.255\.0|/24|g" \
		-e "s|/255\.255\.254\.0|/23|g"   -e "s|/255\.255\.252\.0|/22|g"   -e "s|/255\.255\.248\.0|/21|g" \
		-e "s|/255\.255\.240\.0|/20|g"   -e "s|/255\.255\.224\.0|/19|g"   -e "s|/255\.255\.192\.0|/18|g" \
		-e "s|/255\.255\.128\.0|/17|g"   -e "s|/255\.255\.0\.0|/16|g"     -e "s|/255\.254\.0\.0|/15|g" \
		-e "s|/255\.252\.0\.0|/14|g"     -e "s|/255\.248\.0\.0|/13|g"     -e "s|/255\.240\.0\.0|/12|g" \
		-e "s|/255\.224\.0\.0|/11|g"     -e "s|/255\.192\.0\.0|/10|g"     -e "s|/255\.128\.0\.0|/9|g" \
		-e "s|/255\.0\.0\.0|/8|g"        -e "s|/254\.0\.0\.0|/7|g"        -e "s|/252\.0\.0\.0|/6|g" \
		-e "s|/248\.0\.0\.0|/5|g"        -e "s|/240\.0\.0\.0|/4|g"        -e "s|/224\.0\.0\.0|/3|g" \
		-e "s|/192\.0\.0\.0|/2|g"        -e "s|/128\.0\.0\.0|/1|g"        -e "s|/0\.0\.0\.0|/0|g"
}

trim() {
	sed -e "s/[\t ]\+/ /g" -e "s/^ \+//g" -e "s/ \+$//g" |\
		grep -v "^$"
}

remove_comments() {
	# remove:
	# 1. replace \r with \n
	# 2. everything on the same line after a #
	# 3. multiple white space (tabs and spaces)
	# 4. leading spaces
	# 5. trailing spaces
	# 6. empty lines
	tr "\r" "\n" |\
		sed -e "s/#.*$//g" -e "s/[\t ]\+/ /g" -e "s/^ \+//g" -e "s/ \+$//g" |\
		grep -v "^$"
}

gz_remove_comments() {
	gzip -dc | remove_comments
}

remove_comments_semi_colon() {
	# remove:
	# 1. replace \r with \n
	# 2. everything on the same line after a ;
	# 3. multiple white space (tabs and spaces)
	# 4. leading spaces
	# 5. trailing spaces
	# 6. empty lines
	tr "\r" "\n" |\
		sed -e "s/;.*$//g" -e "s/[\t ]\+/ /g" -e "s/^ \+//g" -e "s/ \+$//g" |\
		grep -v "^$"
}

# convert snort rules to a list of IPs
snort_alert_rules_to_ipv4() {
	remove_comments |\
		grep ^alert |\
		sed -e "s|^alert .* \[\([0-9/,\.]\+\)\] any -> \$HOME_NET any .*$|\1|g" -e "s|,|\n|g" |\
		grep -v ^alert
}

pix_deny_rules_to_ipv4() {
	remove_comments |\
		grep ^access-list |\
		sed -e "s|^access-list .* deny ip \([0-9\.]\+\) \([0-9\.]\+\) any$|\1/\2|g" \
		    -e "s|^access-list .* deny ip host \([0-9\.]\+\) any$|\1|g" |\
		grep -v ^access-list |\
		subnet_to_bitmask
}

dshield_parser() {
	local net= mask=
	remove_comments | grep "^[1-9]" | cut -d ' ' -f 1,3 | while read net mask; do echo "${net}/${mask}"; done
}

unzip_and_split_csv() {
	funzip | tr ",\r" "\n\n"
}

unzip_and_extract() {
	funzip
}

p2p_gz_proxy() {
	gzip -dc |\
		grep "^Proxy" |\
		cut -d ':' -f 2 |\
		egrep "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\-[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$" |\
		ipv4_range_to_cidr
}

p2p_gz() {
	gzip -dc |\
		cut -d ':' -f 2 |\
		egrep "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\-[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$" |\
		ipv4_range_to_cidr
}

csv_comma_first_column() {
	grep "^[0-9]" |\
		cut -d ',' -f 1
}

gz_second_word() {
	gzip -dc |\
		tr '\r' '\n' |\
		cut -d ' ' -f 2
}

geolite2_country() {
	local ipset="geolite2_country" type="net" hash="net" ipv="ipv4" \
		mins=$[24 * 60 * 7] history_mins=0 \
		url="http://geolite.maxmind.com/download/geoip/database/GeoLite2-Country-CSV.zip" \
		info="[MaxMind GeoLite2](http://dev.maxmind.com/geoip/geoip2/geolite2/)"

	if [ ! -f "${ipset}.source" ]
	then
		echo >&2 "${ipset}: is disabled, to enable it run: touch -t 0001010000 '${base}/${ipset}.source'"
		return 1
	fi

	# download it
	download_url "${ipset}" "${mins}" "${url}"
	[ $? -eq ${DOWNLOAD_FAILED} -o \( $? -eq ${DOWNLOAD_NOT_UPDATED} -a -d ${ipset} \) ] && return 1

	# create a temp dir
	[ -d ${ipset}.tmp ] && rm -rf ${ipset}.tmp
	mkdir ${ipset}.tmp || return 1

	# create the final dir
	if [ ! -d ${ipset} ]
	then
		mkdir ${ipset} || return 1
	fi

	# extract it

	# The country db has the following columns:
	# 1. network 				the subnet
	# 2. geoname_id 			the country code it is used
	# 3. registered_country_geoname_id 	the country code it is registered
	# 4. represented_country_geoname_id 	the country code it belongs to (army bases)
	# 5. is_anonymous_proxy 		boolean: VPN providers, etc
	# 6. is_satellite_provider 		boolean: cross-country providers

	echo >&2 "${ipset}: Extracting country and continent netsets..."
	unzip -jpx "${ipset}.source" "*/GeoLite2-Country-Blocks-IPv4.csv" |\
		awk -F, '
		{
			if( $2 )        { print $1 >"geolite2_country.tmp/country."$2".source.tmp" }
			if( $3 )        { print $1 >"geolite2_country.tmp/country."$3".source.tmp" }
			if( $4 )        { print $1 >"geolite2_country.tmp/country."$4".source.tmp" }
			if( $5 == "1" ) { print $1 >"geolite2_country.tmp/anonymous.source.tmp" }
			if( $6 == "1" ) { print $1 >"geolite2_country.tmp/satellite.source.tmp" }
		}'

	# remove the files created of the header line
	[ -f "${ipset}.tmp/country.geoname_id.source.tmp"                     ] && rm "${ipset}.tmp/country.geoname_id.source.tmp"
	[ -f "${ipset}.tmp/country.registered_country_geoname_id.source.tmp"  ] && rm "${ipset}.tmp/country.registered_country_geoname_id.source.tmp"
	[ -f "${ipset}.tmp/country.represented_country_geoname_id.source.tmp" ] && rm "${ipset}.tmp/country.represented_country_geoname_id.source.tmp"

	# The localization db has the following columns:
	# 1. geoname_id
	# 2. locale_code
	# 3. continent_code
	# 4. continent_name
	# 5. country_iso_code
	# 6. country_name

	echo >&2 "${ipset}: Grouping country and continent netsets..."
	unzip -jpx "${ipset}.source" "*/GeoLite2-Country-Locations-en.csv" |\
	(
		IFS=","
		while read id locale cid cname iso name
		do
			[ "${id}" = "geoname_id" ] && continue

			cname="${cname//\"/}"
			cname="${cname//[/(}"
			cname="${cname//]/)}"
			name="${name//\"/}"
			name="${name//[/(}"
			name="${name//]/)}"
			
			if [ -f "${ipset}.tmp/country.${id}.source.tmp" ]
			then
				[ ! -z "${cid}" ] && cat "${ipset}.tmp/country.${id}.source.tmp" >>"${ipset}.tmp/continent_${cid,,}.source.tmp"
				[ ! -z "${iso}" ] && cat "${ipset}.tmp/country.${id}.source.tmp" >>"${ipset}.tmp/country_${iso,,}.source.tmp"
				rm "${ipset}.tmp/country.${id}.source.tmp"

				[ ! -f "${ipset}.tmp/continent_${cid,,}.source.tmp.info" ] && printf "%s" "${cname} (${cid}), with countries: " >"${ipset}.tmp/continent_${cid,,}.source.tmp.info"
				printf "%s" "${name} (${iso}), " >>"${ipset}.tmp/continent_${cid,,}.source.tmp.info"
				printf "%s" "${name} (${iso})" >"${ipset}.tmp/country_${iso,,}.source.tmp.info"
			else
				echo >&2 "${ipset}: WARNING: geoname_id ${id} does not exist!"
			fi
		done
	)
	printf "%s" "Anonymous Service Providers" >"${ipset}.tmp/anonymous.source.tmp.info"
	printf "%s" "Satellite Service Providers" >"${ipset}.tmp/satellite.source.tmp.info"

	echo >&2 "${ipset}: Aggregating country and continent netsets..."
	local x=
	for x in ${ipset}.tmp/*.source.tmp
	do
		cat "${x}" |\
			sort -u |\
			filter_net4 |\
			aggregate4 |\
			filter_invalid4 >"${x/.source.tmp/.source}"

		touch -r "${ipset}.source" "${x/.source.tmp/.source}"
		rm "${x}"
		
		local i=${x/.source.tmp/}
		i=${i/${ipset}.tmp\//}

		local info2="`cat "${x}.info"` -- ${info}"

		finalize "${i}" "${x/.source.tmp/.source}" "${ipset}/${i}.setinfo" "${ipset}.source" "${ipset}/${i}.netset" "${mins}" "${history_mins}" "${ipv}" "${type}" "${hash}" "${url}" "${info2}"
	done

	if [ -d .git ]
	then
		# generate a setinfo for the home page
		echo >"${ipset}.setinfo" "${ipset}|[MaxMind GeoLite2](http://dev.maxmind.com/geoip/geoip2/geolite2/) databases are free IP geolocation databases comparable to, but less accurate than, MaxMind’s GeoIP2 databases. They include IPs per country, IPs per continent, IPs used by anonymous services (VPNs, Proxies, etc) and Satellite Providers.|ipv4 hash:net|All the world|updated every `mins_to_text ${mins}` from [this link](${url})"
	fi

	# remove the temporary dir
	rm -rf "${ipset}.tmp"

	return 0
}

echo >&2

# -----------------------------------------------------------------------------
# CONFIGURATION

# TEMPLATE:
#
# > update NAME TIME_TO_UPDATE ipv4|ipv6 ip|net URL CONVERTER
#
# NAME           the name of the ipset
# TIME_TO_UPDATE minutes to refresh/re-download the URL
# ipv4 or ipv6   the IP version of the ipset
# ip or net      use hash:ip or hash:net ipset
# URL            the URL to download
# CONVERTER      a command to convert the downloaded file to IP addresses

# - It creates the ipset if it does not exist
# - FireHOL will be called to update the ipset
# - both downloaded and converted files are saved in
#   ${base} (/etc/firehol/ipsets)

# RUNNING THIS SCRIPT WILL JUST INSTALL THE IPSETS.
# IT WILL NOT BLOCK OR BLACKLIST ANYTHING.
# YOU HAVE TO UPDATE YOUR firehol.conf TO BLACKLIST ANY OF THESE.
# Check: https://github.com/ktsaou/firehol/wiki/FireHOL-support-for-ipset

# EXAMPLE FOR firehol.conf:
#
# ipv4 ipset create  openbl hash:ip
#      ipset addfile openbl ipsets/openbl.ipset
#
# ipv4 ipset create  tor hash:ip
#      ipset addfile tor ipsets/tor.ipset
#
# ipv4 ipset create  compromised hash:ip
#      ipset addfile compromised ipsets/compromised.ipset
#
# ipv4 ipset create emerging_block hash:net
#      ipset addfile emerging_block ipsets/emerging_block.netset
#
# ipv4 blacklist full \
#         ipset:openbl \
#         ipset:tor \
#         ipset:emerging_block \
#         ipset:compromised \
#


# -----------------------------------------------------------------------------
# MaxMind

geolite2_country


# -----------------------------------------------------------------------------
# www.openbl.org

update openbl $[4*60] 0 ipv4 ip \
	"http://www.openbl.org/lists/base.txt.gz" \
	gz_remove_comments \
	"[OpenBL.org](http://www.openbl.org/) default blacklist (currently it is the same with 90 days). OpenBL.org is detecting, logging and reporting various types of internet abuse. Currently they monitor ports 21 (FTP), 22 (SSH), 23 (TELNET), 25 (SMTP), 110 (POP3), 143 (IMAP), 587 (Submission), 993 (IMAPS) and 995 (POP3S) for bruteforce login attacks as well as scans on ports 80 (HTTP) and 443 (HTTPS) for vulnerable installations of phpMyAdmin and other web applications - **excellent list**"

update openbl_1d $[4*60] 0 ipv4 ip \
	"http://www.openbl.org/lists/base_1days.txt.gz" \
	gz_remove_comments \
	"[OpenBL.org](http://www.openbl.org/) last 24 hours IPs.  OpenBL.org is detecting, logging and reporting various types of internet abuse. Currently they monitor ports 21 (FTP), 22 (SSH), 23 (TELNET), 25 (SMTP), 110 (POP3), 143 (IMAP), 587 (Submission), 993 (IMAPS) and 995 (POP3S) for bruteforce login attacks as well as scans on ports 80 (HTTP) and 443 (HTTPS) for vulnerable installations of phpMyAdmin and other web applications."

update openbl_7d $[4*60] 0 ipv4 ip \
	"http://www.openbl.org/lists/base_7days.txt.gz" \
	gz_remove_comments \
	"[OpenBL.org](http://www.openbl.org/) last 7 days IPs.  OpenBL.org is detecting, logging and reporting various types of internet abuse. Currently they monitor ports 21 (FTP), 22 (SSH), 23 (TELNET), 25 (SMTP), 110 (POP3), 143 (IMAP), 587 (Submission), 993 (IMAPS) and 995 (POP3S) for bruteforce login attacks as well as scans on ports 80 (HTTP) and 443 (HTTPS) for vulnerable installations of phpMyAdmin and other web applications."

update openbl_30d $[4*60] 0 ipv4 ip \
	"http://www.openbl.org/lists/base_30days.txt.gz" \
	gz_remove_comments \
	"[OpenBL.org](http://www.openbl.org/) last 30 days IPs.  OpenBL.org is detecting, logging and reporting various types of internet abuse. Currently they monitor ports 21 (FTP), 22 (SSH), 23 (TELNET), 25 (SMTP), 110 (POP3), 143 (IMAP), 587 (Submission), 993 (IMAPS) and 995 (POP3S) for bruteforce login attacks as well as scans on ports 80 (HTTP) and 443 (HTTPS) for vulnerable installations of phpMyAdmin and other web applications."

update openbl_60d $[4*60] 0 ipv4 ip \
	"http://www.openbl.org/lists/base_60days.txt.gz" \
	gz_remove_comments \
	"[OpenBL.org](http://www.openbl.org/) last 60 days IPs.  OpenBL.org is detecting, logging and reporting various types of internet abuse. Currently they monitor ports 21 (FTP), 22 (SSH), 23 (TELNET), 25 (SMTP), 110 (POP3), 143 (IMAP), 587 (Submission), 993 (IMAPS) and 995 (POP3S) for bruteforce login attacks as well as scans on ports 80 (HTTP) and 443 (HTTPS) for vulnerable installations of phpMyAdmin and other web applications."

update openbl_90d $[4*60] 0 ipv4 ip \
	"http://www.openbl.org/lists/base_90days.txt.gz" \
	gz_remove_comments \
	"[OpenBL.org](http://www.openbl.org/) last 90 days IPs.  OpenBL.org is detecting, logging and reporting various types of internet abuse. Currently they monitor ports 21 (FTP), 22 (SSH), 23 (TELNET), 25 (SMTP), 110 (POP3), 143 (IMAP), 587 (Submission), 993 (IMAPS) and 995 (POP3S) for bruteforce login attacks as well as scans on ports 80 (HTTP) and 443 (HTTPS) for vulnerable installations of phpMyAdmin and other web applications."

update openbl_180d $[4*60] 0 ipv4 ip \
	"http://www.openbl.org/lists/base_180days.txt.gz" \
	gz_remove_comments \
	"[OpenBL.org](http://www.openbl.org/) last 180 days IPs.  OpenBL.org is detecting, logging and reporting various types of internet abuse. Currently they monitor ports 21 (FTP), 22 (SSH), 23 (TELNET), 25 (SMTP), 110 (POP3), 143 (IMAP), 587 (Submission), 993 (IMAPS) and 995 (POP3S) for bruteforce login attacks as well as scans on ports 80 (HTTP) and 443 (HTTPS) for vulnerable installations of phpMyAdmin and other web applications."

update openbl_all $[4*60] 0 ipv4 ip \
	"http://www.openbl.org/lists/base_all.txt.gz" \
	gz_remove_comments \
	"[OpenBL.org](http://www.openbl.org/) last all IPs.  OpenBL.org is detecting, logging and reporting various types of internet abuse. Currently they monitor ports 21 (FTP), 22 (SSH), 23 (TELNET), 25 (SMTP), 110 (POP3), 143 (IMAP), 587 (Submission), 993 (IMAPS) and 995 (POP3S) for bruteforce login attacks as well as scans on ports 80 (HTTP) and 443 (HTTPS) for vulnerable installations of phpMyAdmin and other web applications."

# -----------------------------------------------------------------------------
# www.dshield.org
# https://www.dshield.org/xml.html

# Top 20 attackers (networks) by www.dshield.org
update dshield $[4*60] 0 ipv4 net \
	"http://feeds.dshield.org/block.txt" \
	dshield_parser \
	"[DShield.org](https://dshield.org/) top 20 attacking class C (/24) subnets over the last three days - **excellent list**"


# -----------------------------------------------------------------------------
# TOR lists
# TOR is not necessary hostile, you may need this just for sensitive services.

# https://www.dan.me.uk/tornodes
# This contains a full TOR nodelist (no more than 30 minutes old).
# The page has download limit that does not allow download in less than 30 min.
update danmetor 30 0 ipv4 ip \
	"https://www.dan.me.uk/torlist/" \
	remove_comments \
	"[dan.me.uk](https://www.dan.me.uk) dynamic list of TOR exit points"

update tor $[12*60] 0 ipv4 ip \
	"http://rules.emergingthreats.net/blockrules/emerging-tor.rules" \
	snort_alert_rules_to_ipv4 \
	"[EmergingThreats.net](http://www.emergingthreats.net/) [list](http://doc.emergingthreats.net/bin/view/Main/TorRules) of TOR network IPs"

update tor_servers 30 0 ipv4 ip \
	"https://torstatus.blutmagie.de/ip_list_all.php/Tor_ip_list_ALL.csv" \
	remove_comments \
	"[torstatus.blutmagie.de](https://torstatus.blutmagie.de) list of all TOR network servers"


# -----------------------------------------------------------------------------
# EmergingThreats

# http://doc.emergingthreats.net/bin/view/Main/CompromisedHost
# Includes: openbl, bruteforceblocker and sidreporter
update compromised $[12*60] 0 ipv4 ip \
	"http://rules.emergingthreats.net/blockrules/compromised-ips.txt" \
	remove_comments \
	"[EmergingThreats.net](http://www.emergingthreats.net/) distribution of IPs that have beed compromised (at the time of writing includes openbl, bruteforceblocker and sidreporter)"

# Command & Control botnet servers by abuse.ch
update botnet $[12*60] 0 ipv4 ip \
	"http://rules.emergingthreats.net/fwrules/emerging-PIX-CC.rules" \
	pix_deny_rules_to_ipv4 \
	"[EmergingThreats.net](http://www.emergingthreats.net/) botnet IPs (at the time of writing includes any abuse.ch trackers, which are available separately too - prefer to use the direct ipsets instead of this, they seem to lag a bit in updates)"

# This appears to be the SPAMHAUS DROP list
# disable - have direct feed
#update spamhaus $[12*60] 0 ipv4 net \
#	"http://rules.emergingthreats.net/fwrules/emerging-PIX-DROP.rules" \
#	pix_deny_rules_to_ipv4

# Top 20 attackers by www.dshield.org
# disabled - have direct feed above
#update dshield $[12*60] 0 ipv4 net \
#	"http://rules.emergingthreats.net/fwrules/emerging-PIX-DSHIELD.rules" \
#	pix_deny_rules_to_ipv4

# includes botnet, spamhaus and dshield
update emerging_block $[12*60] 0 ipv4 all \
	"http://rules.emergingthreats.net/fwrules/emerging-Block-IPs.txt" \
	remove_comments \
	"[EmergingThreats.net](http://www.emergingthreats.net/) default blacklist (at the time of writing includes spamhaus DROP, dshield and abuse.ch trackers, which are available separately too - prefer to use the direct ipsets instead of this, they seem to lag a bit in updates)"


# -----------------------------------------------------------------------------
# Spamhaus
# http://www.spamhaus.org

# http://www.spamhaus.org/drop/
# These guys say that this list should be dropped at tier-1 ISPs globaly!
update spamhaus_drop $[12*60] 0 ipv4 net \
	"http://www.spamhaus.org/drop/drop.txt" \
	remove_comments_semi_colon \
	"[Spamhaus.org](http://www.spamhaus.org) DROP list (according to their site this list should be dropped at tier-1 ISPs globaly) - **excellent list**"

# extended DROP (EDROP) list.
# Should be used together with their DROP list.
update spamhaus_edrop $[12*60] 0 ipv4 net \
	"http://www.spamhaus.org/drop/edrop.txt" \
	remove_comments_semi_colon \
	"[Spamhaus.org](http://www.spamhaus.org) EDROP (extended matches that should be used with DROP) - **excellent list**"


# -----------------------------------------------------------------------------
# blocklist.de
# http://www.blocklist.de/en/export.html

# All IP addresses that have attacked one of their servers in the
# last 48 hours. Updated every 30 minutes.
# They also have lists of service specific attacks (ssh, apache, sip, etc).
update blocklist_de 30 0 ipv4 ip \
	"http://lists.blocklist.de/lists/all.txt" \
	remove_comments \
	"[Blocklist.de](https://www.blocklist.de/) IPs that have been detected by fail2ban in the last 48 hours - **excellent list**"


# -----------------------------------------------------------------------------
# Zeus trojan
# https://zeustracker.abuse.ch/blocklist.php
# by abuse.ch

# This blocklists only includes IPv4 addresses that are used by the ZeuS trojan.
update zeus_badips 30 0 ipv4 ip \
	"https://zeustracker.abuse.ch/blocklist.php?download=badips" \
	remove_comments \
	"[Abuse.ch Zeus tracker](https://zeustracker.abuse.ch) includes IPv4 addresses that are used by the ZeuS trojan"

# This blocklist contains the same data as the ZeuS IP blocklist (BadIPs)
# but with the slight difference that it doesn't exclude hijacked websites
# (level 2) and free web hosting providers (level 3).
update zeus 30 0 ipv4 ip \
	"https://zeustracker.abuse.ch/blocklist.php?download=ipblocklist" \
	remove_comments \
	"[Abuse.ch Zeus tracker](https://zeustracker.abuse.ch) default blocklist including hijacked sites and web hosting providers - **excellent list**"

# -----------------------------------------------------------------------------
# Palevo worm
# https://palevotracker.abuse.ch/blocklists.php
# by abuse.ch

# includes IP addresses which are being used as botnet C&C for the Palevo crimeware
update palevo 30 0 ipv4 ip \
	"https://palevotracker.abuse.ch/blocklists.php?download=ipblocklist" \
	remove_comments \
	"[Abuse.ch Palevo tracker](https://palevotracker.abuse.ch) worm includes IPs which are being used as botnet C&C for the Palevo crimeware - **excellent list**"

# -----------------------------------------------------------------------------
# Feodo trojan
# https://feodotracker.abuse.ch/blocklist/
# by abuse.ch

# Feodo (also known as Cridex or Bugat) is a Trojan used to commit ebanking fraud
# and steal sensitive information from the victims computer, such as credit card
# details or credentials.
update feodo 30 0 ipv4 ip \
	"https://feodotracker.abuse.ch/blocklist/?download=ipblocklist" \
	remove_comments \
	"[Abuse.ch Feodo tracker](https://feodotracker.abuse.ch) trojan includes IPs which are being used by Feodo (also known as Cridex or Bugat) which commits ebanking fraud - **excellent list**"


# -----------------------------------------------------------------------------
# SSLBL
# https://sslbl.abuse.ch/
# by abuse.ch

# IPs with "bad" SSL certificates identified by abuse.ch to be associated with malware or botnet activities
update sslbl 30 0 ipv4 ip \
	"https://sslbl.abuse.ch/blacklist/sslipblacklist.csv" \
	csv_comma_first_column \
	"[Abuse.ch SSL Blacklist](https://sslbl.abuse.ch/) bad SSL traffic related to malware or botnet activities - **excellent list**"


# -----------------------------------------------------------------------------
# infiltrated.net
# http://www.infiltrated.net/blacklisted

update infiltrated $[12*60] 0 ipv4 ip \
	"http://www.infiltrated.net/blacklisted" \
	remove_comments \
	"[infiltrated.net](http://www.infiltrated.net) (this list seems to be updated frequently, but we found no information about it)"


# -----------------------------------------------------------------------------
# malc0de
# http://malc0de.com

# updated daily and populated with the last 30 days of malicious IP addresses.
update malc0de $[24*60] 0 ipv4 ip \
	"http://malc0de.com/bl/IP_Blacklist.txt" \
	remove_comments \
	"[Malc0de.com](http://malc0de.com) malicious IPs of the last 30 days"


# -----------------------------------------------------------------------------
# Stop Forum Spam
# http://www.stopforumspam.com/downloads/

# to use this, create the ipset like this (in firehol.conf):
# >> ipset4 create stop_forum_spam hash:ip maxelem 500000
# -- normally, you don't need this set --
# -- use the hourly and the daily ones instead --
# IMPORTANT: THIS IS A BIG LIST - you will have to add maxelem to ipset to fit it
update stop_forum_spam $[24*60] 0 ipv4 ip \
	"http://www.stopforumspam.com/downloads/bannedips.zip" \
	unzip_and_split_csv \
	"[StopForumSpam.com](http://www.stopforumspam.com) all IPs used by forum spammers"

# hourly update with IPs from the last 24 hours
update stop_forum_spam_1h 60 0 ipv4 ip \
	"http://www.stopforumspam.com/downloads/listed_ip_1.zip" \
	unzip_and_extract \
	"[StopForumSpam.com](http://www.stopforumspam.com) IPs used by forum spammers in the last 24 hours - **excellent list**"

# daily update with IPs from the last 7 days
update stop_forum_spam_7d $[24*60] 0 ipv4 ip \
	"http://www.stopforumspam.com/downloads/listed_ip_7.zip" \
	unzip_and_extract \
	"[StopForumSpam.com](http://www.stopforumspam.com) IPs used by forum spammers (last 7 days)"

# daily update with IPs from the last 30 days
update stop_forum_spam_30d $[24*60] 0 ipv4 ip \
	"http://www.stopforumspam.com/downloads/listed_ip_30.zip" \
	unzip_and_extract \
	"[StopForumSpam.com](http://www.stopforumspam.com) IPs used by forum spammers (last 30 days)"


# daily update with IPs from the last 90 days
# you will have to add maxelem to ipset to fit it
update stop_forum_spam_90d $[24*60] 0 ipv4 ip \
	"http://www.stopforumspam.com/downloads/listed_ip_90.zip" \
	unzip_and_extract \
	"[StopForumSpam.com](http://www.stopforumspam.com) IPs used by forum spammers (last 90 days)"


# daily update with IPs from the last 180 days
# you will have to add maxelem to ipset to fit it
update stop_forum_spam_180d $[24*60] 0 ipv4 ip \
	"http://www.stopforumspam.com/downloads/listed_ip_180.zip" \
	unzip_and_extract \
	"[StopForumSpam.com](http://www.stopforumspam.com) IPs used by forum spammers (last 180 days)"


# daily update with IPs from the last 365 days
# you will have to add maxelem to ipset to fit it
update stop_forum_spam_365d $[24*60] 0 ipv4 ip \
	"http://www.stopforumspam.com/downloads/listed_ip_365.zip" \
	unzip_and_extract \
	"[StopForumSpam.com](http://www.stopforumspam.com) IPs used by forum spammers (last 365 days)"


# -----------------------------------------------------------------------------
# Bogons
# Bogons are IP addresses that should not be routed because they are not
# allocated, or they are allocated for private use.
# IMPORTANT: THESE LISTS INCLUDE ${PRIVATE_IPS}
#            always specify an 'inface' when blacklisting in FireHOL

# http://www.team-cymru.org/bogon-reference.html
# private and reserved addresses defined by RFC 1918, RFC 5735, and RFC 6598
# and netblocks that have not been allocated to a regional internet registry
# (RIR) by the Internet Assigned Numbers Authority.
update bogons $[24*60] 0 ipv4 net \
	"http://www.team-cymru.org/Services/Bogons/bogon-bn-agg.txt" \
	remove_comments \
	"[Team-Cymru.org](http://www.team-cymru.org) private and reserved addresses defined by RFC 1918, RFC 5735, and RFC 6598 and netblocks that have not been allocated to a regional internet registry - **excellent list - use it only your internet interface**"


# http://www.team-cymru.org/bogon-reference.html
# Fullbogons are a larger set which also includes IP space that has been
# allocated to an RIR, but not assigned by that RIR to an actual ISP or other
# end-user.
update fullbogons $[24*60] 0 ipv4 net \
	"http://www.team-cymru.org/Services/Bogons/fullbogons-ipv4.txt" \
	remove_comments \
	"[Team-Cymru.org](http://www.team-cymru.org) IP space that has been allocated to an RIR, but not assigned by that RIR to an actual ISP or other end-user - **excellent list - use it only your internet interface**"

#update fullbogons6 $[24*60-10] ipv6 net \
#	"http://www.team-cymru.org/Services/Bogons/fullbogons-ipv6.txt" \
#	remove_comments \
#	"Team-Cymru.org provided"


# -----------------------------------------------------------------------------
# Open Proxies from rosinstruments
# http://tools.rosinstrument.com/proxy/

update rosi_web_proxies 60 $[30*24*60] ipv4 ip \
	"http://tools.rosinstrument.com/proxy/l100.xml" \
	parse_rss_rosinstrument \
	"[rosinstrument.com](http://www.rosinstrument.com) open HTTP proxies (this list is composed using an RSS feed and aggregated for the last 30 days)"

update rosi_connect_proxies 60 $[30*24*60] ipv4 ip \
	"http://tools.rosinstrument.com/proxy/plab100.xml" \
	parse_rss_rosinstrument \
	"[rosinstrument.com](http://www.rosinstrument.com) open CONNECT proxies (this list is composed using an RSS feed and aggregated for the last 30 days)"


# -----------------------------------------------------------------------------
# Project Honey Pot
# http://www.projecthoneypot.org/

update php_harvesters 60 $[30*24*60] ipv4 ip \
	"http://www.projecthoneypot.org/list_of_ips.php?t=h&rss=1" \
	parse_php_rss \
	"[projecthoneypot.org](http://www.projecthoneypot.org/) harvesters (IPs that surf the internet looking for email addresses) (this list is composed using an RSS feed and aggregated for the last 30 days)"

update php_spammers 60 $[30*24*60] ipv4 ip \
	"http://www.projecthoneypot.org/list_of_ips.php?t=s&rss=1" \
	parse_php_rss \
	"[projecthoneypot.org](http://www.projecthoneypot.org/) spam servers (IPs used by spammers to send messages) (this list is composed using an RSS feed and aggregated for the last 30 days)"

update php_bad 60 $[30*24*60] ipv4 ip \
	"http://www.projecthoneypot.org/list_of_ips.php?t=b&rss=1" \
	parse_php_rss \
	"[projecthoneypot.org](http://www.projecthoneypot.org/) bad web hosts (this list is composed using an RSS feed and aggregated for the last 30 days)"

update php_commenters 60 $[30*24*60] ipv4 ip \
	"http://www.projecthoneypot.org/list_of_ips.php?t=c&rss=1" \
	parse_php_rss \
	"[projecthoneypot.org](http://www.projecthoneypot.org/) comment spammers (this list is composed using an RSS feed and aggregated for the last 30 days)"

update php_dictionary 60 $[30*24*60] ipv4 ip \
	"http://www.projecthoneypot.org/list_of_ips.php?t=d&rss=1" \
	parse_php_rss \
	"[projecthoneypot.org](http://www.projecthoneypot.org/) directory attackers (this list is composed using an RSS feed and aggregated for the last 30 days)"


# -----------------------------------------------------------------------------
# Malware Domain List
# All IPs should be considered dangerous

update malwaredomainlist $[12*60] 0 ipv4 ip \
	"http://www.malwaredomainlist.com/hostslist/ip.txt" \
	remove_comments \
	"[malwaredomainlist.com](http://www.malwaredomainlist.com) list of malware active ip addresses"


# -----------------------------------------------------------------------------
# Alien Vault
# Alienvault IP Reputation Database

# IMPORTANT: THIS IS A BIG LIST
# you will have to add maxelem to ipset to fit it
update alienvault_reputation $[6*60] 0 ipv4 ip \
	"https://reputation.alienvault.com/reputation.generic" \
	remove_comments \
	"[AlienVault.com](https://www.alienvault.com/) IP reputation database (this list seems to include port scanning hosts and to be updated regularly, but we found no information about its retention policy)"


# -----------------------------------------------------------------------------
# Clean-MX
# Viruses

update clean_mx_viruses $[12*60] 0 ipv4 ip \
	"http://support.clean-mx.de/clean-mx/xmlviruses.php?sort=id%20desc&response=alive" \
	parse_xml_clean_mx \
	"[Clean-MX.de](http://support.clean-mx.de/clean-mx/viruses.php) IPs with viruses"


# -----------------------------------------------------------------------------
# CI Army
# http://ciarmy.com/

# The CI Army list is a subset of the CINS Active Threat Intelligence ruleset,
# and consists of IP addresses that meet two basic criteria:
# 1) The IP's recent Rogue Packet score factor is very poor, and
# 2) The InfoSec community has not yet identified the IP as malicious.
# We think this second factor is important: We don't want to waste peoples'
# time listing thousands of IPs that have already been placed on other reputation
# lists; our list is meant to supplement and enhance the InfoSec community's
# existing efforts by providing IPs that haven't been identified yet.
update ciarmy $[3*60] 0 ipv4 ip \
	"http://cinsscore.com/list/ci-badguys.txt" \
	remove_comments \
	"[CIArmy.com](http://ciarmy.com/) IPs with poor Rogue Packet score that have not yet been identified as malicious by the community"


# -----------------------------------------------------------------------------
# Bruteforce Blocker
# http://danger.rulez.sk/projects/bruteforceblocker/

update bruteforceblocker $[3*60] 0 ipv4 ip \
	"http://danger.rulez.sk/projects/bruteforceblocker/blist.php" \
	remove_comments \
	"[danger.rulez.sk](http://danger.rulez.sk/) IPs detected by [bruteforceblocker](http://danger.rulez.sk/index.php/bruteforceblocker/) (fail2ban alternative for SSH on OpenBSD)"


# -----------------------------------------------------------------------------
# Snort ipfilter
# http://labs.snort.org/feeds/ip-filter.blf

update snort_ipfilter $[12*60] 0 ipv4 ip \
	"http://labs.snort.org/feeds/ip-filter.blf" \
	remove_comments \
	"[labs.snort.org](https://labs.snort.org/) supplied IP blacklist (this list seems to be updated frequently, but we found no information about it)"


# -----------------------------------------------------------------------------
# NiX Spam
# http://www.heise.de/ix/NiX-Spam-DNSBL-and-blacklist-for-download-499637.html

update nixspam 15 0 ipv4 ip \
	"http://www.dnsbl.manitu.net/download/nixspam-ip.dump.gz" \
	gz_second_word \
	"[NiX Spam](http://www.heise.de/ix/NiX-Spam-DNSBL-and-blacklist-for-download-499637.html) IP addresses that sent spam in the last hour - automatically generated entries without distinguishing open proxies from relays, dialup gateways, and so on. All IPs are removed after 12 hours if there is no spam from there."


# -----------------------------------------------------------------------------
# AutoShun.org
# http://www.autoshun.org/

update autoshun $[4*60] 0 ipv4 ip \
	"http://www.autoshun.org/files/shunlist.csv" \
	csv_comma_first_column \
	"[AutoShun.org](http://autoshun.org/) IPs identified as hostile by correlating logs from distributed snort installations running the autoshun plugin"


# -----------------------------------------------------------------------------
# VoIPBL.org
# http://www.voipbl.org/

update voipbl $[4*60] 0 ipv4 net \
	"http://www.voipbl.org/update/" \
	remove_comments \
	"[VoIPBL.org](http://www.voipbl.org/) VoIPBL is a distributed VoIP blacklist that is aimed to protects against VoIP Fraud and minimizing abuse for network that have publicly accessible PBX's. Several algorithms, external sources and manual confirmation are used before they categorize something as an attack and determine the threat level."


# -----------------------------------------------------------------------------
# iBlocklist
# https://www.iblocklist.com/lists.php
# http://bluetack.co.uk/forums/index.php?autocom=faq&CODE=02&qid=17

if [ ${CAN_CONVERT_RANGES_TO_CIDR} -eq 1 ]
then
	# open proxies and tor
	# we only keep the proxies IPs (tor IPs are not parsed)
	update ib_bluetack_proxies $[12*60] 0 ipv4 ip \
		"http://list.iblocklist.com/?list=xoebmbyexwuiogmbyprb&fileformat=p2p&archiveformat=gz" \
		p2p_gz_proxy \
		"[iBlocklist.com](https://www.iblocklist.com/) free version of [BlueTack.co.uk](http://www.bluetack.co.uk/) Open Proxies IPs list (without TOR)"


	# This list is a compilation of known malicious SPYWARE and ADWARE IP Address ranges. 
	# It is compiled from various sources, including other available Spyware Blacklists,
	# HOSTS files, from research found at many of the top Anti-Spyware forums, logs of
	# Spyware victims and also from the Malware Research Section here at Bluetack. 
	update ib_bluetack_spyware $[12*60] 0 ipv4 net \
		"http://list.iblocklist.com/?list=llvtlsjyoyiczbkjsxpf&fileformat=p2p&archiveformat=gz" \
		p2p_gz \
		"[iBlocklist.com](https://www.iblocklist.com/) free version of [BlueTack.co.uk](http://www.bluetack.co.uk/) known malicious SPYWARE and ADWARE IP Address ranges"


	# List of people who have been reported for bad deeds in p2p.
	update ib_bluetack_badpeers $[12*60] 0 ipv4 ip \
		"http://list.iblocklist.com/?list=cwworuawihqvocglcoss&fileformat=p2p&archiveformat=gz" \
		p2p_gz \
		"[iBlocklist.com](https://www.iblocklist.com/) free version of [BlueTack.co.uk](http://www.bluetack.co.uk/) IPs that have been reported for bad deeds in p2p"


	# Contains hijacked IP-Blocks and known IP-Blocks that are used to deliver Spam. 
	# This list is a combination of lists with hijacked IP-Blocks 
	# Hijacked IP space are IP blocks that are being used without permission by
	# organizations that have no relation to original organization (or its legal
	# successor) that received the IP block. In essence it's stealing of somebody
	# else's IP resources
	update ib_bluetack_hijacked $[12*60] 0 ipv4 net \
		"http://list.iblocklist.com/?list=usrcshglbiilevmyfhse&fileformat=p2p&archiveformat=gz" \
		p2p_gz \
		"[iBlocklist.com](https://www.iblocklist.com/) free version of [BlueTack.co.uk](http://www.bluetack.co.uk/) hijacked IP-Blocks Hijacked IP space are IP blocks that are being used without permission"


	# IP addresses related to current web server hack and exploit attempts that have been
	# logged by us or can be found in and cross referenced with other related IP databases.
	# Malicious and other non search engine bots will also be listed here, along with anything
	# we find that can have a negative impact on a website or webserver such as proxies being
	# used for negative SEO hijacks, unauthorised site mirroring, harvesting, scraping,
	# snooping and data mining / spy bot / security & copyright enforcement companies that
	# target and continuosly scan webservers.
	update ib_bluetack_webexploit $[12*60] 0 ipv4 ip \
		"http://list.iblocklist.com/?list=ghlzqtqxnzctvvajwwag&fileformat=p2p&archiveformat=gz" \
		p2p_gz \
		"[iBlocklist.com](https://www.iblocklist.com/) free version of [BlueTack.co.uk](http://www.bluetack.co.uk/) web server hack and exploit attempts"


	# Companies or organizations who are clearly involved with trying to stop filesharing
	# (e.g. Baytsp, MediaDefender, Mediasentry a.o.). 
	# Companies which anti-p2p activity has been seen from. 
	# Companies that produce or have a strong financial interest in copyrighted material
	# (e.g. music, movie, software industries a.o.). 
	# Government ranges or companies that have a strong financial interest in doing work
	# for governments. 
	# Legal industry ranges. 
	# IPs or ranges of ISPs from which anti-p2p activity has been observed. Basically this
	# list will block all kinds of internet connections that most people would rather not
	# have during their internet travels. 
	# PLEASE NOTE: The Level1 list is recommended for general P2P users, but it all comes
	# down to your personal choice. 
	# IMPORTANT: THIS IS A BIG LIST
	update ib_bluetack_level1 $[12*60] 0 ipv4 net \
		"http://list.iblocklist.com/?list=ydxerpxkpcfqjaybcssw&fileformat=p2p&archiveformat=gz" \
		p2p_gz \
		"[iBlocklist.com](https://www.iblocklist.com/) free version of [BlueTack.co.uk](http://www.bluetack.co.uk/) Level 1 (for use in p2p): Companies or organizations who are clearly involved with trying to stop filesharing (e.g. Baytsp, MediaDefender, Mediasentry a.o.). Companies which anti-p2p activity has been seen from. Companies that produce or have a strong financial interest in copyrighted material (e.g. music, movie, software industries a.o.). Government ranges or companies that have a strong financial interest in doing work for governments. Legal industry ranges. IPs or ranges of ISPs from which anti-p2p activity has been observed. Basically this list will block all kinds of internet connections that most people would rather not have during their internet travels."


	# General corporate ranges. 
	# Ranges used by labs or researchers. 
	# Proxies. 
	update ib_bluetack_level2 $[12*60] 0 ipv4 net \
		"http://list.iblocklist.com/?list=gyisgnzbhppbvsphucsw&fileformat=p2p&archiveformat=gz" \
		p2p_gz \
		"[iBlocklist.com](https://www.iblocklist.com/) free version of BlueTack.co.uk Level 2 (for use in p2p). General corporate ranges. Ranges used by labs or researchers. Proxies."


	# Many portal-type websites. 
	# ISP ranges that may be dodgy for some reason. 
	# Ranges that belong to an individual, but which have not been determined to be used by a particular company. 
	# Ranges for things that are unusual in some way. The L3 list is aka the paranoid list.
	update ib_bluetack_level3 $[12*60] 0 ipv4 net \
		"http://list.iblocklist.com/?list=uwnukjqktoggdknzrhgh&fileformat=p2p&archiveformat=gz" \
		p2p_gz \
		"[iBlocklist.com](https://www.iblocklist.com/) free version of BlueTack.co.uk Level 3 (for use in p2p). Many portal-type websites. ISP ranges that may be dodgy for some reason. Ranges that belong to an individual, but which have not been determined to be used by a particular company. Ranges for things that are unusual in some way. The L3 list is aka the paranoid list."

fi


# to add
# http://www.nothink.org/blacklist/blacklist_ssh_week.txt
# http://www.nothink.org/blacklist/blacklist_malware_irc.txt
# http://www.nothink.org/blacklist/blacklist_malware_http.txt
