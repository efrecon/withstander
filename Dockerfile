FROM efrecon/mini-tcl
MAINTAINER Emmanuel Frecon <efrecon@gmail.com>

# Ensure we have socat since nc on busybox does not support UNIX
# domain sockets.
RUN apk add --no-cache socat git && \
    git clone https://github.com/efrecon/docker-client /tmp/docker-client && \
    mkdir -p /opt/withstander/docker && \
    mv /tmp/docker-client/docker /opt/withstander/docker/ && \
    apk del git && \
    rm -rf /tmp/docker-client

# COPY code and documentation
COPY *.md /opt/withstander/
COPY *.tcl /opt/withstander/

# Export where we will look for the Docker UNIX socket.
VOLUME ["/var/run/docker.sock"]

ENTRYPOINT ["tclsh8.6", "/opt/withstander/withstander.tcl", "-docker", "unix:///var/run/docker.sock"]
CMD ["-verbose", "INFO"]