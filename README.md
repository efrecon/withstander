# Withstander

Withstander is a docker container for improved stability to keep containers from
running amok and using too many resources. This is to be used on-top of Docker
builtin capabilities for e.g. constraining [resources] for particular
containers, and builds upon the idea that a container that is using too many
resources is probably not healthy and should be taken acted upon.

  [resources]: https://docs.docker.com/config/containers/resource_constraints/

## Example

Provided you have docker setup and running on your machine, running the
following command would arrange to restart any container that have used more
than 96% of the CPU resources for the past 10 seconds.  Note that this binds the
local Docker socket into the container so that it can communicate with the
Docker daemon using its [API].

  [API]: https://docs.docker.com/engine/api/v1.30/#operation/ContainerStats

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