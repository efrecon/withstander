# Withstander

[withstander] is a docker container for improved stability. It can be used to
restrain containers from running amok and using too many resources. This is to
be used on top of Docker builtin capabilities for e.g. constraining [resources]
for particular containers.  Withstander builds upon the idea that a container
that is using too many (network, CPU, memory, etc.) resources for too long is
probably not healthy and should be acted upon.

  [withstander]: https://hub.docker.com/r/efrecon/withstander/
  [resources]: https://docs.docker.com/config/containers/resource_constraints/

## Example

Provided you have docker set up and running on your machine, running the
following command would arrange to restart any container that have used more
than 96% of the CPU resources for the past 10 seconds.  Note that this binds the
local Docker socket into the container so that it can communicate with the
Docker daemon using its [stats] [API].

  [stats]: https://docs.docker.com/engine/api/v1.30/#operation/ContainerStats
  [API]: https://docs.docker.com/engine/api

````Shell
docker run -it --rm \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  efrecon/withstander \
  -rules '* 10 "cpuPercent > 96" restart ""'
````

To exercise withstander, you could run the following command, a command that
will arbitrarily spend as much time as possible computing the sum of nothing...

````Shell
docker run -it --rm --name "cpu100" --entrypoint ash alpine -c "sha1sum /dev/zero"
````

This should lead to output similar to the following from the running withstander
container.

````
[20180216 082343] [withstander] [INFO] Opened UNIX socket at /var/run/docker.sock using /usr/bin/socat
[20180216 082343] [withstander] [INFO] Discovered new container loving_brown (d241646eafc0)
[20180216 082343] [withstander] [INFO] Opened UNIX socket at /var/run/docker.sock using /usr/bin/socat
[20180216 082343] [withstander] [NOTICE] Collecting stats for container loving_brown (d241646eafc0)
[20180216 082413] [withstander] [INFO] Discovered new container cpu100 (f173a59d6de4)
[20180216 082413] [withstander] [INFO] Opened UNIX socket at /var/run/docker.sock using /usr/bin/socat
[20180216 082413] [withstander] [NOTICE] Collecting stats for container cpu100 (f173a59d6de4)
[20180216 082425] [withstander] [NOTICE] Running 'restart' on container f173a59d6de4 with arguments: 
[20180216 082435] [withstander] [INFO] Forgetting container cpu100 (f173a59d6de4)
````

These log lines witness of the following actions taken by the running
withstander container:

1. Withstander discovers itself under the name `loving_brown`, the name
   automatically associated to the container by the Docker daemon. This is
   because the first argument to the `-rules` options was `*`, a glob-style
   pattern that matches any container name.
2. Withstander will automatically start collecting statistics for the container.
3. Withstander discovers `cpu100` the other container that you would have run
   from the command-line.  This one has a specific name to be easy to spot in
   the logs.
4. Withstander will automatically start collecting statistics for `cpu100`.
5. Around 10 seconds after `cpu100` was discovered using all CPU resources, it
   is automatically restarted.  This is a result of the remaining arguments of
   the `-rules` option.
6. Withstander forgets about `cpu100` to reinitialise the statistics collection.
   When run with a positive `-refresh` option (the default), it will
   automatically re-discover the container again and start collecting statistics
   for that container.  This will lead to infinite restarts as `cpu100` was
   constructed to use all resources available.

## Principles and Internal Logic

Withstander is driven by a set of rules, given as an argument to the `-rules`
command-line option.  There can be as many set of rules as possible and these
address specific running containers through a glob-style pattern that is
continuously matched against the names of running containers on the host.  For
all matching containers, withstander will start collecting statistics using the
daemon [API], and generate a number of higher-level statistics similar to the
ones offered by the `docker stats` command.  Withstander is then able to take
actions when one or several of these metrics have matched a criteria for a given
time period.

## Options

Withstander takes a number of options and arguments on the command-line.  There
are few options, these are led by a single-dash for quicker typing while keeping
expressiveness.

### `-docker`

This should point at the URI where to reach the Docker daemon [API].  It
defaults to `unix:///var/run/docker.sock` in order to reach the local Docker
daemon on the standard UNIX socket.  To access a remote Docker daemon, use a URL
such as `tcp://localhost:2375`, for dangerous unencrypted access, or
`https://localhost:2376` for TLS encrypted access.  In the latter case, you can
combine this with the options `-cert` and `-key` to pinpoint your remote client.
For increased security when accessing the local Docker socket, it is possible to
use a [proxy].

  [proxy]: https://github.com/Tecnativa/docker-socket-proxy

### `-cert` and `-key`

