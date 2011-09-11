#!/bin/bash
# Copyright 1999-2011 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2

PORTAGE_BIN_PATH="${PORTAGE_BIN_PATH:-/usr/lib/portage/bin}"
PORTAGE_PYM_PATH="${PORTAGE_PYM_PATH:-/usr/lib/portage/pym}"

if [[ $PORTAGE_SANDBOX_COMPAT_LEVEL -lt 22 ]] ; then
	# Ensure that /dev/std* streams have appropriate sandbox permission for
	# bug #288863. This can be removed after sandbox is fixed and portage
	# depends on the fixed version (sandbox-2.2 has the fix but it is
	# currently unstable).
	export SANDBOX_WRITE="${SANDBOX_WRITE:+${SANDBOX_WRITE}:}/dev/stdout:/dev/stderr"
	export SANDBOX_READ="${SANDBOX_READ:+${SANDBOX_READ}:}/dev/stdin"
fi

# Don't use sandbox's BASH_ENV for new shells because it does
# 'source /etc/profile' which can interfere with the build
# environment by modifying our PATH.
unset BASH_ENV

ROOTPATH=${ROOTPATH##:}
ROOTPATH=${ROOTPATH%%:}
PREROOTPATH=${PREROOTPATH##:}
PREROOTPATH=${PREROOTPATH%%:}
PATH=$PORTAGE_BIN_PATH/ebuild-helpers:$PREROOTPATH${PREROOTPATH:+:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${ROOTPATH:+:}$ROOTPATH
export PATH

# This is just a temporary workaround for portage-9999 users since
# earlier portage versions do not detect a version change in this case
# (9999 to 9999) and therefore they try execute an incompatible version of
# ebuild.sh during the upgrade.
export PORTAGE_BZIP2_COMMAND=${PORTAGE_BZIP2_COMMAND:-bzip2} 

# These two functions wrap sourcing and calling respectively.  At present they
# perform a qa check to make sure eclasses and ebuilds and profiles don't mess
# with shell opts (shopts).  Ebuilds/eclasses changing shopts should reset them 
# when they are done.

qa_source() {
	local shopts=$(shopt) OLDIFS="$IFS"
	local retval
	source "$@"
	retval=$?
	set +e
	[[ $shopts != $(shopt) ]] &&
		eqawarn "QA Notice: Global shell options changed and were not restored while sourcing '$*'"
	[[ "$IFS" != "$OLDIFS" ]] &&
		eqawarn "QA Notice: Global IFS changed and was not restored while sourcing '$*'"
	return $retval
}

qa_call() {
	local shopts=$(shopt) OLDIFS="$IFS"
	local retval
	"$@"
	retval=$?
	set +e
	[[ $shopts != $(shopt) ]] &&
		eqawarn "QA Notice: Global shell options changed and were not restored while calling '$*'"
	[[ "$IFS" != "$OLDIFS" ]] &&
		eqawarn "QA Notice: Global IFS changed and was not restored while calling '$*'"
	return $retval
}

EBUILD_SH_ARGS="$*"

shift $#

# Prevent aliases from causing portage to act inappropriately.
# Make sure it's before everything so we don't mess aliases that follow.
unalias -a

# Unset some variables that break things.
unset GZIP BZIP BZIP2 CDPATH GREP_OPTIONS GREP_COLOR GLOBIGNORE

source "${PORTAGE_BIN_PATH}/isolated-functions.sh"  &>/dev/null

[[ $PORTAGE_QUIET != "" ]] && export PORTAGE_QUIET

# sandbox support functions; defined prior to profile.bashrc srcing, since the profile might need to add a default exception (/usr/lib64/conftest fex)
_sb_append_var() {
	local _v=$1 ; shift
	local var="SANDBOX_${_v}"
	[[ -z $1 || -n $2 ]] && die "Usage: add$(echo ${_v} | \
		LC_ALL=C tr [:upper:] [:lower:]) <colon-delimited list of paths>"
	export ${var}="${!var:+${!var}:}$1"
}
# bash-4 version:
# local var="SANDBOX_${1^^}"
# addread() { _sb_append_var ${0#add} "$@" ; }
addread()    { _sb_append_var READ    "$@" ; }
addwrite()   { _sb_append_var WRITE   "$@" ; }
adddeny()    { _sb_append_var DENY    "$@" ; }
addpredict() { _sb_append_var PREDICT "$@" ; }

addwrite "${PORTAGE_TMPDIR}"
addread "/:${PORTAGE_TMPDIR}"
[[ -n ${PORTAGE_GPG_DIR} ]] && addpredict "${PORTAGE_GPG_DIR}"

# Avoid sandbox violations in temporary directories.
if [[ -w $T ]] ; then
	export TEMP=$T
	export TMP=$T
	export TMPDIR=$T
elif [[ $SANDBOX_ON = 1 ]] ; then
	for x in TEMP TMP TMPDIR ; do
		[[ -n ${!x} ]] && addwrite "${!x}"
	done
	unset x
fi

# the sandbox is disabled by default except when overridden in the relevant stages
export SANDBOX_ON=0

lchown() {
	chown -h "$@"
}

lchgrp() {
	chgrp -h "$@"
}

esyslog() {
	# Custom version of esyslog() to take care of the "Red Star" bug.
	# MUST follow functions.sh to override the "" parameter problem.
	return 0
}

# Return true if given package is installed. Otherwise return false.
# Takes single depend-type atoms.
has_version() {
	if [ "${EBUILD_PHASE}" == "depend" ]; then
		die "portageq calls (has_version calls portageq) are not allowed in the global scope"
	fi

	if [[ -n $PORTAGE_IPC_DAEMON ]] ; then
		"$PORTAGE_BIN_PATH"/ebuild-ipc has_version "$ROOT" "$1"
	else
		PYTHONPATH=${PORTAGE_PYM_PATH}${PYTHONPATH:+:}${PYTHONPATH} \
		"${PORTAGE_PYTHON:-/usr/bin/python}" "${PORTAGE_BIN_PATH}/portageq" has_version "${ROOT}" "$1"
	fi
	local retval=$?
	case "${retval}" in
		0|1)
			return ${retval}
			;;
		*)
			die "unexpected portageq exit code: ${retval}"
			;;
	esac
}

portageq() {
	if [ "${EBUILD_PHASE}" == "depend" ]; then
		die "portageq calls are not allowed in the global scope"
	fi

	PYTHONPATH=${PORTAGE_PYM_PATH}${PYTHONPATH:+:}${PYTHONPATH} \
	"${PORTAGE_PYTHON:-/usr/bin/python}" "${PORTAGE_BIN_PATH}/portageq" "$@"
}


# ----------------------------------------------------------------------------
# ----------------------------------------------------------------------------
# ----------------------------------------------------------------------------


# Returns the best/most-current match.
# Takes single depend-type atoms.
best_version() {
	if [ "${EBUILD_PHASE}" == "depend" ]; then
		die "portageq calls (best_version calls portageq) are not allowed in the global scope"
	fi

	if [[ -n $PORTAGE_IPC_DAEMON ]] ; then
		"$PORTAGE_BIN_PATH"/ebuild-ipc best_version "$ROOT" "$1"
	else
		PYTHONPATH=${PORTAGE_PYM_PATH}${PYTHONPATH:+:}${PYTHONPATH} \
		"${PORTAGE_PYTHON:-/usr/bin/python}" "${PORTAGE_BIN_PATH}/portageq" 'best_version' "${ROOT}" "$1"
	fi
	local retval=$?
	case "${retval}" in
		0|1)
			return ${retval}
			;;
		*)
			die "unexpected portageq exit code: ${retval}"
			;;
	esac
}

