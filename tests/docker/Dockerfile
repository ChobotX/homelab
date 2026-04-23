# Ubuntu 24 LTS test target — systemd + SSH + Ansible prerequisites.
# Based on the geerlingguy pattern used widely for Molecule/Ansible testing.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# systemd prerequisites + the small set bootstrap.sh expects on a fresh Ubuntu,
# plus yamllint + git (git is pulled anyway by ansible-galaxy during collection
# install). Install all in one apt layer.
#
# NOTE: we intentionally keep /var/lib/apt/lists populated — the `common` role's
# `update_cache: true, cache_valid_time: 3600` check believes the cache is fresh
# (update-success-stamp is recent from this RUN) and skips apt-get update.
# If lists were removed, the next apt install would fail to resolve packages.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus \
      openssh-server sudo curl ca-certificates gnupg git \
      python3 python3-apt python3-pip python3-venv \
      iproute2 iptables less vim \
      locales tzdata yamllint \
 && apt-get clean

# Bake ansible-core + pinned collections into the image so test.sh doesn't need
# to install them on every run inside a fresh container. The COPY'd files are
# staged into the build context by tests/docker/test.sh (see build_image()).
# Layer invalidates only when .ansible-version or ansible/requirements.yml change.
COPY .ansible-version /tmp/.ansible-version
COPY requirements.yml /tmp/requirements.yml
RUN pip3 install --break-system-packages --no-cache-dir \
      "ansible-core==$(cat /tmp/.ansible-version)" \
 && ansible-galaxy collection install --force -r /tmp/requirements.yml >/dev/null \
 && rm -f /tmp/.ansible-version /tmp/requirements.yml

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

# Generic test admin user matching the config.yml stub in test.sh.
# ssh_hardening role refuses to run without a populated authorized_keys file.
RUN useradd -m -s /bin/bash -G sudo testadmin \
 && echo 'testadmin ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-testadmin \
 && chmod 0440 /etc/sudoers.d/90-testadmin \
 && install -d -m 0700 -o testadmin -g testadmin /home/testadmin/.ssh \
 && ssh-keygen -t ed25519 -N '' -f /tmp/testkey -C test >/dev/null \
 && install -m 0600 -o testadmin -g testadmin /tmp/testkey.pub /home/testadmin/.ssh/authorized_keys \
 && rm -f /tmp/testkey /tmp/testkey.pub

VOLUME ["/sys/fs/cgroup", "/tmp", "/run", "/run/lock"]
STOPSIGNAL SIGRTMIN+3
CMD ["/lib/systemd/systemd"]
