#! /usr/bin/env tclsh

set dirname [file dirname [file normalize [info script]]]
set appname [file rootname [file tail [info script]]]
lappend auto_path [file join $dirname docker]

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
foreach { arg val dsc } $prg_args {
    set WSTD($arg) $val
}
for {set eaten ""} {$eaten ne $argv} {} {
    set eaten $argv
    foreach opt [array names WSTD -*] {
        ::getopt argv $opt WSTD($opt) $WSTD($opt)
    }
}

# Remaining args? Dump help and exit
if { [llength $argv] > 0 } {
    ::help:dump "[lindex $argv 0] is an unknown command-line option!"
}

# Local constants and initial context variables.
docker verbosity $WSTD(-verbose)

set startup "Starting $appname with args\n"
foreach {k v} [array get WSTD -*] {
    append startup "\t$k:\t$v\n"
}
docker log INFO [string trim $startup] $appname


proc cname { id {dft "--"}} {
    if { [info exists ::C_$id] } {
        return "[string trimleft [lindex [dict get [set ::C_$id] names] 0] /] ($id)"
    }
    return $dft
}

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


proc collect { id { dta {}} } {    
    if { [info exists ::C_$id] && [llength $dta] } {
        # These statistics are inline with the ones shown by docker stats, see:
        # https://github.com/docker/cli/blob/master/cli/command/container/stats_helpers.go
        if { [dict get $dta memory_stats limit] != 0 } {
            dict set dta memPercent [expr {double([dict get $dta memory_stats usage])/double([dict get $dta memory_stats limit])*100.0}]
        }
        dict set dta mem [dict get $dta memory_stats usage]
        dict set dta memLimit [dict get $dta memory_stats limit]
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


proc dget {d k {dft ""}} {
    if { [dict exists $d $k] } {
        return [dict get $d $k]
    }
    return $dft
}


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


# Enumerate all running containers and start collecting statistics
proc ::refresh { } {
    global WSTD
    global appname
    
    if { $WSTD(docker) eq "" } {
        if { [catch {docker connect $WSTD(-docker) -cert $WSTD(-cert) -key $WSTD(-key)} d] } {
            docker log WARN "Cannot connect to docker at $WSTD(-docker): $d" $appname
        } else {
            set WSTD(docker) $d
        }
    }
    
    if { $WSTD(docker) ne "" } {
        if { [catch {$WSTD(docker) containers} containers] } {
            docker log WARN "Cannot collect list of containers: $containers" $appname
        } else {
            # Capture all containers and start to collect statistics (this will have no
            # effect on containers that are already under our control)
            set all [list]
            foreach c $containers {
                set id [string range [dict get $c Id] 0 11]
                
                # Create container structure if none yet, and establish
                # connection if we have a rule that matches the name of the
                # container.
                if { ! [info exists ::C_$id] } {
                    dict set ::C_$id id $id
                    dict set ::C_$id names [dget $c Names [list]]
                    dict set ::C_$id stats [list]
                    docker log INFO "Discovered new container [cname $id]" $appname
                    
                    # Connect once again to collect statistics on a regular
                    # basis.
                    dict set ::C_$id connection ""
                    foreach {ptn period xpr cmd args} $WSTD(-rules) {
                        set cid [cid $id [dict get [set ::C_$id] names] $ptn]
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
                lappend all $id
            }
            
            # Remove containers that would have disappeared, close statistics
            # collection if necessary.
            foreach c [info vars ::C_*] {
                set id [dict get [set $c] id]
                if { [lsearch $all $id] < 0 } {
                    delete $id
                }
            }
        }
    }

    if { $WSTD(-refresh) >= 0 } {
        set when [expr {int($WSTD(-refresh)*1000)}]
        after $when ::refresh
    }
}

proc mapper { d _map { lvls {} } } {
    upvar $_map map
    dict for {k v} $d {
        if { [llength $v] > 1 } {
            mapper $v map [concat $lvls $k]
        } else {
            lappend map [string trimleft [join $lvls .].$k .] $v
        }
    }
}

proc check {} {
    global WSTD
    global appname

    set now [clock seconds]    
    foreach c [info vars ::C_*] {
        set id [dict get [set $c] id]
        foreach {ptn period xpr cmd args} $WSTD(-rules) {
            set cid [cid $id [dict get [set ::C_$id] names] $ptn]
            if { $cid ne "" } {
                set match 0
                set allstats [dict get [set ::C_$id] stats]
                if { [llength $allstats] } {
                    set match 1
                    foreach {tstamp stats} $allstats {
                        if { $tstamp >= $now - $period } {
                            set map [list]
                            mapper $stats map
                            set xpr [string map $map $xpr]
                            if { [catch {expr $xpr} res] } {
                                docker log WARN "Cannot understand $xpr: $res" $appname
                            } else {
                                if { !$res } {
                                    set match 0
                                    break
                                }
                            }
                        }
                    }
                }
                
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
    
    set when [expr {int($WSTD(-period)*1000)}]
    after $when check    
}

# Start checking periodically for matching rules
set when [expr {int($WSTD(-period)*1000)}]
after $when check

# Start looking for new containers and listening to their stats
after idle refresh

vwait forever