register_die_hook() {
	local x
	for x in $* ; do
		has $x $EBUILD_DEATH_HOOKS || \
			export EBUILD_DEATH_HOOKS="$EBUILD_DEATH_HOOKS $x"
	done
}

register_success_hook() {
	local x
	for x in $* ; do
		has $x $EBUILD_SUCCESS_HOOKS || \
			export EBUILD_SUCCESS_HOOKS="$EBUILD_SUCCESS_HOOKS $x"
	done
}

# Ensure that $PWD is sane whenever possible, to protect against
# exploitation of insecure search path for python -c in ebuilds.
# See bug #239560.
if ! has "$EBUILD_PHASE" clean cleanrm depend help ; then
	cd "$PORTAGE_BUILDDIR" || \
		die "PORTAGE_BUILDDIR does not exist: '$PORTAGE_BUILDDIR'"
fi

#if no perms are specified, dirs/files will have decent defaults
#(not secretive, but not stupid)
umask 022

strip_duplicate_slashes() {
	if [[ -n $1 ]] ; then
		local removed=$1
		while [[ ${removed} == *//* ]] ; do
			removed=${removed//\/\///}
		done
		echo ${removed}
	fi
}

hasg() {
    local x s=$1
    shift
    for x ; do [[ ${x} == ${s} ]] && echo "${x}" && return 0 ; done
    return 1
}
hasgq() { hasg "$@" >/dev/null ; }

# debug-print() gets called from many places with verbose status information useful
# for tracking down problems. The output is in $T/eclass-debug.log.
# You can set ECLASS_DEBUG_OUTPUT to redirect the output somewhere else as well.
# The special "on" setting echoes the information, mixing it with the rest of the
# emerge output.
# You can override the setting by exporting a new one from the console, or you can
# set a new default in make.*. Here the default is "" or unset.

# in the future might use e* from /etc/init.d/functions.sh if i feel like it
debug-print() {
	# if $T isn't defined, we're in dep calculation mode and
	# shouldn't do anything
	[[ $EBUILD_PHASE = depend || ! -d ${T} || ${#} -eq 0 ]] && return 0

	if [[ ${ECLASS_DEBUG_OUTPUT} == on ]]; then
		printf 'debug: %s\n' "${@}" >&2
	elif [[ -n ${ECLASS_DEBUG_OUTPUT} ]]; then
		printf 'debug: %s\n' "${@}" >> "${ECLASS_DEBUG_OUTPUT}"
	fi

	if [[ -w $T ]] ; then
		# default target
		printf '%s\n' "${@}" >> "${T}/eclass-debug.log"
		# let the portage user own/write to this file
		chgrp portage "${T}/eclass-debug.log" &>/dev/null
		chmod g+w "${T}/eclass-debug.log" &>/dev/null
	fi
}

# The following 2 functions are debug-print() wrappers

debug-print-function() {
	debug-print "${1}: entering function, parameters: ${*:2}"
}

debug-print-section() {
	debug-print "now in section ${*}"
}

# Sources all eclasses in parameters
declare -ix ECLASS_DEPTH=0
inherit() {
	ECLASS_DEPTH=$(($ECLASS_DEPTH + 1))
	if [[ ${ECLASS_DEPTH} > 1 ]]; then
		debug-print "*** Multiple Inheritence (Level: ${ECLASS_DEPTH})"
	fi

	if [[ -n $ECLASS && -n ${!__export_funcs_var} ]] ; then
		echo "QA Notice: EXPORT_FUNCTIONS is called before inherit in" \
			"$ECLASS.eclass. For compatibility with <=portage-2.1.6.7," \
			"only call EXPORT_FUNCTIONS after inherit(s)." \
			| fmt -w 75 | while read -r ; do eqawarn "$REPLY" ; done
	fi

	local location
	local olocation
	local x

	# These variables must be restored before returning.
	local PECLASS=$ECLASS
	local prev_export_funcs_var=$__export_funcs_var

	local B_IUSE
	local B_REQUIRED_USE
	local B_DEPEND
	local B_RDEPEND
	local B_PDEPEND
	while [ "$1" ]; do
		location="${ECLASSDIR}/${1}.eclass"
		olocation=""

		export ECLASS="$1"
		__export_funcs_var=__export_functions_$ECLASS_DEPTH
		unset $__export_funcs_var

		if [ "${EBUILD_PHASE}" != "depend" ] && \
			[[ ${EBUILD_PHASE} != *rm ]] && \
			[[ ${EMERGE_FROM} != "binary" ]] ; then
			# This is disabled in the *rm phases because they frequently give
			# false alarms due to INHERITED in /var/db/pkg being outdated
			# in comparison the the eclasses from the portage tree.
			if ! has $ECLASS $INHERITED $__INHERITED_QA_CACHE ; then
				eqawarn "QA Notice: ECLASS '$ECLASS' inherited illegally in $CATEGORY/$PF $EBUILD_PHASE"
			fi
		fi

		# any future resolution code goes here
		if [ -n "$PORTDIR_OVERLAY" ]; then
			local overlay
			for overlay in ${PORTDIR_OVERLAY}; do
				olocation="${overlay}/eclass/${1}.eclass"
				if [ -e "$olocation" ]; then
					location="${olocation}"
					debug-print "  eclass exists: ${location}"
				fi
			done
		fi
		debug-print "inherit: $1 -> $location"
		[ ! -e "$location" ] && die "${1}.eclass could not be found by inherit()"

		if [ "${location}" == "${olocation}" ] && \
			! has "${location}" ${EBUILD_OVERLAY_ECLASSES} ; then
				EBUILD_OVERLAY_ECLASSES="${EBUILD_OVERLAY_ECLASSES} ${location}"
		fi

		#We need to back up the value of DEPEND and RDEPEND to B_DEPEND and B_RDEPEND
		#(if set).. and then restore them after the inherit call.

		#turn off glob expansion
		set -f

		# Retain the old data and restore it later.
		unset B_IUSE B_REQUIRED_USE B_DEPEND B_RDEPEND B_PDEPEND
		[ "${IUSE+set}"       = set ] && B_IUSE="${IUSE}"
		[ "${REQUIRED_USE+set}" = set ] && B_REQUIRED_USE="${REQUIRED_USE}"
		[ "${DEPEND+set}"     = set ] && B_DEPEND="${DEPEND}"
		[ "${RDEPEND+set}"    = set ] && B_RDEPEND="${RDEPEND}"
		[ "${PDEPEND+set}"    = set ] && B_PDEPEND="${PDEPEND}"
		unset IUSE REQUIRED_USE DEPEND RDEPEND PDEPEND
		#turn on glob expansion
		set +f

		qa_source "$location" || die "died sourcing $location in inherit()"
		
		#turn off glob expansion
		set -f

		# If each var has a value, append it to the global variable E_* to
		# be applied after everything is finished. New incremental behavior.
		[ "${IUSE+set}"       = set ] && export E_IUSE="${E_IUSE} ${IUSE}"
		[ "${REQUIRED_USE+set}"       = set ] && export E_REQUIRED_USE="${E_REQUIRED_USE} ${REQUIRED_USE}"
		[ "${DEPEND+set}"     = set ] && export E_DEPEND="${E_DEPEND} ${DEPEND}"
		[ "${RDEPEND+set}"    = set ] && export E_RDEPEND="${E_RDEPEND} ${RDEPEND}"
		[ "${PDEPEND+set}"    = set ] && export E_PDEPEND="${E_PDEPEND} ${PDEPEND}"

		[ "${B_IUSE+set}"     = set ] && IUSE="${B_IUSE}"
		[ "${B_IUSE+set}"     = set ] || unset IUSE
		
		[ "${B_REQUIRED_USE+set}"     = set ] && REQUIRED_USE="${B_REQUIRED_USE}"
		[ "${B_REQUIRED_USE+set}"     = set ] || unset REQUIRED_USE

		[ "${B_DEPEND+set}"   = set ] && DEPEND="${B_DEPEND}"
		[ "${B_DEPEND+set}"   = set ] || unset DEPEND

		[ "${B_RDEPEND+set}"  = set ] && RDEPEND="${B_RDEPEND}"
		[ "${B_RDEPEND+set}"  = set ] || unset RDEPEND

		[ "${B_PDEPEND+set}"  = set ] && PDEPEND="${B_PDEPEND}"
		[ "${B_PDEPEND+set}"  = set ] || unset PDEPEND

		#turn on glob expansion
		set +f

		if [[ -n ${!__export_funcs_var} ]] ; then
			for x in ${!__export_funcs_var} ; do
				debug-print "EXPORT_FUNCTIONS: $x -> ${ECLASS}_$x"
				declare -F "${ECLASS}_$x" >/dev/null || \
					die "EXPORT_FUNCTIONS: ${ECLASS}_$x is not defined"
				eval "$x() { ${ECLASS}_$x \"\$@\" ; }" > /dev/null
			done
		fi
		unset $__export_funcs_var

		has $1 $INHERITED || export INHERITED="$INHERITED $1"

		shift
	done
	((--ECLASS_DEPTH)) # Returns 1 when ECLASS_DEPTH reaches 0.
	if (( ECLASS_DEPTH > 0 )) ; then
		export ECLASS=$PECLASS
		__export_funcs_var=$prev_export_funcs_var
	else
		unset ECLASS __export_funcs_var
	fi
	return 0
}

# Exports stub functions that call the eclass's functions, thereby making them default.
# For example, if ECLASS="base" and you call "EXPORT_FUNCTIONS src_unpack", the following
# code will be eval'd:
# src_unpack() { base_src_unpack; }
EXPORT_FUNCTIONS() {
	if [ -z "$ECLASS" ]; then
		die "EXPORT_FUNCTIONS without a defined ECLASS"
	fi
	eval $__export_funcs_var+=\" $*\"
}

# this is a function for removing any directory matching a passed in pattern from
# PATH
remove_path_entry() {
	save_IFS
	IFS=":"
	stripped_path="${PATH}"
	while [ -n "$1" ]; do
		cur_path=""
		for p in ${stripped_path}; do
			if [ "${p/${1}}" == "${p}" ]; then
				cur_path="${cur_path}:${p}"
			fi
		done
		stripped_path="${cur_path#:*}"
		shift
	done
	restore_IFS
	PATH="${stripped_path}"
}

# Set given variables unless these variable have been already set (e.g. during emerge
# invocation) to values different than values set in make.conf.
set_unless_changed() {
	if [[ $# -lt 1 ]]; then
		die "${FUNCNAME}() requires at least 1 argument: VARIABLE=VALUE"
	fi

	local argument value variable
	for argument in "$@"; do
		if [[ ${argument} != *=* ]]; then
			die "${FUNCNAME}(): Argument '${argument}' has incorrect syntax"
		fi
		variable="${argument%%=*}"
		value="${argument#*=}"
		if eval "[[ \${${variable}} == \$(env -u ${variable} portageq envvar ${variable}) ]]"; then
			eval "${variable}=\"\${value}\""
		fi
	done
}

# Unset given variables unless these variable have been set (e.g. during emerge
# invocation) to values different than values set in make.conf.
unset_unless_changed() {
	if [[ $# -lt 1 ]]; then
		die "${FUNCNAME}() requires at least 1 argument: VARIABLE"
	fi

	local variable
	for variable in "$@"; do
		if eval "[[ \${${variable}} == \$(env -u ${variable} portageq envvar ${variable}) ]]"; then
			unset ${variable}
		fi
	done
}

PORTAGE_BASHRCS_SOURCED=0

# @FUNCTION: source_all_bashrcs
# @DESCRIPTION:
# Source a relevant bashrc files and perform other miscellaneous
# environment initialization when appropriate.
#
# If EAPI is set then define functions provided by the current EAPI:
#
#  * default_* aliases for the current EAPI phase functions
#  * A "default" function which is an alias for the default phase
#    function for the current phase.
#
source_all_bashrcs() {
	[[ $PORTAGE_BASHRCS_SOURCED = 1 ]] && return 0
	PORTAGE_BASHRCS_SOURCED=1
	local x

	local OCC="${CC}" OCXX="${CXX}"

	if [[ $EBUILD_PHASE != depend ]] ; then
		# source the existing profile.bashrcs.
		save_IFS
		IFS=$'\n'
		local path_array=($PROFILE_PATHS)
		restore_IFS
		for x in "${path_array[@]}" ; do
			[ -f "$x/profile.bashrc" ] && qa_source "$x/profile.bashrc"
		done
	fi

	# We assume if people are changing shopts in their bashrc they do so at their
	# own peril.  This is the ONLY non-portage bit of code that can change shopts
	# without a QA violation.
	for x in "${PORTAGE_BASHRC}" "${PM_EBUILD_HOOK_DIR}"/${CATEGORY}/{${PN},${PN}:${SLOT},${P},${PF}}; do
		if [ -r "${x}" ]; then
			# If $- contains x, then tracing has already enabled elsewhere for some
			# reason.  We preserve it's state so as not to interfere.
			if [ "$PORTAGE_DEBUG" != "1" ] || [ "${-/x/}" != "$-" ]; then
				source "${x}"
			else
				set -x
				source "${x}"
				set +x
			fi
		fi
	done

	[ ! -z "${OCC}" ] && export CC="${OCC}"
	[ ! -z "${OCXX}" ] && export CXX="${OCXX}"
}

# Hardcoded bash lists are needed for backward compatibility with
# <portage-2.1.4 since they assume that a newly installed version
# of ebuild.sh will work for pkg_postinst, pkg_prerm, and pkg_postrm
# when portage is upgrading itself.

PORTAGE_READONLY_METADATA="DEFINED_PHASES DEPEND DESCRIPTION
	EAPI HOMEPAGE INHERITED IUSE REQUIRED_USE KEYWORDS LICENSE
	PDEPEND PROVIDE RDEPEND RESTRICT SLOT SRC_URI"

PORTAGE_READONLY_VARS="D EBUILD EBUILD_PHASE \
	EBUILD_SH_ARGS ECLASSDIR EMERGE_FROM FILESDIR MERGE_TYPE \
	PM_EBUILD_HOOK_DIR \
	PORTAGE_ACTUAL_DISTDIR PORTAGE_ARCHLIST PORTAGE_BASHRC  \
	PORTAGE_BINPKG_FILE PORTAGE_BINPKG_TAR_OPTS PORTAGE_BINPKG_TMPFILE \
	PORTAGE_BIN_PATH PORTAGE_BUILDDIR PORTAGE_BUNZIP2_COMMAND \
	PORTAGE_BZIP2_COMMAND PORTAGE_COLORMAP PORTAGE_CONFIGROOT \
	PORTAGE_DEBUG PORTAGE_DEPCACHEDIR PORTAGE_EBUILD_EXIT_FILE \
	PORTAGE_GID PORTAGE_GRPNAME PORTAGE_INST_GID PORTAGE_INST_UID \
	PORTAGE_IPC_DAEMON PORTAGE_IUSE PORTAGE_LOG_FILE \
	PORTAGE_MUTABLE_FILTERED_VARS PORTAGE_PYM_PATH PORTAGE_PYTHON \
	PORTAGE_READONLY_METADATA PORTAGE_READONLY_VARS \
	PORTAGE_REPO_NAME PORTAGE_RESTRICT PORTAGE_SANDBOX_COMPAT_LEVEL \
	PORTAGE_SAVED_READONLY_VARS PORTAGE_SIGPIPE_STATUS \
	PORTAGE_TMPDIR PORTAGE_UPDATE_ENV PORTAGE_USERNAME \
	PORTAGE_VERBOSE PORTAGE_WORKDIR_MODE PORTDIR PORTDIR_OVERLAY \
	PROFILE_PATHS REPLACING_VERSIONS REPLACED_BY_VERSION T WORKDIR"

PORTAGE_SAVED_READONLY_VARS="A CATEGORY P PF PN PR PV PVR"

# Variables that portage sets but doesn't mark readonly.
# In order to prevent changed values from causing unexpected
# interference, they are filtered out of the environment when
# it is saved or loaded (any mutations do not persist).
PORTAGE_MUTABLE_FILTERED_VARS="AA HOSTNAME"

# @FUNCTION: filter_readonly_variables
# @DESCRIPTION: [--filter-sandbox] [--allow-extra-vars]
# Read an environment from stdin and echo to stdout while filtering variables
# with names that are known to cause interference:
#
#   * some specific variables for which bash does not allow assignment
#   * some specific variables that affect portage or sandbox behavior
#   * variable names that begin with a digit or that contain any
#     non-alphanumeric characters that are not be supported by bash
#
# --filter-sandbox causes all SANDBOX_* variables to be filtered, which
# is only desired in certain cases, such as during preprocessing or when
# saving environment.bz2 for a binary or installed package.
#
# --filter-features causes the special FEATURES variable to be filtered.
# Generally, we want it to persist between phases since the user might
# want to modify it via bashrc to enable things like splitdebug and
# installsources for specific packages. They should be able to modify it
# in pre_pkg_setup() and have it persist all the way through the install
# phase. However, if FEATURES exist inside environment.bz2 then they
# should be overridden by current settings.
#
# --filter-locale causes locale related variables such as LANG and LC_*
# variables to be filtered. These variables should persist between phases,
# in case they are modified by the ebuild. However, the current user
# settings should be used when loading the environment from a binary or
# installed package.
#
# --filter-path causes the PATH variable to be filtered. This variable
# should persist between phases, in case it is modified by the ebuild.
# However, old settings should be overridden when loading the
# environment from a binary or installed package.
#
# ---allow-extra-vars causes some extra vars to be allowd through, such
# as ${PORTAGE_SAVED_READONLY_VARS} and ${PORTAGE_MUTABLE_FILTERED_VARS}.
#
# In bash-3.2_p20+ an attempt to assign BASH_*, FUNCNAME, GROUPS or any
# readonly variable cause the shell to exit while executing the "source"
# builtin command. To avoid this problem, this function filters those
# variables out and discards them. See bug #190128.
filter_readonly_variables() {
	local x filtered_vars
	local readonly_bash_vars="BASHOPTS BASHPID DIRSTACK EUID
		FUNCNAME GROUPS PIPESTATUS PPID SHELLOPTS UID"
	local bash_misc_vars="BASH BASH_.* COMP_WORDBREAKS HISTCMD
		HISTFILE HOSTNAME HOSTTYPE IFS LINENO MACHTYPE OLDPWD
		OPTERR OPTIND OSTYPE POSIXLY_CORRECT PS4 PWD RANDOM
		SECONDS SHELL SHLVL"
	local filtered_sandbox_vars="SANDBOX_ACTIVE SANDBOX_BASHRC
		SANDBOX_DEBUG_LOG SANDBOX_DISABLED SANDBOX_LIB
		SANDBOX_LOG SANDBOX_ON"
	local misc_garbage_vars="_portage_filter_opts"
	filtered_vars="$readonly_bash_vars $bash_misc_vars
		$PORTAGE_READONLY_VARS $misc_garbage_vars"

	# Don't filter/interfere with prefix variables unless they are
	# supported by the current EAPI.
	case "${EAPI:-0}" in
		0|1|2)
			;;
		*)
			filtered_vars+=" ED EPREFIX EROOT"
			;;
	esac

	if has --filter-sandbox $* ; then
		filtered_vars="${filtered_vars} SANDBOX_.*"
	else
		filtered_vars="${filtered_vars} ${filtered_sandbox_vars}"
	fi
	if has --filter-features $* ; then
		filtered_vars="${filtered_vars} FEATURES PORTAGE_FEATURES"
	fi
	if has --filter-path $* ; then
		filtered_vars+=" PATH"
	fi
	if has --filter-locale $* ; then
		filtered_vars+=" LANG LC_ALL LC_COLLATE
			LC_CTYPE LC_MESSAGES LC_MONETARY
			LC_NUMERIC LC_PAPER LC_TIME"
	fi
	if ! has --allow-extra-vars $* ; then
		filtered_vars="
			${filtered_vars}
			${PORTAGE_SAVED_READONLY_VARS}
			${PORTAGE_MUTABLE_FILTERED_VARS}
		"
	fi

	"${PORTAGE_PYTHON:-/usr/bin/python}" "${PORTAGE_BIN_PATH}"/filter-bash-environment.py "${filtered_vars}" || die "filter-bash-environment.py failed"
}

# @FUNCTION: preprocess_ebuild_env
# @DESCRIPTION:
# Filter any readonly variables from ${T}/environment, source it, and then
# save it via save_ebuild_env(). This process should be sufficient to prevent
# any stale variables or functions from an arbitrary environment from
# interfering with the current environment. This is useful when an existing
# environment needs to be loaded from a binary or installed package.
preprocess_ebuild_env() {
	local _portage_filter_opts="--filter-features --filter-locale --filter-path --filter-sandbox"

	# If environment.raw is present, this is a signal from the python side,
	# indicating that the environment may contain stale FEATURES and
	# SANDBOX_{DENY,PREDICT,READ,WRITE} variables that should be filtered out.
	# Otherwise, we don't need to filter the environment.
	[ -f "${T}/environment.raw" ] || return 0

	filter_readonly_variables $_portage_filter_opts < "${T}"/environment \
		>> "$T/environment.filtered" || return $?
	unset _portage_filter_opts
	mv "${T}"/environment.filtered "${T}"/environment || return $?
	rm -f "${T}/environment.success" || return $?
	# WARNING: Code inside this subshell should avoid making assumptions
	# about variables or functions after source "${T}"/environment has been
	# called. Any variables that need to be relied upon should already be
	# filtered out above.
	(
		export SANDBOX_ON=1
		source "${T}/environment" || exit $?
		# We have to temporarily disable sandbox since the
		# SANDBOX_{DENY,READ,PREDICT,WRITE} values we've just loaded
		# may be unusable (triggering in spurious sandbox violations)
		# until we've merged them with our current values.
		export SANDBOX_ON=0

		# It's remotely possible that save_ebuild_env() has been overridden
		# by the above source command. To protect ourselves, we override it
		# here with our own version. ${PORTAGE_BIN_PATH} is safe to use here
		# because it's already filtered above.
		source "${PORTAGE_BIN_PATH}/isolated-functions.sh" || exit $?

		# Rely on save_ebuild_env() to filter out any remaining variables
		# and functions that could interfere with the current environment.
		save_ebuild_env || exit $?
		>> "$T/environment.success" || exit $?
	) > "${T}/environment.filtered"
	local retval
	if [ -e "${T}/environment.success" ] ; then
		filter_readonly_variables --filter-features < \
			"${T}/environment.filtered" > "${T}/environment"
		retval=$?
	else
		retval=1
	fi
	rm -f "${T}"/environment.{filtered,raw,success}
	return ${retval}
}

# === === === === === === === === === === === === === === === === === ===
# === === === === === functions end, main part begins === === === === ===
# === === === === === functions end, main part begins === === === === ===
# === === === === === functions end, main part begins === === === === ===
# === === === === === === === === === === === === === === === === === ===

export SANDBOX_ON="1"
export S=${WORKDIR}/${P}

unset E_IUSE E_REQUIRED_USE E_DEPEND E_RDEPEND E_PDEPEND

# Turn of extended glob matching so that g++ doesn't get incorrectly matched.
shopt -u extglob

if [[ ${EBUILD_PHASE} == depend ]] ; then
	QA_INTERCEPTORS="awk bash cc egrep equery fgrep g++
		gawk gcc grep javac java-config nawk perl
		pkg-config python python-config sed"
elif [[ ${EBUILD_PHASE} == clean* ]] ; then
	unset QA_INTERCEPTORS
else
	QA_INTERCEPTORS="autoconf automake aclocal libtoolize"
fi
# level the QA interceptors if we're in depend
if [[ -n ${QA_INTERCEPTORS} ]] ; then
	for BIN in ${QA_INTERCEPTORS}; do
		BIN_PATH=$(type -Pf ${BIN})
		if [ "$?" != "0" ]; then
			BODY="echo \"*** missing command: ${BIN}\" >&2; return 127"
		else
			BODY="${BIN_PATH} \"\$@\"; return \$?"
		fi
		if [[ ${EBUILD_PHASE} == depend ]] ; then
			FUNC_SRC="${BIN}() {
				if [ \$ECLASS_DEPTH -gt 0 ]; then
					eqawarn \"QA Notice: '${BIN}' called in global scope: eclass \${ECLASS}\"
				else
					eqawarn \"QA Notice: '${BIN}' called in global scope: \${CATEGORY}/\${PF}\"
				fi
			${BODY}
			}"
		elif has ${BIN} autoconf automake aclocal libtoolize ; then
			FUNC_SRC="${BIN}() {
				if ! has \${FUNCNAME[1]} eautoreconf eaclocal _elibtoolize \\
					eautoheader eautoconf eautomake autotools_run_tool \\
					autotools_check_macro autotools_get_subdirs \\
					autotools_get_auxdir ; then
					eqawarn \"QA Notice: '${BIN}' called by \${FUNCNAME[1]}: \${CATEGORY}/\${PF}\"
					eqawarn \"Use autotools.eclass instead of calling '${BIN}' directly.\"
				fi
			${BODY}
			}"
		else
			FUNC_SRC="${BIN}() {
				eqawarn \"QA Notice: '${BIN}' called by \${FUNCNAME[1]}: \${CATEGORY}/\${PF}\"
			${BODY}
			}"
		fi
		eval "$FUNC_SRC" || echo "error creating QA interceptor ${BIN}" >&2
	done
	unset BIN_PATH BIN BODY FUNC_SRC
fi

# Subshell/helper die support (must export for the die helper).
export EBUILD_MASTER_PID=$BASHPID
trap 'exit 1' SIGTERM

if [[ $EBUILD_PHASE != depend ]] ; then
	source "${PORTAGE_BIN_PATH}/phase-functions.sh"
	source "${PORTAGE_BIN_PATH}/phase-helpers.sh"
else
	# These dummy functions are for things that are likely to be called
	# in global scope, even though they are completely useless during
	# the "depend" phase.
	for x in diropts docompress exeopts insopts \
		keepdir libopts use useq usev use_with use_enable ; do
		eval "${x}() { : ; }"
	done
	unset x
fi

if ! has "$EBUILD_PHASE" clean cleanrm depend && \
	[ -f "${T}"/environment ] ; then
	# The environment may have been extracted from environment.bz2 or
	# may have come from another version of ebuild.sh or something.
	# In any case, preprocess it to prevent any potential interference.
	preprocess_ebuild_env || \
		die "error processing environment"
	# Colon separated SANDBOX_* variables need to be cumulative.
	for x in SANDBOX_DENY SANDBOX_READ SANDBOX_PREDICT SANDBOX_WRITE ; do
		export PORTAGE_${x}=${!x}
	done
	PORTAGE_SANDBOX_ON=${SANDBOX_ON}
	export SANDBOX_ON=1
	source "${T}"/environment || \
		die "error sourcing environment"
	# We have to temporarily disable sandbox since the
	# SANDBOX_{DENY,READ,PREDICT,WRITE} values we've just loaded
	# may be unusable (triggering in spurious sandbox violations)
	# until we've merged them with our current values.
	export SANDBOX_ON=0
	for x in SANDBOX_DENY SANDBOX_PREDICT SANDBOX_READ SANDBOX_WRITE ; do
		y="PORTAGE_${x}"
		if [ -z "${!x}" ] ; then
			export ${x}=${!y}
		elif [ -n "${!y}" ] && [ "${!y}" != "${!x}" ] ; then
			# filter out dupes
			export ${x}=$(printf "${!y}:${!x}" | tr ":" "\0" | \
				sort -z -u | tr "\0" ":")
		fi
		export ${x}=${!x%:}
		unset PORTAGE_${x}
	done
	unset x y
	export SANDBOX_ON=${PORTAGE_SANDBOX_ON}
	unset PORTAGE_SANDBOX_ON
	[[ -n $EAPI ]] || EAPI=0
fi

if ! has "$EBUILD_PHASE" clean cleanrm ; then
	if [[ $EBUILD_PHASE = depend || ! -f $T/environment || \
		-f $PORTAGE_BUILDDIR/.ebuild_changed ]] || \
		has noauto $FEATURES ; then
		# The bashrcs get an opportunity here to set aliases that will be expanded
		# during sourcing of ebuilds and eclasses.
		source_all_bashrcs

		# When EBUILD_PHASE != depend, INHERITED comes pre-initialized
		# from cache. In order to make INHERITED content independent of
		# EBUILD_PHASE during inherit() calls, we unset INHERITED after
		# we make a backup copy for QA checks.
		__INHERITED_QA_CACHE=$INHERITED

		# *DEPEND and IUSE will be set during the sourcing of the ebuild.
		# In order to ensure correct interaction between ebuilds and
		# eclasses, they need to be unset before this process of
		# interaction begins.
		unset DEPEND RDEPEND PDEPEND INHERITED IUSE REQUIRED_USE \
			ECLASS E_IUSE E_REQUIRED_USE E_DEPEND E_RDEPEND E_PDEPEND

		if [[ $PORTAGE_DEBUG != 1 || ${-/x/} != $- ]] ; then
			source "$EBUILD" || die "error sourcing ebuild"
		else
			set -x
			source "$EBUILD" || die "error sourcing ebuild"
			set +x
		fi

		if [[ "${EBUILD_PHASE}" != "depend" ]] ; then
			RESTRICT=${PORTAGE_RESTRICT}
			[[ -e $PORTAGE_BUILDDIR/.ebuild_changed ]] && \
			rm "$PORTAGE_BUILDDIR/.ebuild_changed"
		fi

		[[ -n $EAPI ]] || EAPI=0

		if has "$EAPI" 0 1 2 3 3_pre2 ; then
			export RDEPEND=${RDEPEND-${DEPEND}}
			debug-print "RDEPEND: not set... Setting to: ${DEPEND}"
		fi

		# add in dependency info from eclasses
		IUSE="${IUSE} ${E_IUSE}"
		DEPEND="${DEPEND} ${E_DEPEND}"
		RDEPEND="${RDEPEND} ${E_RDEPEND}"
		PDEPEND="${PDEPEND} ${E_PDEPEND}"
		REQUIRED_USE="${REQUIRED_USE} ${E_REQUIRED_USE}"
		
		unset ECLASS E_IUSE E_REQUIRED_USE E_DEPEND E_RDEPEND E_PDEPEND \
			__INHERITED_QA_CACHE

		# alphabetically ordered by $EBUILD_PHASE value
		case "$EAPI" in
			0|1)
				_valid_phases="src_compile pkg_config pkg_info src_install
					pkg_nofetch pkg_postinst pkg_postrm pkg_preinst pkg_prerm
					pkg_setup src_test src_unpack"
				;;
			2|3|3_pre2)
				_valid_phases="src_compile pkg_config src_configure pkg_info
					src_install pkg_nofetch pkg_postinst pkg_postrm pkg_preinst
					src_prepare pkg_prerm pkg_setup src_test src_unpack"
				;;
			*)
				_valid_phases="src_compile pkg_config src_configure pkg_info
					src_install pkg_nofetch pkg_postinst pkg_postrm pkg_preinst
					src_prepare pkg_prerm pkg_pretend pkg_setup src_test src_unpack"
				;;
		esac

		DEFINED_PHASES=
		for _f in $_valid_phases ; do
			if declare -F $_f >/dev/null ; then
				_f=${_f#pkg_}
				DEFINED_PHASES+=" ${_f#src_}"
			fi
		done
		[[ -n $DEFINED_PHASES ]] || DEFINED_PHASES=-

		unset _f _valid_phases

		if [[ $EBUILD_PHASE != depend ]] ; then

			case "$EAPI" in
				0|1|2|3)
					_ebuild_helpers_path="$PORTAGE_BIN_PATH/ebuild-helpers"
					;;
				*)
					_ebuild_helpers_path="$PORTAGE_BIN_PATH/ebuild-helpers/4:$PORTAGE_BIN_PATH/ebuild-helpers"
					;;
			esac

			PATH=$_ebuild_helpers_path:$PREROOTPATH${PREROOTPATH:+:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${ROOTPATH:+:}$ROOTPATH
			unset _ebuild_helpers_path

			# Use default ABI libdir in accordance with bug #355283.
			x=LIBDIR_${DEFAULT_ABI}
			[[ -n $DEFAULT_ABI && -n ${!x} ]] && x=${!x} || x=lib

			if has distcc $FEATURES ; then
				PATH="/usr/$x/distcc/bin:$PATH"
				[[ -n $DISTCC_LOG ]] && addwrite "${DISTCC_LOG%/*}"
			fi

			if has ccache $FEATURES ; then
				PATH="/usr/$x/ccache/bin:$PATH"

				if [[ -n $CCACHE_DIR ]] ; then
					addread "$CCACHE_DIR"
					addwrite "$CCACHE_DIR"
				fi

				[[ -n $CCACHE_SIZE ]] && ccache -M $CCACHE_SIZE &> /dev/null
			fi

			unset x

			if [[ -n $QA_PREBUILT ]] ; then

				# these ones support fnmatch patterns
				QA_EXECSTACK+=" $QA_PREBUILT"
				QA_TEXTRELS+=" $QA_PREBUILT"
				QA_WX_LOAD+=" $QA_PREBUILT"

				# these ones support regular expressions, so translate
				# fnmatch patterns to regular expressions
				for x in QA_DT_HASH QA_DT_NEEDED QA_PRESTRIPPED QA_SONAME ; do
					if [[ $(declare -p $x 2>/dev/null) = declare\ -a* ]] ; then
						eval "$x=(\"\${$x[@]}\" ${QA_PREBUILT//\*/.*})"
					else
						eval "$x+=\" ${QA_PREBUILT//\*/.*}\""
					fi
				done

				unset x
			fi

			# This needs to be exported since prepstrip is a separate shell script.
			[[ -n $QA_PRESTRIPPED ]] && export QA_PRESTRIPPED
			eval "[[ -n \$QA_PRESTRIPPED_${ARCH/-/_} ]] && \
				export QA_PRESTRIPPED_${ARCH/-/_}"
		fi
	fi
fi

# unset USE_EXPAND variables that contain only the special "*" token
for x in ${USE_EXPAND} ; do
	[ "${!x}" == "*" ] && unset ${x}
done
unset x

if has nostrip ${FEATURES} ${RESTRICT} || has strip ${RESTRICT}
then
	export DEBUGBUILD=1
fi

#a reasonable default for $S
[[ -z ${S} ]] && export S=${WORKDIR}/${P}

# Note: readonly variables interfere with preprocess_ebuild_env(), so
# declare them only after it has already run.
if [ "${EBUILD_PHASE}" != "depend" ] ; then
	declare -r $PORTAGE_READONLY_METADATA $PORTAGE_READONLY_VARS
	case "$EAPI" in
		0|1|2)
			;;
		*)
			declare -r ED EPREFIX EROOT
			;;
	esac
