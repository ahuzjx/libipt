#! /bin/bash
#
# Copyright (c) 2013-2020, Intel Corporation
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
#  * Redistributions of source code must retain the above copyright notice,
#    this list of conditions and the following disclaimer.
#  * Redistributions in binary form must reproduce the above copyright notice,
#    this list of conditions and the following disclaimer in the documentation
#    and/or other materials provided with the distribution.
#  * Neither the name of Intel Corporation nor the names of its contributors
#    may be used to endorse or promote products derived from this software
#    without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.
#
# This script executes ptt tests and compares the output of tools, like
# ptxed or ptdump, with the expected output from the ptt testfile.

info() {
	[[ $verbose != 0 ]] && echo -e "$@" >&2
}

run() {
	info "$@"
	"$@"
}

asm2addr() {
	local line
	line=`grep -i ^org "$1"`
	[[ $? != 0 ]] && return $?
	echo $line | sed "s/org *//"
}

usage() {
	cat <<EOF
usage: $0 [<options>] <pttfile>...

options:
  -h            this text
  -v            print commands as they are executed
  -c cpu[,cpu]  comma-separated list of cpu's for the tests (see pttc -h, for valid values)
  -f            exit with 1 if any of the tests failed
  -l            only list .diff files
  -g            specify the pttc command (default: pttc)
  -G            specify additional arguments to pttc
  -d            specify the ptdump command (default: ptdump)
  -D            specify additional arguments to ptdump
  -x            specify the ptxed command (default: ptxed)
  -X            specify additional arguments to ptxed

  <pttfile>     annotated yasm file ending in .ptt
EOF
}

pttc_cmd=pttc
pttc_arg=""
ptdump_cmd=ptdump
ptdump_arg=""
ptxed_cmd=ptxed
ptxed_arg=""
exit_fails=0
list=0
verbose=0
while getopts "hvc:flg:G:d:D:x:X:" option; do
	case $option in
	h)
		usage
		exit 0
		;;
	v)
		verbose=1
		;;
	c)
		cpus=`echo $OPTARG | sed "s/,/ /g"`
		;;
	f)
		exit_fails=1
		;;
	l)
		list=1
		;;
	g)
		pttc_cmd=$OPTARG
		;;
	G)
		pttc_arg=$OPTARG
		;;
	d)
		ptdump_cmd=$OPTARG
		;;
	D)
		ptdump_arg=$OPTARG
		;;
	x)
		ptxed_cmd=$OPTARG
		;;
	X)
		ptxed_arg=$OPTARG
		;;
	\?)
		exit 1
		;;
	esac
done

shift $(($OPTIND-1))

if [[ $# == 0 ]]; then
	usage
	exit 1
fi

# the exit status
status=0

ptt-ptdump-opts() {
	sed -n 's/[ \t]*;[ \t]*opt:ptdump[ \t][ \t]*\(.*\)[ \t]*/\1/p' "$1"
}

ptt-ptxed-opts() {
	sed -n 's/[ \t]*;[ \t]*opt:ptxed[ \t][ \t]*\(.*\)[ \t]*/\1/p' "$1"
}

run-ptt-test() {
	info "\n# run-ptt-test $@"

	ptt="$1"
	cpu="$2"
	base=`basename "${ptt%%.ptt}"`

	if [[ -n "$cpu" ]]; then
		cpu="--cpu $cpu"
	fi

	# the following are the files that are generated by pttc
	pt=$base.pt
	bin=$base.bin
	lst=$base.lst


	# execute pttc - remove the extra \r in Windows line endings
	files=`run "$pttc_cmd" $pttc_arg $cpu "$ptt" | sed 's/\r\n/\n/g'`
	ret=$?
	if [[ $ret != 0 ]]; then
		echo "$ptt: $pttc_cmd $pttc_arg failed with $ret" >&2
		status=1
		return
	fi

	exps=""
	sb=""
	for file in $files; do
		case $file in
		*.sb)
			sb_base=${file%.sb}
			sb_part=${sb_base#$base-}
			sb_prefix=${sb_part%%,*}
			sb_options=${sb_part#$sb_prefix}
			sb_prio=${sb_prefix##*-}
			sb_prefix2=${sb_prefix%-$sb_prio}
			sb_format=${sb_prefix2##*-}

			sb+=`echo $sb_options | sed -e "s/,/ --$sb_format:/g" -e "s/=/ /g"`
			sb+=" --$sb_format:$sb_prio $file"
			;;
		*.exp)
			exps+=" $file"
			;;
		*)
			echo "$ptt: unexpected $pttc_cmd output '$file'"
			status=1
			continue
			;;
		esac
	done

	if [[ -z $exps ]]; then
		echo "$ptt: $pttc_cmd $pttc_arg did not produce any .exp file" >&2
		status=1
		return
	fi

	# loop over all .exp files determine the tool, generate .out
	# files and compare .exp and .out file with diff.
	# all differences will be
	for exp in $exps; do
		exp_base=${exp%%.exp}
		out=$exp_base.out
		diff=$exp_base.diff
		tool=${exp_base##$base-}
		tool=${tool%%-cpu_*}
		case $tool in
		ptxed)
			addr=`asm2addr "$ptt"`
			if [[ $? != 0 ]]; then
				echo "$ptt: org directive not found in test file" >&2
				status=1
				continue
			fi
			local opts=`ptt-ptxed-opts "$ptt"`
			opts+=" --no-inst --check"
			run "$ptxed_cmd" $ptxed_arg --raw $bin:$addr $cpu $opts --pt $pt $sb > $out
			;;
		ptdump)
			local opts=`ptt-ptdump-opts "$ptt"`
			run "$ptdump_cmd" $ptdump_arg $cpu $opts $sb $pt > $out
			;;
		*)
			echo "$ptt: unknown tool '$tool'"
			status=1
			continue
			;;
		esac
		if run diff -ub $exp $out > $diff; then
			run rm $diff
		else
			if [[ $exit_fails != 0 ]]; then
				status=1
			fi

			if [[ $list != 0 ]]; then
				echo $diff
			else
				cat $diff
			fi
		fi
	done
}

ptt-cpus() {
	sed -n 's/[ \t]*;[ \t]*cpu[ \t][ \t]*\(.*\)[ \t]*/\1/p' "$1"
}

run-ptt-tests() {
	local ptt="$1"
	local cpus=$cpus

	# if no cpus are given on the command-line,
	# use the cpu directives from the pttfile.
	if [[ -z $cpus ]]; then
		cpus=`ptt-cpus "$ptt"`
	fi

	# if there are no cpu directives in the pttfile,
	# run the test without any cpu settings.
	if [[ -z $cpus ]]; then
		run-ptt-test "$ptt"
		return
	fi

	# otherwise run for each cpu the test.
	for i in $cpus; do
		run-ptt-test "$ptt" $i
	done
}

for ptt in "$@"; do
	run-ptt-tests "$ptt"
done

exit $status
