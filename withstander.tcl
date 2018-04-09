#! /usr/bin/env tclsh

set dirname [file dirname [file normalize [info script]]]
set appname [file rootname [file tail [info script]]]
lappend auto_path [file join $dirname tockler]

package require docker
package require Tcl 8.5

set prg_args {
    -docker    "unix:///var/run/docker.sock" "UNIX socket for connection to docker"
    -rules     ""   "List of specifications for operations (multiple of 5, e.g. * 10 cpuPercent>95 restart)"
    -verbose   INFO "Verbose level"
    -refresh   5    "Freq. of docker container discovery"
    -period    1    "Freq. of rules checking"
    -cert      ""   "Path to certificate for TLS connections"
    -key       ""   "Path to key for TLS connections"
    -h         ""   "Print this help and exit"
}

# Dump help based on the command-line option specification and exit.
proc ::help:dump { { hdr "" } } {
    global appname
    
    if { $hdr ne "" } {
        puts $hdr
        puts ""
    }
    puts "NAME:"
    puts "\t$appname - Docker container watchdog for automatic restart, stop, etc."
    puts ""
    puts "USAGE"
    puts "\t${appname}.tcl \[options\]"
    puts ""
    puts "OPTIONS:"
    foreach { arg val dsc } $::prg_args {
        puts "\t${arg}\t$dsc (default: ${val})"
    }
    exit
}


# ::getopt -- Quick and ugly getopt
#
#      Pull an option (and value) from a list of options, typically coming from the starting
#      arguments. The option is considered a boolean (no-value) option whenever
#      no variable is pointed at to receive its value.
#
# Arguments:
#      _argv    "pointer" to list of incoming arguments
#      name     Option to extract
#      _var     "pointer" to where to place the value of option
#      default  Default value for the option when not present.
#
# Results:
#      1 if the option was present, 0 otherwise. Which is usefull for boolean
#      options.
#
# Side Effects:
#      Remove the option (and prehaps its value) from the list of arguments.
proc ::getopt {_argv name {_var ""} {default ""}} {
    upvar $_argv argv $_var var
    set pos [lsearch -regexp $argv ^$name]
    if {$pos>=0} {
        set to $pos
        if {$_var ne ""} {
            set var [lindex $argv [incr to]]
        }
        set argv [lreplace $argv $pos $to]
        return 1
    } else {
        # Did we provide a value to default?
        if {[llength [info level 0]] == 5} {set var $default}
        return 0
    }
}


# Did we ask for help at the command-line, print out all command-line
# options described above and exit.
if { [::getopt argv -h] } {
    ::help:dump
}

# Extract list of command-line options into array that will contain
# program state.  The description array contains help messages, we get
# rid of them on the way into the main program's status array.
array set WSTD {
    docker     ""
    history    -1
}
# Fill in main state array with default values of options
foreach { arg val dsc } $prg_args {
    set WSTD($arg) $val
}
# Eat all options, only the last one will be taken into account.
for {set eaten ""} {$eaten ne $argv} {} {
    set eaten $argv
    foreach opt [array names WSTD -*] {
        ::getopt argv $opt WSTD($opt) $WSTD($opt)
    }
}

# Remaining args? Dump help and exit. This will also print help when calling
# with -help.
if { [llength $argv] > 0 } {
    ::help:dump "[lindex $argv 0] is an unknown command-line option!"
}

# Verbosity setup and extra info when running with higher verbosity
docker verbosity $WSTD(-verbose)
set startup "Starting $appname with args\n"
foreach {k v} [array get WSTD -*] {
    append startup "\t$k:\t$v\n"
}
docker log INFO [string trim $startup] $appname


# cname -- Return a good container name
#
#      Provided the data storage conventions used in the program and a container
#      identifier, return a good descriptive name for that container if it is
#      known to us.
#
# Arguments:
#      id       (short) identifier of a container
#      dft      Default when container isn't known.
#
# Results:
#      Good name for container (constructed out of the (cleaned) name and the
#      identifier)
#
# Side Effects:
#      None.
proc cname { id {dft "--"}} {
    if { [info exists ::C_$id] } {
        return "[string trimleft [lindex [dict get [set ::C_$id] names] 0] /] ($id)"
    }
    return $dft
}