fi

ebuild_main() {

	# Subshell/helper die support (must export for the die helper).
	# Since this function is typically executed in a subshell,
	# setup EBUILD_MASTER_PID to refer to the current $BASHPID,
	# which seems to give the best results when further
	# nested subshells call die.
	export EBUILD_MASTER_PID=$BASHPID
	trap 'exit 1' SIGTERM

	if [[ $EBUILD_PHASE != depend ]] ; then
		# Force configure scripts that automatically detect ccache to
		# respect FEATURES="-ccache".
		has ccache $FEATURES || export CCACHE_DISABLE=1

		local phase_func=$(_ebuild_arg_to_phase "$EAPI" "$EBUILD_PHASE")
		[[ -n $phase_func ]] && _ebuild_phase_funcs "$EAPI" "$phase_func"
		unset phase_func
	fi

	source_all_bashrcs

	case ${EBUILD_SH_ARGS} in
	nofetch)
		ebuild_phase_with_hooks pkg_nofetch
		;;
	prerm|postrm|postinst|config|info)
		if has "$EBUILD_SH_ARGS" config info && \
			! declare -F "pkg_$EBUILD_SH_ARGS" >/dev/null ; then
			ewarn  "pkg_${EBUILD_SH_ARGS}() is not defined: '${EBUILD##*/}'"
		fi
		export SANDBOX_ON="0"
		if [ "${PORTAGE_DEBUG}" != "1" ] || [ "${-/x/}" != "$-" ]; then
			ebuild_phase_with_hooks pkg_${EBUILD_SH_ARGS}
		else
			set -x
			ebuild_phase_with_hooks pkg_${EBUILD_SH_ARGS}
			set +x
		fi
		if [[ $EBUILD_PHASE == postinst ]] && [[ -n $PORTAGE_UPDATE_ENV ]]; then
			# Update environment.bz2 in case installation phases
			# need to pass some variables to uninstallation phases.
			save_ebuild_env --exclude-init-phases | \
				filter_readonly_variables --filter-path \
				--filter-sandbox --allow-extra-vars \
				| ${PORTAGE_BZIP2_COMMAND} -c -f9 > "$PORTAGE_UPDATE_ENV"
			assert "save_ebuild_env failed"
		fi
		;;
	unpack|prepare|configure|compile|test|clean|install)
		if [[ ${SANDBOX_DISABLED:-0} = 0 ]] ; then
			export SANDBOX_ON="1"
		else
			export SANDBOX_ON="0"
		fi

		case "$EBUILD_SH_ARGS" in
		configure|compile)

			local x
			for x in ASFLAGS CCACHE_DIR CCACHE_SIZE \
				CFLAGS CXXFLAGS LDFLAGS LIBCFLAGS LIBCXXFLAGS ; do
				[[ ${!x+set} = set ]] && export $x
			done
			unset x

			has distcc $FEATURES && [[ -n $DISTCC_DIR ]] && \
				[[ ${SANDBOX_WRITE/$DISTCC_DIR} = $SANDBOX_WRITE ]] && \
				addwrite "$DISTCC_DIR"

			x=LIBDIR_$ABI
			[ -z "$PKG_CONFIG_PATH" -a -n "$ABI" -a -n "${!x}" ] && \
				export PKG_CONFIG_PATH=/usr/${!x}/pkgconfig

			if has noauto $FEATURES && \
				[[ ! -f $PORTAGE_BUILDDIR/.unpacked ]] ; then
				echo
				echo "!!! We apparently haven't unpacked..." \
					"This is probably not what you"
				echo "!!! want to be doing... You are using" \
					"FEATURES=noauto so I'll assume"
				echo "!!! that you know what you are doing..." \
					"You have 5 seconds to abort..."
				echo

				local x
				for x in 1 2 3 4 5 6 7 8; do
					LC_ALL=C sleep 0.25
				done

				sleep 3
			fi

			cd "$PORTAGE_BUILDDIR"
			if [ ! -d build-info ] ; then
				mkdir build-info
				cp "$EBUILD" "build-info/$PF.ebuild"
			fi

			#our custom version of libtool uses $S and $D to fix
			#invalid paths in .la files
			export S D

			;;
		esac

		if [ "${PORTAGE_DEBUG}" != "1" ] || [ "${-/x/}" != "$-" ]; then
			dyn_${EBUILD_SH_ARGS}
		else
			set -x
			dyn_${EBUILD_SH_ARGS}
			set +x
		fi
		export SANDBOX_ON="0"
		;;
	help|pretend|setup|preinst)
		#pkg_setup needs to be out of the sandbox for tmp file creation;
		#for example, awking and piping a file in /tmp requires a temp file to be created
		#in /etc.  If pkg_setup is in the sandbox, both our lilo and apache ebuilds break.
		export SANDBOX_ON="0"
		if [ "${PORTAGE_DEBUG}" != "1" ] || [ "${-/x/}" != "$-" ]; then
			dyn_${EBUILD_SH_ARGS}
		else
			set -x
			dyn_${EBUILD_SH_ARGS}
			set +x
		fi
		;;
	depend)
		export SANDBOX_ON="0"
		set -f

		if [ -n "${dbkey}" ] ; then
			if [ ! -d "${dbkey%/*}" ]; then
				install -d -g ${PORTAGE_GID} -m2775 "${dbkey%/*}"
			fi
			# Make it group writable. 666&~002==664
			umask 002
		fi

		auxdbkeys="DEPEND RDEPEND SLOT SRC_URI RESTRICT HOMEPAGE LICENSE
			DESCRIPTION KEYWORDS INHERITED IUSE REQUIRED_USE PDEPEND PROVIDE EAPI
			PROPERTIES DEFINED_PHASES UNUSED_05 UNUSED_04
			UNUSED_03 UNUSED_02 UNUSED_01"

		#the extra $(echo) commands remove newlines
		[ -n "${EAPI}" ] || EAPI=0

		if [ -n "${dbkey}" ] ; then
			> "${dbkey}"
			for f in ${auxdbkeys} ; do
				echo $(echo ${!f}) >> "${dbkey}" || exit $?
			done
		else
			for f in ${auxdbkeys} ; do
				echo $(echo ${!f}) 1>&9 || exit $?
			done
			exec 9>&-
		fi
		set +f
		;;
	_internal_test)
		;;
	*)
		export SANDBOX_ON="1"
		echo "Unrecognized EBUILD_SH_ARGS: '${EBUILD_SH_ARGS}'"
		echo
		dyn_help
		exit 1
		;;
	esac
}

