FROM debian:bookworm-slim

# Base tools needed to exercise install.sh's own logic (git for submodules,
# sudo for ensure_installed's apt-get path, zsh as the shell install.sh
# targets) plus zsh/git/vim itself.
RUN apt-get update && apt-get install -y --no-install-recommends \
		zsh \
		git \
		curl \
		ca-certificates \
		sudo \
		vim \
	&& rm -rf /var/lib/apt/lists/*

# Non-root user with passwordless sudo, mirroring a real workstation account
# (install.sh's ensure_installed shells out to `sudo apt-get ...`).
RUN useradd --create-home --shell /bin/zsh tester \
	&& echo "tester ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/tester \
	&& chmod 0440 /etc/sudoers.d/tester

COPY entrypoint.sh /usr/local/bin/dotfiles-test-entrypoint
RUN chmod +x /usr/local/bin/dotfiles-test-entrypoint

ENTRYPOINT ["/usr/local/bin/dotfiles-test-entrypoint"]