# delete -- Delete container and close connection
#
#      Given a known container, close connection to the container (which will
#      stop statistics collection, if any) and forget about the container.
#
# Arguments:
#      id       (short) identifier of a container
#
# Results:
#      None.
#
# Side Effects:
#      Close connection to Docker daemon that had been established for
#      collecting statistics and remove all known state for container.
proc delete { id } {
    global WSTD
    global appname
    
    set c ::C_$id
    if { [info exists $c] } {
        docker log INFO "Forgetting container [cname $id]" $appname
        set cx [dict get [set $c] connection]
        if { $cx ne "" } {
            $cx disconnect
        }
        unset $c
    }
}


# forget -- Shift time history window
#
#      Automatically remove statistics that have were collected past the maximum
#      history window. This procedure will also arrange to compute the maximum
#      history window of all containers and store this in the main state array.
#      A note about maximum history: rreally, it would be enough to store
#      history for each group of container instead, however the current
#      implementation is storing the same amount of history so that future
#      extensions can provide more features.
#
# Arguments:
#      id       (short) identifier of a container
#      when     The time now, in seconds. Empty for using system time.
#
# Results:
#      None.
#
# Side Effects:
#      Remove old statistics from main dictionary that represents the container
#      internally. This will also compute and store the maximum history for all
#      containers.
proc forget { id { when ""} } {
    global WSTD
    global appname
    
    # Compute max lookback into WSTD(history) so we know how much history to
    # save, this will really occur only once.
    if { $WSTD(history) <= 0 } {
        foreach {ptn period xpr cmd args} $WSTD(-rules) {
            if { $period > $WSTD(history) } { set WSTD(history) $period }
        }
        docker log DEBUG "Will keep at most $WSTD(history) seconds of statistics for relevant containers"
    }

    # Default to from now
    if { $when eq "" } {
        set when [clock seconds]
    }
    
    # If we know about the container, construct a new list that will only
    # contain statistics collected within the history window from "when" and
    # store that new list as the history for the container.
    if { [info exists ::C_$id] } {
        set removed 0
        set kept [list]
        foreach {tstamp stats} [dict get [set ::C_$id] stats] {
            if { $tstamp >= $when - $WSTD(history) } {
                lappend kept $tstamp $stats
            } else {
                incr removed
            }
        }
        
        dict set ::C_$id stats $kept
        if { $removed > 0 } {
            docker log DEBUG "Discarded $removed statistics samples for [cname $id]"
        }
    }
}


# collect -- Collect statistics
#
#      Collect statistics for a given and known container. Upon reception of raw
#      statistics (that have been converted to dictionaries by the Docker API
#      implementation), compute more human-friendly statistics using algorithms
#      similar to what is provided by the docker stats command.
#
# Arguments:
#      id       (short) identifier of a container
#      dta      Dictionary representation of instantaneous stats, from Docker.
#
# Results:
#      None.
#
# Side Effects:
#      Store statistics in global representation of container and arrange to
#      forget about older (uneccessary) statistics.
proc collect { id { dta {}} } {
    # Only collect for existing containers.
    if { [info exists ::C_$id] && [llength $dta] } {
        # The following continues filling the <dta> dictionary with
        # human-readable statistics. These statistics are inline with the ones
        # shown by docker stats, see:
        # https://github.com/docker/cli/blob/master/cli/command/container/stats_helpers.go
        
        # Compute memory statistics
        dict set dta memPercent 0.0
        if { [dict get $dta memory_stats limit] != 0 } {
            dict set dta memPercent [expr {double([dict get $dta memory_stats usage])/double([dict get $dta memory_stats limit])*100.0}]
        }
        dict set dta mem [dict get $dta memory_stats usage]
        dict set dta memLimit [dict get $dta memory_stats limit]

        # Compute CPU statistics
        dict set dta cpuPercent 0.0
        if { [dict exists $dta precpu_stats system_cpu_usage] && [dict exists $dta cpu_stats system_cpu_usage] } {
            set previousCPU [dict get $dta precpu_stats cpu_usage total_usage]
            set previousSystem [dict get $dta precpu_stats system_cpu_usage]
            set cpuDelta [expr {[dict get $dta cpu_stats cpu_usage total_usage]-$previousCPU}]
            set systemDelta [expr {[dict get $dta cpu_stats system_cpu_usage]-$previousSystem}]
            if { $systemDelta > 0 && $cpuDelta > 0 } {
                dict set dta cpuPercent [expr {(double($cpuDelta)/double($systemDelta))*double([llength [dict get $dta cpu_stats cpu_usage percpu_usage]])*100.0}]
            }
        }
        
        # Compute Network statistics.
        dict set dta rx 0
        dict set dta tx 0
        foreach { net vals } [dict get $dta networks] {
            dict incr dta rx [dict get $vals rx_bytes]
            dict incr dta tx [dict get $vals tx_bytes]
        }
        dict set dta pidsCurrent [dict get $dta pids_stats current]
        
        # Keep these latest stats and arrange to remove older stats that are of
        # no use.
        set now [clock seconds]
        forget $id $now
        dict lappend ::C_$id stats $now $dta
    }
}


