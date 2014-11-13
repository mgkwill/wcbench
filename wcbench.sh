#!/usr/bin/env sh
# Main WCBench script. WCBench wraps CBench in stuff to make it useful.
# This script supports installing ODL, installing CBench, starting and
# configuring ODL, running CBench against ODL, pinning ODL to a given
# number of CPUs, using given-length CBench runs, collecting CBench
# results and system stats, storing results in CSV format, stopping
# ODL and removing all source/binaries installed by this script.
# The main repo for WCBench is: https://github.com/dfarrell07/wcbench
# See README.md for more details.

# Exit codes
EX_USAGE=64
EX_NOT_FOUND=65
EX_OK=0
EX_ERR=1

# Output verbose debug info (true) or not (anything else)
VERBOSE=false

# Params for CBench test and ODL config
NUM_SWITCHES=256  # Default number of switches for CBench to simulate
NUM_MACS=100000  # Default number of MACs for CBench to use
TESTS_PER_SWITCH=10  # Default number of CBench tests to do per CBench run
MS_PER_TEST=10000  # Default milliseconds to run each CBench test
CBENCH_WARMUP=1  # Default number of warmup cycles to run CBench
OSGI_PORT=2400  # Port that the OSGi console listens for telnet on
ODL_STARTUP_DELAY=90  # Default time in seconds to give ODL to start
CONTROLLER="OpenDaylight"  # Currently only support ODL
CONTROLLER_IP="localhost"  # Change this to remote IP if running on two systems
CONTROLLER_PORT=6633  # Default port for OpenDaylight
SSH_HOSTNAME="cbenchc"  # You'll need to update this to reflect ~/.ssh/config

# Paths used in this script
BASE_DIR=$HOME  # Directory that code and such is dropped into
OF_DIR=$BASE_DIR/openflow  # Directory that contains OpenFlow code
OFLOPS_DIR=$BASE_DIR/oflops  # Directory that contains oflops repo
ODL_DIR=$BASE_DIR/distribution-karaf-0.2.0-Helium  # Directory with ODL code
ODL_ZIP="distribution-karaf-0.2.0-Helium.zip"  # ODL zip name
ODL_ZIP_PATH=$BASE_DIR/$ODL_ZIP  # Full path to ODL zip
PLUGIN_DIR=$ODL_DIR/plugins  # ODL plugin directory
RESULTS_FILE=$BASE_DIR/"results.csv"  # File that results are stored in
CBENCH_LOG=$BASE_DIR/"cbench.log"  # Log file used to store strange error msgs
CBENCH_BIN="/usr/local/bin/cbench"  # Path to CBench binary
FEATURES_FILE=$ODL_DIR/etc/org.apache.karaf.features.cfg  # Karaf features to install

# Array that stores results in indexes defined by cols array
declare -a results

# The order of these array values determines column order in RESULTS_FILE
cols=(run_num cbench_avg start_time end_time controller_ip human_time
    num_switches num_macs tests_per_switch ms_per_test start_steal_time
    end_steal_time total_ram used_ram free_ram cpus one_min_load five_min_load
    fifteen_min_load controller start_iowait end_iowait)

# This two-stat-array system is needed until I find an answer to this question:
# http://goo.gl/e0M8Tp

# Associative array with stats-collecting commands for local system
declare -A local_stats_cmds
local_stats_cmds=([total_ram]="$(free -m | awk '/^Mem:/{print $2}')"
            [used_ram]="$(free -m | awk '/^Mem:/{print $3}')"
            [free_ram]="$(free -m | awk '/^Mem:/{print $4}')"
            [cpus]="`nproc`"
            [one_min_load]="`uptime | awk -F'[a-z]:' '{print $2}' | awk -F "," '{print $1}' | tr -d " "`"
            [five_min_load]="`uptime | awk -F'[a-z]:' '{print $2}' | awk -F "," '{print $2}' | tr -d " "`"
            [fifteen_min_load]="`uptime | awk -F'[a-z]:' '{print $2}' | awk -F "," '{print $3}' | tr -d " "`"
            [iowait]="`cat /proc/stat | awk 'NR==1 {print $6}'`"
            [steal_time]="`cat /proc/stat | awk 'NR==1 {print $9}'`")

