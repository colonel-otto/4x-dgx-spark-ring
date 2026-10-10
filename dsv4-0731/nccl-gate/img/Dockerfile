# Before building: ssh-keygen -q -t ed25519 -N "" -f ntkey   (key stays local; .gitignore). Rebuild ntests24:eugr
# before reuse: images built before 2026-10-10 contain a key that was briefly in this repo.
FROM eugr/spark-vllm-b12x:latest
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openmpi-bin libopenmpi3t64 openssh-client openssh-server && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /var/run/sshd /root/.ssh && chmod 700 /root/.ssh && ssh-keygen -A && \
    printf 'Port 2299\nPermitRootLogin yes\nPubkeyAuthentication yes\nPasswordAuthentication no\nStrictModes no\nAcceptEnv *\n' > /etc/ssh/sshd_config.d/nt.conf
COPY ntkey.pub /root/.ssh/authorized_keys
COPY ntkey /root/.ssh/id_ed25519
RUN chmod 600 /root/.ssh/id_ed25519 /root/.ssh/authorized_keys && printf 'Host *\n  Port 2299\n  StrictHostKeyChecking no\n  UserKnownHostsFile /dev/null\n  LogLevel ERROR\n' > /root/.ssh/config
ENTRYPOINT ["/usr/sbin/sshd","-D","-e"]