if [[ -s $SANDBOX_LOG ]] ; then
	# We use SANDBOX_LOG to check for sandbox violations,
	# so we ensure that there can't be a stale log to
	# interfere with our logic.
	x=
	if [[ -n SANDBOX_ON ]] ; then
		x=$SANDBOX_ON
		export SANDBOX_ON=0
	fi

	rm -f "$SANDBOX_LOG" || \
		die "failed to remove stale sandbox log: '$SANDBOX_LOG'"

	if [[ -n $x ]] ; then
		export SANDBOX_ON=$x
	fi
	unset x
fi

if [[ $EBUILD_PHASE = depend ]] ; then
	ebuild_main
elif [[ -n $EBUILD_SH_ARGS ]] ; then
	(
		# Don't allow subprocesses to inherit the pipe which
		# emerge uses to monitor ebuild.sh.
		exec 9>&-

		ebuild_main

		# Save the env only for relevant phases.
		if ! has "$EBUILD_SH_ARGS" clean help info nofetch ; then
			umask 002
			save_ebuild_env | filter_readonly_variables \
				--filter-features > "$T/environment"
			assert "save_ebuild_env failed"
			chown portage:portage "$T/environment" &>/dev/null
			chmod g+w "$T/environment" &>/dev/null
		fi
		[[ -n $PORTAGE_EBUILD_EXIT_FILE ]] && > "$PORTAGE_EBUILD_EXIT_FILE"
		if [[ -n $PORTAGE_IPC_DAEMON ]] ; then
			[[ ! -s $SANDBOX_LOG ]]
			"$PORTAGE_BIN_PATH"/ebuild-ipc exit $?
		fi
		exit 0
	)
	exit $?
fi

# Do not exit when ebuild.sh is sourced by other scripts.
true
