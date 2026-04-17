# Ubuntu 24 LTS test target — systemd + SSH + Ansible prerequisites.
# Based on the geerlingguy pattern used widely for Molecule/Ansible testing.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# systemd prerequisites + the small set bootstrap.sh expects on a fresh Ubuntu.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus \
      openssh-server sudo curl ca-certificates gnupg \
      python3 python3-apt python3-pip \
      iproute2 iptables less vim \
      locales tzdata \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# Kill unneeded systemd units that just produce noise in a container.
RUN systemctl mask \
      dev-hugepages.mount \
      sys-fs-fuse-connections.mount \
      systemd-logind.service \
      getty.target \
      console-getty.service

# SSH daemon setup — host keys, run dir.
RUN mkdir -p /run/sshd \
 && ssh-keygen -A \
 && sed -i 's/^#\?UsePAM.*/UsePAM no/' /etc/ssh/sshd_config

# Generic test admin user — decoupled from whatever `admin_user` is set to in
# host_vars. test.sh overrides `admin_user=testadmin` for the test run.
RUN useradd -m -s /bin/bash -G sudo testadmin \
 && echo 'testadmin ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-testadmin \
 && chmod 0440 /etc/sudoers.d/90-testadmin

VOLUME ["/sys/fs/cgroup", "/tmp", "/run", "/run/lock"]
STOPSIGNAL SIGRTMIN+3
CMD ["/lib/systemd/systemd"]
