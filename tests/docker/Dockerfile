# Test image for the tmuxkeep broker and VPS scripts. Built and run by tests/run-bats.ps1.
# Spec 12.1 lists tmux, bats, oathtool, jq, util-linux and git. openssh-server, sudo,
# shellcheck, procps, bsdutils and ca-certificates are test-only additions (plan Q14).
FROM debian:bookworm

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8

# zsh is for the laptop rc-block test (plan Review Focus 4).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bats tmux oathtool jq util-linux bsdutils git ca-certificates \
      openssh-server sudo shellcheck procps zsh \
 && rm -rf /var/lib/apt/lists/*

# A claude user and the broker's default directories, for remote-mode tests that run
# against the real default paths inside this disposable container (plan Q11).
RUN useradd -m -s /bin/bash claude \
 && mkdir -p /var/log/tmuxkeep /etc/tmuxkeep /run/sshd \
 && ssh-keygen -A

WORKDIR /src
CMD ["bats", "/src/tests/bats"]