# Associative array with stats-collecting commands for remote system
# See this for explanation of horrible-looking quoting: http://goo.gl/PMI5ag
declare -A remote_stats_cmds
remote_stats_cmds=([total_ram]='free -m | awk '"'"'/^Mem:/{print $2}'"'"''
            [used_ram]='free -m | awk '"'"'/^Mem:/{print $3}'"'"''
            [free_ram]='free -m | awk '"'"'/^Mem:/{print $4}'"'"''
            [cpus]='nproc'
            [one_min_load]='uptime | awk -F'"'"'[a-z]:'"'"' '"'"'{print $2}'"'"' | awk -F "," '"'"'{print $1}'"'"' | tr -d " "'
            [five_min_load]='uptime | awk -F'"'"'[a-z]:'"'"' '"'"'{print $2}'"'"' | awk -F "," '"'"'{print $2}'"'"' | tr -d " "'
            [fifteen_min_load]='uptime | awk -F'"'"'[a-z]:'"'"' '"'"'{print $2}'"'"' | awk -F "," '"'"'{print $3}'"'"' | tr -d " "'
            [iowait]='cat /proc/stat | awk '"'"'NR==1 {print $6}'"'"''
            [steal_time]='cat /proc/stat | awk '"'"'NR==1 {print $9}'"'"'')

###############################################################################
# Prints usage message
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
###############################################################################
usage()
{
    cat << EOF
Usage $0 [options]

Setup and/or run CBench and/or OpenDaylight.

OPTIONS:
    -h Show this message
    -c Install CBench
    -t <time> Run CBench for given number of minutes
    -r Run CBench against OpenDaylight
    -i Install ODL from last successful build
    -p <processors> Pin ODL to given number of processors
    -o Run ODL from last successful build
    -k Kill OpenDaylight
    -d Delete local ODL and CBench code
EOF
}

###############################################################################
# Globals:
#   EX_OK
#   EX_NOT_FOUND
# Arguments:
#   None
# Returns:
#   EX_OK if CBench is installed
#   EX_NOT_FOUND if CBench isn't installed
###############################################################################
cbench_installed()
{
    # Checks if CBench is installed
    if command -v cbench &>/dev/null; then
        echo "CBench is installed"
        return $EX_OK
    else
        echo "CBench is not installed"
        return $EX_NOT_FOUND
    fi
}

###############################################################################
# Installs CBench, including its dependencies
# This function is idempotent
# This has been tested on fresh cloud versions of Fedora 20 and CentOS 6.5
# Not currently building oflops/netfpga-packet-generator-c-library (optional)
# Globals:
#   VERBOSE
#   EX_OK
#   EX_ERR
#   OFLOPS_DIR
#   OF_DIR
# Arguments:
#   None
# Returns:
#   EX_OK if CBench is already installed or successfully installed
#   EX_ERR if CBench fails to install
###############################################################################
install_cbench()
{
    if cbench_installed; then
        return $EX_OK
    fi

    # Install required packages
    echo "Installing CBench dependencies"
    if "$VERBOSE" = true; then
        sudo yum install -y net-snmp-devel libpcap-devel autoconf make automake libtool libconfig-devel git
    else
        sudo yum install -y net-snmp-devel libpcap-devel autoconf make automake libtool libconfig-devel git &> /dev/null
    fi

    # Clone repo that contains CBench
    echo "Cloning CBench repo into $OFLOPS_DIR"
    if "$VERBOSE" = true; then
        git clone https://github.com/andi-bigswitch/oflops.git $OFLOPS_DIR
    else
        git clone https://github.com/andi-bigswitch/oflops.git $OFLOPS_DIR &> /dev/null
    fi

    # CBench requires the OpenFlow source code, clone it
    echo "Cloning openflow source code into $OF_DIR"
    if "$VERBOSE" = true; then
        git clone git://gitosis.stanford.edu/openflow.git $OF_DIR
    else
        git clone git://gitosis.stanford.edu/openflow.git $OF_DIR &> /dev/null
    fi

    # Build the oflops/configure file
    old_cwd=$PWD
    cd $OFLOPS_DIR
    echo "Building oflops/configure file"
    if "$VERBOSE" = true; then
        ./boot.sh
    else
        ./boot.sh &> /dev/null
    fi

    # Build oflops
    echo "Building CBench"
    if "$VERBOSE" = true; then
        ./configure --with-openflow-src-dir=$OF_DIR
        make
        sudo make install
    else
        ./configure --with-openflow-src-dir=$OF_DIR &> /dev/null
        make &> /dev/null
        sudo make install &> /dev/null
    fi
    cd $old_cwd

    # Validate that the install worked
    if ! cbench_installed; then
        echo "Failed to install CBench" >&2
        exit $EX_ERR
    else
        echo "Successfully installed CBench"
        return $EX_OK
    fi
}