# dget -- Enhanced dictionary get
#
#      Get a key from a dictionary if it exists, return a default value otherwise.
#
# Arguments:
#      d        Dictionary to get from
#      k        Key to extract from dictionary
#      dft      Default value when non-existing
#
# Results:
#      Return the value for the key, or the default value
#
# Side Effects:
#      None.
proc dget {d k {dft ""}} {
    if { [dict exists $d $k] } {
        return [dict get $d $k]
    }
    return $dft
}


# cid -- Match container identifier
#
#      Provided a set of names for a container, and a pattern, return the
#      container identifier it one of the names matches. This will remove any
#      leading slash from known names, and also match on the identifier (which
#      is very unlikely!).
#
# Arguments:
#      id       (short) identifier of a container
#      names    Names for container (as collected from Docker)
#      ptn      Pattern to match against the names, typically from command-line
#
# Results:
#      Identifier of the container if it matches, otherwise an empty string.
#
# Side Effects:
#      None.
proc cid { id names ptn } {
    foreach name $names {
        set name [string trimleft $name "/"]
        if { [string match $ptn $name] } {
            return $id
        }
    }

    if { [string match $ptn $id] } {
        return $id
    }
    
    return ""
}


# refresh -- Container discovery and cleanup
#
#      (Continuously) discover new containers and start collecting statistics
#      when their name matches one of the rules that have been specified at the
#      command-line. Old containers that are not running on the host are delete
#      from internal state, including any statistics collection for these
#      containers.
#
# Arguments:
#      None.
#
# Results:
#      None.
#
# Side Effects:
#      Open one new connection to the Docker daemon per container. Note that
#      when running against a UNIX domain socket, this means forking one process
#      for each container since the internal implementation relies on nc or
#      socat for communication with the Docker daemon in that case.
proc ::refresh { } {
    global WSTD
    global appname
    
    # Arrange to have a connection to the main docker daemon and store that
    # connection into the main state array.
    if { $WSTD(docker) eq "" } {
        if { [catch {docker connect $WSTD(-docker) -cert $WSTD(-cert) -key $WSTD(-key)} d] } {
            docker log WARN "Cannot connect to docker at $WSTD(-docker): $d" $appname
        } else {
            set WSTD(docker) $d
        }
    }
    
    if { $WSTD(docker) ne "" } {
        # Collect current list of containers and discover/remove
        if { [catch {$WSTD(docker) containers} containers] } {
            docker log WARN "Cannot collect list of containers: $containers" $appname
        } else {
            # Capture all containers and start to collect statistics whenever
            # relevant (this will have no effect on containers that are already
            # under our control)
            set all [list]
            foreach c $containers {
                # Make the identifier a short identifier, as the one that is
                # presented to users by all command-line tools.
                set id [string range [dict get $c Id] 0 11]
                
                # Create container structure if none yet, and establish
                # connection if we have a rule that matches the name of the
                # container.
                if { ! [info exists ::C_$id] } {
                    dict set ::C_$id id $id
                    dict set ::C_$id names [dget $c Names [list]]
                    dict set ::C_$id stats [list]
                    docker log INFO "Discovered new container [cname $id]" $appname
                    
                    # Connect once again to the Docker daemon to collect
                    # statistics on a regular basis. We have to do this as this
                    # will be a long-going HTTP stream-like reception.
                    dict set ::C_$id connection ""
                    foreach {ptn period xpr cmd args} $WSTD(-rules) {
                        set cid [cid $id [dict get [set ::C_$id] names] $ptn]
                        # This is a container that we should be watching, start
                        # collecting stats.
                        if { $cid ne "" } {
                            if { [catch {docker connect $WSTD(-docker) -cert $WSTD(-cert) -key $WSTD(-key)} d] } {
                                docker log WARN "Cannot connect to docker at $WSTD(-docker): $d" $appname
                            } else {
                                docker log NOTICE "Collecting stats for container [cname $id]" $appname
                                # Remember connection identifier for that
                                # container and start collecting data.
                                dict set ::C_$id connection $d
                                $d stats $id [list collect $id]
                            }
                            break
                        }
                    }
                }
                lappend all $id;   # Keep list of known running containers
            }
            
            # Remove containers that would have disappeared, close statistics
            # collection if necessary.
            foreach c [info vars ::C_*] {
                set id [dict get [set $c] id]
                # Containers known to us but not in the list of running
                # containers constructed above should be removed from our
                # service.
                if { [lsearch $all $id] < 0 } {
                    delete $id
                }
            }
        }
    }

    # Periodic refresh (in decimal seconds, just in case)
    if { $WSTD(-refresh) >= 0 } {
        set when [expr {int($WSTD(-refresh)*1000)}]
        after $when ::refresh
    }
}