Path location to the certificate, respectively key to use for TLS encrypted
communication with the daemon.

### `-rules`

This should be a 5-ary list of space separated arguments expressing rules to
control the behaviour of withstander.  Rules are groups of 5 with the following
meaning, in order:

1. Glob-style pattern matching the name (or identifier) of container(s).
2. Slash (`/`) separated timings for matches. Slashes are optional when not
   necessary. The timings specifications are, in order:
   - Integer number of seconds for expression matching to trigger the command.
   - Ratio (between `0.0` and `1.0`) of samples matching the expression to
     trigger the command. When empty this will default to the value of command
     line argument `-ratio`.
   - Integer number of seconds of a grace period. No checks will be performed
     under the grace period (+ the period), which allows containers to settle on
     resource usage during their startup phase. When empty, this defaults to the
     value of the command line argument `-grace`.
3. Expression to match against the statistics all along this period (this is
   explained further below).
4. Docker sub-command to execute. At present, this is what is supported by the
   internal low-level [Tcl](https://github.com/efrecon/docker-client)
   implementation of the Docker [API].
5. Arguments to the command. These are **not** the arguments from the `docker`
   command, but rather [API] URL parameters.

### `-refresh`

Number of seconds (defaults to 5) to check for new containers or discover
containers that have stopped running.  Specifying a negative value will turn off
continuous discovery, in which case withstander will only perform a single
container snapshot at start-up.

### `-period`

Frequency (expressed in decimal seconds) at which to check for the set of rules
controlling the behaviour of withstander. Note that this does **not** change the
pace of the statistics collection, as this is driven by the Docker Daemon
instead.  The default is to check every second, which is inline with the pace of
the daemon itself. There might be a "dead" second after container discovery
where all (CPU) statistics cannot be collected.

### `-ratio`

Default ratio of samples that should match for the collection period of each
matching rule. This defaults to `1.0`, i.e. all statistics samples must match
for the rule to trigger. The ratio is a float between `0.0` and `1.0`.

### `-grace`

Default grace period (in seconds) under which no statistics samples are
considered. This is an integer and defaults to `0`, meaning that the rules will
be considered as soon as enough statistics have been collected (i.e. as
specified by the period of the rule). The grace period can account for the fact
that containers often use more resources during startup before settling down.

### `-h`

Print down help and exit.  This is also the default behaviour when an
unrecognised option is specified.

### `-verbose`

Change the verbosity level, available levels are `CRITICAL`, `ERROR`, `WARN`,
`NOTICE`, `INFO`, `DEBUG` and `TRACE` and the default is `INFO`.  Logging occurs
by default on `stderr` so that it can be captured by the daemon and further
process using host-wide mechanisms.

## Collected Statistics and Expressions

### Statistics

Withstander collects the JSON [stats] that are provided by the running Docker
Daemon.  It is able to use these statistics directly in its mathematical
expression, joining together the JSON hierarchy using dots (`.`), so
`system_cpu_usage` which is placed under `cpu_stats` is represented by
`cpu_stats.system_cpu_usage` in expressions.

Using these statistics, withstander compute higher-level statistics that can be
also be used in expressions.  These statistics are inline with the statistics
provided by the `docker stats` command, and are, at present:

- `cpuPercent` total instantaneous CPU usage (for all CPUs alloted to the
  container).
- `mem` total number of memory used (in bytes), this is an alias for
  `memory_stats.usage`.
- `memLimit`, memory limit in number of bytes, this is an alias for
  `memory_stats.limit`.
- `memPercent` the percentage of memory used by the process right now.
- `rx` and `tx` the number of bytes received and sent on all interfaces alloted
  to the container.

### Expressions

Given the statistics described above and how they are represented above,
withstander is able to use any syntax that is allowed by the internal Tcl
[expr] syntax.

  [expr]: https://www.tcl.tk/man/tcl/TclCmd/expr.htm

## Implementation Details

[withstander] is implemented using [Tcl] and makes heavily use of the Docker API
[implementation](https://github.com/efrecon/docker-client).

If you wanted to run withstander standalone, e.g. not as a container, you will
have to arrange for a copy of the `docker` sub-folder of the client API
implementation to be present under the main directory of your copy of this
repository. You will also have an installation of `socat` or `nc` if you want to
communicate with the local Docker daemon with the UNIX socket, as Tcl has no
support for UNIX sockets by default. TLS encrypted access to (remote) daemone
requires the [TclTLS] package, but this package is usually part of most
distributions.

  [Tcl]: https://www.tcl.tk/
  [TclTLS]: https://core.tcl.tk/tcltls/wiki/Documentation