###############################################################################
# Get the number of the next run, as found in results file
# Assumes that the results file hasn't had rows removed by a human
# Globals:
#   RESULTS_FILE
# Arguments:
#   None
# Returns:
#   The run number of the next run
###############################################################################
next_run_num()
{
    # Check if there's actually a results file
    if [ ! -s $RESULTS_FILE ]; then
        echo 0
        return
    fi

    # There should be one header row, then rows starting with 0, counting up
    num_lines=`wc -l $RESULTS_FILE | awk '{print $1}'`
    echo $(expr $num_lines - 1)
}

###############################################################################
# Given the name of a results column, get its index in cols (therefore results)
# Globals:
#   cols
# Arguments:
#   The name of the column to find the index of
# Returns:
#   The index of the given column name in cols
###############################################################################
name_to_index()
{
    name=$1
    for (( i = 0; i < ${#cols[@]}; i++ )); do
        if [ "${cols[$i]}" = $name ]; then
            echo $i
            return
        fi
    done
}

###############################################################################
# Accepts an array and writes it in CSV format to the results file
# Globals:
#   RESULTS_FILE
# Arguments:
#   Array to write to results file
# Returns:
#   None
###############################################################################
write_csv_row()
{
    # Creates var for array argument
    declare -a array_to_write=("${!1}")
    i=0
    # Write all but the last column of the array to results file
    while [ $i -lt $(expr ${#array_to_write[@]} - 1) ]; do
        # Only use echo with comma and no newline for all but last col
        echo -n "${array_to_write[$i]}," >> $RESULTS_FILE
        let i+=1
    done
    # Finish CSV row with no comma and a newline
    echo "${array_to_write[$i]}" >> $RESULTS_FILE
}

###############################################################################
# Collects local or remote system stats that should be collected pre-CBench
# Pre and post-test collection is needed for computing the change in stats
# Globals:
#   CONTROLLER_IP
#   SSH_HOSTNAME
#   results
#   local_stats_commands
#   remote_stats_commands
# Arguments:
#   None
# Returns:
#   None
###############################################################################
get_pre_test_stats()
{
    echo "Collecting pre-test stats"
    results[$(name_to_index "start_time")]=`date +%s`
    if [ $CONTROLLER_IP = "localhost" ]; then
        results[$(name_to_index "start_iowait")]=${local_stats_cmds[iowait]}
        results[$(name_to_index "start_steal_time")]=${local_stats_cmds[steal_time]}
    else
        results[$(name_to_index "start_iowait")]=$(ssh $SSH_HOSTNAME "${remote_stats_cmds[iowait]}" 2> /dev/null)
        results[$(name_to_index "start_steal_time")]=$(ssh $SSH_HOSTNAME "${remote_stats_cmds[steal_time]}" 2> /dev/null)
    fi
}

###############################################################################
# Collects local or remote system stats that should be collected post-CBench
# Pre and post-test collection is needed for computing the change in stats
# Globals:
#   CONTROLLER_IP
#   SSH_HOSTNAME
#   results
#   local_stats_commands
#   remote_stats_commands
# Arguments:
#   None
# Returns:
#   None
###############################################################################
get_post_test_stats()
{
    # Start by collecting always-local stats that are time-sensitive
    echo "Collecting post-test stats"
    results[$(name_to_index "end_time")]=`date +%s`
    results[$(name_to_index "human_time")]=`date`

    # Now collect local/remote stats that are time-sensative
    if [ $CONTROLLER_IP = "localhost" ]; then
        results[$(name_to_index "end_iowait")]=${local_stats_cmds[iowait]}
        results[$(name_to_index "end_steal_time")]=${local_stats_cmds[steal_time]}
        results[$(name_to_index "one_min_load")]=${local_stats_cmds[one_min_load]}
        results[$(name_to_index "five_min_load")]=${local_stats_cmds[five_min_load]}
        results[$(name_to_index "fifteen_min_load")]=${local_stats_cmds[fifteen_min_load]}
    else
        results[$(name_to_index "end_iowait")]=$(ssh $SSH_HOSTNAME "${remote_stats_cmds[iowait]}" 2> /dev/null)
        results[$(name_to_index "end_steal_time")]=$(ssh $SSH_HOSTNAME "${remote_stats_cmds[steal_time]}" 2> /dev/null)
        results[$(name_to_index "one_min_load")]=$(ssh $SSH_HOSTNAME "${remote_stats_cmds[one_min_load]}" 2> /dev/null)
        results[$(name_to_index "five_min_load")]=$(ssh $SSH_HOSTNAME "${remote_stats_cmds[five_min_load]}" 2> /dev/null)
        results[$(name_to_index "fifteen_min_load")]=$(ssh $SSH_HOSTNAME "${remote_stats_cmds[fifteen_min_load]}" 2> /dev/null)
    fi
}

###############################################################################
# Collects local or remote system stats for which collection time is irrelevant
# Globals:
#   CONTROLLER_IP
#   NUM_SWITCHES
#   NUM_MACS
#   TESTS_PER_SWITCH
#   MS_PER_TEST
#   CONTROLLER
#   SSH_HOSTNAME
#   results
#   local_stats_commands
#   remote_stats_commands
# Arguments:
#   None
# Returns:
#   None
###############################################################################
get_time_irrelevant_stats()
{
    # Collect always-local stats that aren't time-sensitive
    echo "Collecting time-irrelevant stats"
    results[$(name_to_index "run_num")]=$(next_run_num)
    results[$(name_to_index "controller_ip")]=$CONTROLLER_IP
    results[$(name_to_index "num_switches")]=$NUM_SWITCHES
    results[$(name_to_index "num_macs")]=$NUM_MACS
    results[$(name_to_index "tests_per_switch")]=$TESTS_PER_SWITCH
    results[$(name_to_index "ms_per_test")]=$MS_PER_TEST
    results[$(name_to_index "controller")]=$CONTROLLER

    # Store local or remote stats that aren't time-sensitive
    if [ $CONTROLLER_IP = "localhost" ]; then
        results[$(name_to_index "total_ram")]=${local_stats_cmds[total_ram]}
        results[$(name_to_index "used_ram")]=${local_stats_cmds[used_ram]}
        results[$(name_to_index "free_ram")]=${local_stats_cmds[free_ram]}
        results[$(name_to_index "cpus")]=${local_stats_cmds[cpus]}
    else
        results[$(name_to_index "total_ram")]=$(ssh $SSH_HOSTNAME "${remote_stats_cmds[total_ram]}" 2> /dev/null)
        results[$(name_to_index "used_ram")]=$(ssh $SSH_HOSTNAME "${remote_stats_cmds[used_ram]}" 2> /dev/null)
        results[$(name_to_index "free_ram")]=$(ssh $SSH_HOSTNAME "${remote_stats_cmds[free_ram]}" 2> /dev/null)
        results[$(name_to_index "cpus")]=$(ssh $SSH_HOSTNAME "${remote_stats_cmds[cpus]}" 2> /dev/null)
    fi
}

###############################################################################
# Write data stored in results array to results file
# Globals:
#   RESULTS_FILE
#   cols
#   results
# Arguments:
#   None
# Returns:
#   None
###############################################################################
write_results()
{
    # Write header if this is a fresh results file
    if [ ! -s $RESULTS_FILE ]; then
        echo "$RESULTS_FILE not found or empty, building fresh one" >&2
        write_csv_row cols[@]
    fi
    write_csv_row results[@]
}

###############################################################################
# Runs the CBench against the controller
# Globals:
#   CONTROLLER_IP
#   CONTROLLER_PORT
#   VERBOSE
#   MS_PER_TEST
#   TEST_PER_SWITCH
#   NUM_SWITCHES
#   NUM_MACS
#   CBENCH_WARMUP
#   CBENCH_LOG
#   results
# Arguments:
#   None
# Returns:
#   None
###############################################################################
run_cbench()
{
    get_pre_test_stats
    echo "Running CBench against ODL on $CONTROLLER_IP:$CONTROLLER_PORT"
    if "$VERBOSE" = true; then
        cbench_output=`cbench -c $CONTROLLER_IP -p $CONTROLLER_PORT -m $MS_PER_TEST -l $TESTS_PER_SWITCH -s $NUM_SWITCHES -M $NUM_MACS -w $CBENCH_WARMUP`
    else
        cbench_output=`cbench -c $CONTROLLER_IP -p $CONTROLLER_PORT -m $MS_PER_TEST -l $TESTS_PER_SWITCH -s $NUM_SWITCHES -M $NUM_MACS -w $CBENCH_WARMUP` &> /dev/null
    fi
    get_post_test_stats
    get_time_irrelevant_stats

    # Parse out average responses/sec, log/handle very rare unexplained errors
    # This logic can be removed if/when the root cause of this error is discovered and fixed
    cbench_avg=`echo "$cbench_output" | grep RESULT | awk '{print $8}' | awk -F'/' '{print $3}'`
    if [ -z "$cbench_avg" ]; then
        echo "WARNING: Rare error occurred: failed to parse avg. See $CBENCH_LOG." >&2
        echo "Run $(next_run_num) failed to record a CBench average. CBench details:" >> $CBENCH_LOG
        echo "$cbench_output" >> $CBENCH_LOG
        return
    else
        echo "Average responses/second: $cbench_avg"
        results[$(name_to_index "cbench_avg")]=$cbench_avg
    fi

    # Write results to results file
    write_results
}

###############################################################################
# Deletes OpenDaylight source (zipped and unzipped)
# Globals:
#   ODL_DIR
#   ODL_ZIP_PATH
# Arguments:
#   None
# Returns:
#   None
###############################################################################
uninstall_odl()
{
    if [ -d $ODL_DIR ]; then
        echo "Removing $ODL_DIR"
        rm -rf $ODL_DIR
    fi
    if [ -f $ODL_ZIP_PATH ]; then
        echo "Removing $ODL_ZIP_PATH"
        rm -f $ODL_ZIP_PATH
    fi
}

###############################################################################
# Checks if the given feature is in list to be installed at boot
# Globals:
#   FEATURES_FILE
#   EX_OK
#   EX_NOT_FOUND
# Arguments:
#   Feature to search featuresBoot list for
# Returns:
#   EX_OK if feature already in featuresBoot list
#   EX_NOT_FOUND if feature isn't in featuresBoot list
###############################################################################
is_in_featuresBoot()
{
    feature=$1

    # Check if feature is already set to be installed at boot
    if $(grep featuresBoot= $FEATURES_FILE | grep -q $feature); then
        return $EX_OK
    else
        return $EX_NOT_FOUND
    fi
}

###############################################################################
# Adds features to be installed by Karaf at ODL boot
# Globals:
#   FEATURES_FILE
#   EX_OK
#   EX_ERR
# Arguments:
#   Feature to append to end of featuresBoot CSV list
# Returns:
#   EX_OK if feature already is installed or was successfully added
#   EX_ERR if failed to add feature to group installed at boot
###############################################################################
add_to_featuresBoot()
{
    feature=$1

    # Check if feature is already set to be installed at boot
    if is_in_featuresBoot $feature; then
        echo "$feature is already set to be installed at boot"
        return $EX_OK
    fi

    # Append feature to end of boot-install list
    sed -i "/^featuresBoot=/ s/$/,$feature/" $FEATURES_FILE

    # Check if feature was added to install list correctly
    if is_in_featuresBoot $feature; then
        echo "$feature added to features installed at boot"
        return $EX_OK
    else
        echo "ERROR: Failed to add $feature to features installed at boot"
        return $EX_ERR
    fi
}

###############################################################################
# Installs latest build of the OpenDaylight controller
# Note that the installed build is via an Integration team Jenkins job
# Globals:
#   ODL_DIR
#   VERBOSE
#   ODL_ZIP_DIR
#   BASE_DIR
#   ODL_ZIP_PATH
#   ODL_ZIP
#   EX_ERR
# Arguments:
#   None
# Returns:
#   EX_ERR if ODL install fails
###############################################################################
install_opendaylight()
{
    # Only remove unzipped code, as zip is large and unlikely to have changed.
    if [ -d $ODL_DIR ]; then
        echo "Removing $ODL_DIR"
        rm -rf $ODL_DIR
    fi

    # Install required packages
    echo "Installing OpenDaylight dependencies"
    if "$VERBOSE" = true; then
        sudo yum install -y java-1.7.0-openjdk unzip wget
    else
        sudo yum install -y java-1.7.0-openjdk unzip wget &> /dev/null
    fi

    # If we already have the zip archive, use that.
    if [ -f $ODL_ZIP_PATH ]; then
        echo "Using local $ODL_ZIP_PATH. Pass -d flag to remove."
    else
        # Grab last successful build
        echo "Downloading last successful ODL build"
        if "$VERBOSE" = true; then
            wget -P $BASE_DIR "http://nexus.opendaylight.org/content/groups/public/org/opendaylight/integration/distribution-karaf/0.2.0-Helium/$ODL_ZIP"
        else
            wget -P $BASE_DIR "http://nexus.opendaylight.org/content/groups/public/org/opendaylight/integration/distribution-karaf/0.2.0-Helium/$ODL_ZIP" &> /dev/null
        fi
    fi

    # Confirm that download was successful
    if [ ! -f $ODL_ZIP_PATH ]; then
        echo "WARNING: Failed to dl ODL. Version bumped? If so, update \$ODL_ZIP" >&2
        return $EX_ERR
    fi

    # Unzip ODL archive
    echo "Unzipping last successful ODL build"
    if "$VERBOSE" = true; then
        unzip -d $BASE_DIR $ODL_ZIP_PATH
    else
        unzip -d $BASE_DIR $ODL_ZIP_PATH &> /dev/null
    fi

    # Add required features to list installed by Karaf at ODL boot
    add_to_featuresBoot "odl-openflowplugin-flow-services"
    add_to_featuresBoot "odl-openflowplugin-drop-test"

    # TODO: Do all required Karaf config.
    # Relevant Issue: https://github.com/dfarrell07/wcbench/issues/36
    echo "FIXME: Karaf config not yet built. See issue #36." >&2
    return $EX_ERR

    # TODO: Change controller log level to ERROR. Confirm this is necessary.
    # Relevant Issue: https://github.com/dfarrell07/wcbench/issues/3
}

###############################################################################
# Checks if OpenDaylight is installed
# Globals:
#   ODL_DIR
#   EX_NOT_FOUND
# Arguments:
#   None
# Returns:
#   EX_NOT_FOUND if ODL isn't installed
#   0 if ODL is installed
###############################################################################
odl_installed()
{
    if [ ! -d $ODL_DIR ]; then
        return $EX_NOT_FOUND
    fi
}

###############################################################################
# Checks if OpenDaylight is running
# Assumes you've checked that ODL is installed
# Globals:
#   ODL_DIR
#   VERBOSE
#   EX_OK
#   EX_NOT_FOUND
# Arguments:
#   None
# Returns:
#   EX_OK if ODL is running
#   EX_NOT_FOUND if ODL isn't running
###############################################################################
odl_started()
{
    old_cwd=$PWD
    cd $ODL_DIR
    if "$VERBOSE" = true; then
        ./bin/status
    else
        ./bin/status &> /dev/null
    fi
    if [ $? = 0 ]; then
        return $EX_OK
    else
        return $EX_NOT_FOUND
    fi
    cd $old_cwd
}

###############################################################################
# Starts the OpenDaylight controller
# Pins ODL process to given number of CPUs if `$processors` is non-zero
# Makes call to issue ODL config once ODL is up and running
# Globals:
#   ODL_DIR
#   EX_OK
#   processors
#   OSGI_PORT
#   VERBOSE
#   ODL_STARTUP_DELAY
# Arguments:
#   None
# Returns:
#   EX_OK if ODL is already running
###############################################################################
start_opendaylight()
{
    old_cwd=$PWD
    cd $ODL_DIR
    if odl_started; then
        echo "OpenDaylight is already running"
        return $EX_OK
    else
        echo "Starting OpenDaylight"
        if [ -z $processors ]; then
            if "$VERBOSE" = true; then
                ./bin/start
            else
                ./bin/start &> /dev/null
            fi
        else
            echo "Pinning ODL to $processors processor(s)"
            if [ $processors == 1 ]; then
                echo "Increasing ODL start time to 120s, as 1 processor will slow it down"
                ODL_STARTUP_DELAY=120
            fi
            # Use taskset to pin ODL to a given number of processors
            if "$VERBOSE" = true; then
                taskset -c 0-$(expr $processors - 1) ./bin/start
            else
                taskset -c 0-$(expr $processors - 1) ./bin/start  &> /dev/null
            fi
        fi
    fi
    cd $old_cwd
    # TODO: Smarter block until ODL is actually up
    # Relevant Issue: https://github.com/dfarrell07/wcbench/issues/6
    echo "Giving ODL $ODL_STARTUP_DELAY seconds to get up and running"
    while [ $ODL_STARTUP_DELAY -gt 0 ]; do
        sleep 10
        let ODL_STARTUP_DELAY=ODL_STARTUP_DELAY-10
        echo "$ODL_STARTUP_DELAY seconds remaining"
    done
    issue_odl_config
}

###############################################################################
# Give `dropAllPackets on` command via telnet to OSGi
# See: http://goo.gl/VEJIRc
# TODO: This can be issued too early. Smarter check needed.
# Relevant Issue: https://github.com/dfarrell07/wcbench/issues/6
# Globals:
#   VERBOSE
#   OSGI_PORT
# Arguments:
#   None
# Returns:
#   None
###############################################################################
issue_odl_config()
{
    if ! command -v telnet &> /dev/null; then
        echo "Installing telnet, as it's required for issuing ODL config."
        if "$VERBOSE" = true; then
            sudo yum install -y telnet
        else
            sudo yum install -y telnet &> /dev/null
        fi
    fi
    echo "Issuing \`dropAllPacketsRpc on\` command via telnet to localhost:$OSGI_PORT"
    # NB: Not using sleeps results in silent failures (cmd has no effect)
    (sleep 3; echo dropAllPacketsRpc on; sleep 3) | telnet localhost $OSGI_PORT
}

###############################################################################
# Stops OpenDaylight using run.sh
# TODO: Update to work with Karaf
# Globals:
#   ODL_DIR
#   VERBOSE
# Arguments:
#   None
# Returns:
#   None
###############################################################################
stop_opendaylight()
{
    old_cwd=$PWD
    cd $ODL_DIR
    if odl_started; then
        echo "Stopping OpenDaylight"
        if "$VERBOSE" = true; then
            ./run.sh -stop
        else
            ./run.sh -stop &> /dev/null
        fi
    else
        echo "OpenDaylight isn't running"
    fi
    cd $old_cwd
}

###############################################################################
# Uninstall CBench binary and the code that built it
# Globals:
#   OF_DIR
#   OFLOPS_DIR
#   CBENCH_BIN
# Arguments:
#   None
# Returns:
#   None
###############################################################################
uninstall_cbench()
{
    if [ -d $OF_DIR ]; then
        echo "Removing $OF_DIR"
        rm -rf $OF_DIR
    fi
    if [ -d $OFLOPS_DIR ]; then
        echo "Removing $OFLOPS_DIR"
        rm -rf $OFLOPS_DIR
    fi
    if [ -f $CBENCH_BIN ]; then
        echo "Removing $CBENCH_BIN"
        sudo rm -f $CBENCH_BIN
    fi
    # TODO: Remove oflops binary
    # Relevant issue: https://github.com/dfarrell07/wcbench/issues/25
}

# If executed with no options
if [ $# -eq 0 ]; then
    usage
    exit $EX_USAGE
fi

# Parse options given from command line
while getopts ":hvrcip:ot:kd" opt; do
    case "$opt" in
        h)
            # Help message
            usage
            exit $EX_OK
            ;;
        v)
            # Output debug info verbosely
            VERBOSE=true
            ;;
        r)
            # Run CBench against OpenDaylight
            if [ $CONTROLLER_IP = "localhost" ]; then
                if ! odl_installed; then
                    echo "OpenDaylight isn't installed, can't run test"
                    exit $EX_ERR
                fi
                if ! odl_started; then
                    echo "OpenDaylight isn't started, can't run test"
                    exit $EX_ERR
                fi
            fi
            run_cbench
            ;;
        c)
            # Install CBench
            install_cbench
            ;;
        i)
            # Install OpenDaylight from last successful build
            install_opendaylight
            ;;
        p)
            # Pin a given number of processors
            # Note that this option must be given before -o (start ODL)
            if odl_started; then
                echo "OpenDaylight is already running, can't adjust processors"
                exit $EX_ERR
            fi
            processors=${OPTARG}
            if [ $processors -lt 1 ]; then
                echo "Can't pin ODL to less than one processor"
                exit $EX_USAGE
            fi
            ;;
        o)
            # Run OpenDaylight from last successful build
            if ! odl_installed; then
                echo "OpenDaylight isn't installed, can't start it"
                exit $EX_ERR
            fi
            start_opendaylight
            ;;
        t)
            # Set CBench run time in minutes
            if ! odl_installed; then
                echo "OpenDaylight isn't installed, can't start it"
                exit $EX_ERR
            fi
            # Convert minutes to milliseconds
            MS_PER_TEST=$((${OPTARG} * 60 * 1000))
            TESTS_PER_SWITCH=1
            CBENCH_WARMUP=0
            echo "Set MS_PER_TEST to $MS_PER_TEST, TESTS_PER_SWITCH to $TESTS_PER_SWITCH, CBENCH_WARMUP to $CBENCH_WARMUP"
            ;;
        k)
            # Kill OpenDaylight
            if ! odl_installed; then
                echo "OpenDaylight isn't installed, can't stop it"
                exit $EX_ERR
            fi
            if ! odl_started; then
                echo "OpenDaylight isn't started, can't stop it"
                exit $EX_ERR
            fi
            stop_opendaylight
            ;;
        d)
            # Delete local ODL and CBench code
            uninstall_odl
            uninstall_cbench
            ;;
        *)
            # Print usage message
            usage
            exit $EX_USAGE
    esac
done