# mapper -- Dictionary mapper
#
#      Arrange for a mapping list to contain a list of key value, where the keys
#      contain a dot-separated of the dictionary hierarchy.
#
# Arguments:
#      d        Dictionary content
#      _map     "Pointer" to map to construct
#      lvls     List of dictionary levels (when recursing)
#
# Results:
#      A list of keys and values, where the keys are dot-separated
#      representations of the dictionary hierarchy.
#
# Side Effects:
#      None.
proc mapper { d _map { lvls {} } } {
    upvar $_map map
    foreach {k v} $d {
        if { [llength $v] > 1 } {
            mapper $v map [concat $lvls $k]
        } else {
            lappend map [string trimleft [join $lvls .].$k .] $v
        }
    }
}


# check -- Check rules
#
#      Check statistics and containers against the set of matching rules and
#      call appropriate Docker command (API-level) whenver a match has occured.
#
# Arguments:
#      None.
#
# Results:
#      None.
#
# Side Effects:
#      Will operate of matching containers as of the rule specification. This
#      can involve killing, stopping, etc. containers.
proc check {} {
    global WSTD
    global appname

    # Collect current time and date from system once.
    set now [clock seconds]
    
    # Loop through containers known to us to match their names against the set
    # of rules.
    foreach c [info vars ::C_*] {
        set id [dict get [set $c] id]
        # Traverse the set of known rules to match against the name and possibly
        # triggers.
        foreach {ptn period xpr cmd args} $WSTD(-rules) {
            # We have a rule matching the name/id of the container
            set cid [cid $id [dict get [set ::C_$id] names] $ptn]
            if { $cid ne "" } {
                # No stats avaible, no match
                set match 0
                set allstats [dict get [set ::C_$id] stats]
                
                # When we have stats, excercise the expression against each
                # relevant collected statistics (for the rule period) and stop
                # as soon as it does not match (this will save us some CPU
                # cycles).
                if { [llength $allstats] } {
                    set match 1
                    foreach {tstamp stats} $allstats {
                        if { $tstamp >= $now - $period } {
                            # Map the dictionary representing the statistics to
                            # something usable, i.e. cpu_stats.system_cpu_usage.
                            set map [list]
                            mapper $stats map
                            # Map this directly into the expression to replace
                            # all occurrences of any collected and relevant
                            # stats by its value at the time of collection.
                            set xpr [string map $map $xpr]
                            # Evaluate the expression with precaution.
                            if { [catch {expr $xpr} res] } {
                                docker log WARN "Cannot understand $xpr: $res" $appname
                            } else {
                                # Break and stop at once as soon as it does not
                                # match, there isn't any purpose in continuing.
                                if { !$res } {
                                    set match 0
                                    break
                                }
                            }
                        }
                    }
                }
                
                # Expression matched. Append the identifier of the container to
                # the command coming from the rules, then any arguments that
                # would also come from the rules and request the Docker daemon
                # to execute that command, though our main connection to the
                # daemon. Using the main connection is necessary here, since all
                # other connections are used for long-going statistics
                # streaming.
                if { $match } {
                    docker log NOTICE "Running '$cmd' on container $id with arguments: $args" $appname
                    if { [catch {$WSTD(docker) $cmd $id {*}$args} val] == 0 } {
                        if { [string trim $val] ne "" } {
                            docker log INFO "$cmd returned: $val" $appname
                        }
                        # Delete statistics and info for container temporary
                        delete $id
                    } else {
                        docker log WARN "$cmd returned an error: $val" $appname
                    }                    
                }
            }
        }        
    }
    
    # Periodic refresh (in decimal seconds, just in case)
    if { $WSTD(-period) >= 0 } {
        set when [expr {int($WSTD(-period)*1000)}]
        after $when check
    }
}

# Start checking periodically for matching rules. TODO handle a once and only
# once case perhaps?
set when [expr {int($WSTD(-period)*1000)}]
after $when check

# Start looking for new containers and listening to their stats
after idle refresh

vwait forever
