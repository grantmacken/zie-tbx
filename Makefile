SHELL=/bin/bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c
.DELETE_ON_ERROR:
MAKEFLAGS += --warn-undefined-variables
MAKEFLAGS += --no-builtin-rules
MAKEFLAGS += --silent

FEDORA_VER := 40
GROUP_C_DEV := "C Development Tools and Libraries"
INSTALL  := bat eza fd-find flatpak-spawn fswatch fzf gh jq kitty-terminfo ripgrep wl-clipboard yq zoxide
# include .env
default: zie-toolbox  ## build the toolbox

# https://github.com/ublue-os/toolboxes/blob/main/toolboxes/bluefin-cli/packages.bluefin-cli
wolfi: ## apk bins from wolfi-dev
	echo '##[ $@ ]##'
	CONTAINER=$$(buildah from cgr.dev/chainguard/wolfi-base:latest)
	# add apk binaries that my toolbox needs (not yet available via dnf)
	buildah run $${CONTAINER} sh -c 'apk add \
	atuin \
	google-cloud-sdk \
	starship \
	uutils'
	# buildah run $${CONTAINER} sh -c 'apk info'
	buildah run $${CONTAINER} sh -c 'apk info google-cloud-sdk'
	buildah run $${CONTAINER} sh -c 'apk info starship'
	buildah run $${CONTAINER} sh -c 'apk info uutils'
	buildah run $${CONTAINER} sh -c 'apk info atuin'
	buildah commit --rm $${CONTAINER} $@ &>/dev/null
	echo ' ------------------------------- '

latest/cosign.name:
	mkdir -p $(dir $@)
	echo -n ' - latest cosign release version: '
	wget -q -O - 'https://api.github.com/repos/sigstore/cosign/releases/latest' |
	jq  -r '.name' | tee $@

cosign: latest/cosign.name
	echo '##[ $@ ]##'
	CONTAINER=$$(buildah from cgr.dev/chainguard/wolfi-base:latest)
	buildah config --workingdir /home/nonroot $${CONTAINER}
	buildah run $${CONTAINER} sh -c 'apk add git'
	buildah run $${CONTAINER} sh -c 'wget "https://github.com/sigstore/cosign/releases/download/v2.0.0/cosign-linux-amd64"'
	buildah run $${CONTAINER} sh -c 'mv cosign-linux-amd64 /usr/local/bin/cosign'
	buildah run $${CONTAINER} sh -c 'ls -al /usr/local' || true
	buildah commit --rm $${CONTAINER} $@


latest/luarocks.name:
	mkdir -p $(dir $@)
	wget -q -O - 'https://api.github.com/repos/luarocks/luarocks/tags' | jq  -r '.[0].name' | tee $@

latest/neovim-nightly.json:
	mkdir -p $(dir $@)
	wget -q -O - 'https://api.github.com/repos/neovim/neovim/releases/tags/nightly' > $@

latest/neovim.download: latest/neovim-nightly.json
	mkdir -p $(dir $@)
	jq -r '.assets[].browser_download_url' $< | grep nvim-linux64.tar.gz  | head -1 | tee $@

neovim: latest/neovim.download
	jq -r '.tag_name' latest/neovim-nightly.json
	jq -r '.name' latest/neovim-nightly.json
	CONTAINER=$$(buildah from cgr.dev/chainguard/wolfi-base)
	buildah run $${CONTAINER} sh -c 'apk add wget'
	echo -n 'download: ' && cat $<
	cat $< | buildah run $${CONTAINER} sh -c 'cat - | wget -q -O- -i- | tar xvz -C /usr/local' &>/dev/null
	buildah run $${CONTAINER} sh -c 'ls -al /usr/local' || true
	buildah commit --rm $${CONTAINER} $@

luarocks: latest/luarocks.name
	echo '##[ $@ ]##'
	CONTAINER=$$(buildah from cgr.dev/chainguard/wolfi-base:latest)
	buildah config --workingdir /home/nonroot $${CONTAINER}
	buildah run $${CONTAINER} sh -c 'mkdir /app && apk add \
	build-base \
	readline-dev \
	autoconf \
	luajit \
	luajit-dev \
	wget'
	buildah run $${CONTAINER} sh -c 'lua -v'
	echo '##[ ----------include----------------- ]##'
	buildah run $${CONTAINER} sh -c 'ls -al /usr/include' | grep lua
	echo '##[ -----------lib ------------------- ]##'
	buildah run $${CONTAINER} sh -c 'ls /usr/lib' | grep lua
	VERSION=$(shell cat $< | cut -c 2-)
	echo "luarocks version: $${VERSION}"
	URL=https://github.com/luarocks/luarocks/archive/refs/tags/v$${VERSION}.tar.gz
	echo "luarocks URL: $${URL}"
	buildah run $${CONTAINER} sh -c "wget -qO- $${URL} | tar xvz" &>/dev/null
	buildah config --workingdir /home/nonroot/luarocks-$${VERSION} $${CONTAINER}
	buildah run $${CONTAINER} sh -c './configure \
		--with-lua=/usr/bin \
		--with-lua-bin=/usr/bin \
		--with-lua-lib=/usr/lib \
		--with-lua-include=/usr/include/lua' &>/dev/null
	buildah run $${CONTAINER} sh -c 'make & make install' &>/dev/null
	buildah run $${CONTAINER} sh -c 'which luarocks'
	buildah commit --rm $${CONTAINER} $@ &>/dev/null
	echo '-------------------------------'

zie-toolbox: neovim luarocks
	CONTAINER=$$(buildah from registry.fedoraproject.org/fedora-toolbox:$(FEDORA_VER))
	# buildah run $${CONTAINER} sh -c 'dnf group list --hidden'
	# buildah run $${CONTAINER} sh -c 'dnf group info $(GROUP_C_DEV)' || true
	buildah run $${CONTAINER} sh -c 'dnf -y group install $(GROUP_C_DEV)' &>/dev/null
	buildah run $${CONTAINER} sh -c 'which make' || true
	buildah run $${CONTAINER} sh -c 'dnf -y install $(INSTALL)' &>/dev/null
	echo ' - add cosign from sigstore release'
	SRC=https://github.com/sigstore/cosign/releases/download/v2.0.0/cosign-linux-amd64
	TARG=/usr/local/bin/cosign
	buildah add --chmod 755 $${CONTAINER} $${SRC} $${TARG}
	buildah run $${CONTAINER} sh -c 'which cosign'
	echo ' - from: bldr neovim'
	buildah add --from localhost/neovim $${CONTAINER} '/usr/local/nvim-linux64' '/usr/local/'
	buildah run $${CONTAINER} sh -c 'which nvim && nvim --version'
	echo ' - from: bldr luarocks'
	buildah add --from localhost/luarocks $${CONTAINER} '/usr/local/bin' '/usr/local/bin'
	buildah add --from localhost/luarocks $${CONTAINER} '/usr/local/share/lua' '/usr/local/share/lua'
	buildah add --from localhost/luarocks $${CONTAINER} '/usr/local/etc' '/usr/local/etc'
	buildah add --from localhost/luarocks $${CONTAINER} '/usr/local/lib' '/usr/local/lib'
	buildah add --from localhost/luarocks $${CONTAINER} '/usr/include/lua' '/usr/include/lua'
	buildah add --from localhost/luarocks $${CONTAINER} '/usr/bin/lua*' '/usr/bin/'
	buildah run $${CONTAINER} sh -c 'lua -v'
	buildah run $${CONTAINER} sh -c 'which lua'
	buildah run $${CONTAINER} sh -c 'luarocks'
	HOST_SPAWN_VERSION=$(shell wget -q -O - 'https://api.github.com/repos/1player/host-spawn/tags' | jq  -r '.[0].name')
	echo " - put into container: host-spawn: $${HOST_SPAWN_VERSION}"
	SRC=https://github.com/1player/host-spawn/releases/download/$${HOST_SPAWN_VERSION}/host-spawn-x86_64
	TARG=/usr/local/bin/host-spawn
	buildah add --chmod 755 $${CONTAINER} $${SRC} $${TARG}
	buildah run $${CONTAINER} /bin/bash -c 'which host-spawn'
	echo ' - add symlinks to exectables on host using host-spawn'
	buildah run $${CONTAINER} /bin/bash -c 'ln -fs /usr/local/bin/host-spawn /usr/local/bin/flatpak'
	buildah run $${CONTAINER} /bin/bash -c 'ln -fs /usr/local/bin/host-spawn /usr/local/bin/podman'
	buildah run $${CONTAINER} /bin/bash -c 'ln -fs /usr/local/bin/host-spawn /usr/local/bin/buildah'
	buildah run $${CONTAINER} /bin/bash -c 'ln -fs /usr/local/bin/host-spawn /usr/local/bin/systemctl'
	buildah run $${CONTAINER} /bin/bash -c 'ln -fs /usr/local/bin/host-spawn /usr/local/bin/rpm-ostree'
	buildah run $${CONTAINER} /bin/bash -c 'which host-spawn'
	buildah commit --rm $${CONTAINER} ghcr.io/grantmacken/$@
ifdef GITHUB_ACTIONS
	buildah push ghcr.io/grantmacken/$@
endif

installed.json:
	mkdir -p tmp
	echo 'Name,Version,Summary' > tmp/installed.tsv
	dnf info installed $(INSTALL) | grep -oP '(Name.+:\s\K.+)|(Ver.+:\s\K.+)|(Sum.+:\s\K.+)' |
	paste - - - |
	sed '1 i Name\tVersion\tSummary' |
	yq -p=tsv -o=json
	# >> tmp/installed.csv
	# cat tmp/installed.tsv
	# yq tmp/installed.csv -p=csv -o=json
	# paste -d, - - -  | awk '{line=line ", " $$0} NR%3==0{print substr(line,2); line=""}'
	# dnf info installed fzf jq | grep -oP '(Name.+:\s\K.+)|(Ver.+:\s\K.+)|(Sum.+:\s\K.+)' | 
	# awk '{line=line " " $$0} NR%3==0{print substr(line,2); line=""}' 
	# dnf info installed fzf jq | grep -oP '(Name.+:\s\K.+)|(Ver.+:\s\K.+)|(Sum.+:\s\K.+)' | sed 'N;N; s/\n/ /g'


bldr-rust: ## a ephemeral localhost container which builds rust executables
	echo '##[ $@ ]##'
	CONTAINER=$$(buildah from cgr.dev/chainguard/rust:latest)
	buildah run $${CONTAINER} rustc --version
	buildah run $${CONTAINER} cargo --version
	buildah run $${CONTAINER} cargo install cargo-binstall &>/dev/null
	# only install stuff not in  wolfi apk registry
	buildah run $${CONTAINER} /home/nonroot/.cargo/bin/cargo-binstall --no-confirm --no-symlinks stylua silicon tree-sitter-cli &>/dev/null
	buildah run $${CONTAINER} rm /home/nonroot/.cargo/bin/cargo-binstall
	buildah run $${CONTAINER} ls /home/nonroot/.cargo/bin/
	buildah commit --rm $${CONTAINER} $@
	echo '##[ ------------------------------- ]##'

wolfi-toolbox: wolfi neovim luarocks
	echo '##[ $@ ]##'
	CONTAINER=$$(buildah from localhost/wolfi)
	echo ' - configuration labels'
	buildah config \
	--label com.github.containers.toolbox='true' \
	--label io.containers.autoupdate='registry' \
	--label usage='This image is meant to be used with the distrobox command' \
	--label summary='a Wolfi based toolbox' \
	--label maintainer='Grant MacKenzie <grantmacken@gmail.com>' $${CONTAINER}
	echo ' - configuration enviroment'
	buildah config --env LANG=C.UTF-8 $${CONTAINER}
	echo ' - into container: distrobox-host-exec '
	SRC=https://raw.githubusercontent.com/89luca89/distrobox/main/distrobox-host-exec
	TARG=/usr/bin/distrobox-host-exec
	buildah add --chmod 755 $${CONTAINER} $${SRC} $${TARG}
	echo ' - into container: distrobox-export'
	SRC=https://raw.githubusercontent.com/89luca89/distrobox/main/distrobox-export
	TARG=/usr/bin/distrobox-export
	buildah add --chmod 755 $${CONTAINER} $${SRC} $${TARG}
	echo ' - into container: distrobox-init'
	SRC=https://raw.githubusercontent.com/89luca89/distrobox/main/distrobox-init
	TARG=/usr/bin/entrypoint
	buildah add --chmod 755 $${CONTAINER} $${SRC} $${TARG}
	echo -n ' - set var: HOST_SPAWN_VERSION '
	HOST_SPAWN_VERSION=$$(buildah run $${CONTAINER} /bin/bash -c 'grep -oP "host_spawn_version=.\K(\d+\.){2}\d+" /usr/bin/distrobox-host-exec')
	echo "$${HOST_SPAWN_VERSION}"
	echo ' - into container: host-spawn'
	SRC=https://github.com/1player/host-spawn/releases/download/$${HOST_SPAWN_VERSION}/host-spawn-x86_64
	TARG=/usr/bin/host-spawn
	buildah add --chmod 755 $${CONTAINER} $${SRC} $${TARG}
	buildah run $${CONTAINER} /bin/bash -c 'which host-spawn'
	buildah run $${CONTAINER} /bin/bash -c 'which entrypoint'
	buildah run $${CONTAINER} /bin/bash -c 'which distrobox-export'
	buildah run $${CONTAINER} /bin/bash -c 'which distrobox-host-exec'
	# https://github.com/rcaloras/bash-preexec
	echo ' - add bash-preexec'
	SRC=https://raw.githubusercontent.com/rcaloras/bash-preexec/master/bash-preexec.sh
	TARG=/usr/share/bash-prexec
	buildah add --chmod 755 $${CONTAINER} $${SRC} $${TARG}
	# buildah run $${CONTAINER} /bin/bash -c 'cd /usr/share/ && mv bash-preexec.sh bash-preexec'
	buildah run $${CONTAINER} /bin/bash -c 'ls -al /usr/share/bash-prexec'
	echo ' - add /etc/bashrc: the systemwide bash per-interactive-shell startup file'
	SRC=https://raw.githubusercontent.com/ublue-os/toolboxes/main/toolboxes/bluefin-cli/files/etc/bashrc
	TARG=/etc/bashrc
	buildah add --chmod 755 $${CONTAINER} $${SRC} $${TARG}
	echo ' - add my files to /etc/profile.d file for default settings for all users when starting a login shell'
	SRC=./files/etc/profile.d/bash_completion.sh
	TARG=/etc/profile.d/
	buildah add --chmod 755 $${CONTAINER} $${SRC} $${TARG}
	buildah run $${CONTAINER} /bin/bash -c 'ls -al /etc/profile.d/'
	echo ' - add starship config file'
	SRC=https://raw.githubusercontent.com/ublue-os/toolboxes/main/toolboxes/bluefin-cli/files/etc/starship.toml
	TARG=/etc/starship.toml
	buildah add --chmod 755 $${CONTAINER} $${SRC} $${TARG}
	buildah run $${CONTAINER} /bin/bash -c 'ls -al /etc | grep starship'
	echo ' - symlink to exectables on host'
	buildah run $${CONTAINER} /bin/bash -c 'ln -fs /usr/bin/distrobox-host-exec /usr/local/bin/flatpak'
	buildah run $${CONTAINER} /bin/bash -c 'ln -fs /usr/bin/distrobox-host-exec /usr/local/bin/podman'
	buildah run $${CONTAINER} /bin/bash -c 'ln -fs /usr/bin/distrobox-host-exec /usr/local/bin/buildah'
	buildah run $${CONTAINER} /bin/bash -c 'ln -fs /usr/bin/distrobox-host-exec /usr/local/bin/systemctl'
	buildah run $${CONTAINER} /bin/bash -c 'ln -fs /usr/bin/distrobox-host-exec /usr/local/bin/rpm-ostree'
	podman images
	echo ' - from: bldr luarocks'
	buildah add --chmod 755 --from localhost/luarocks $${CONTAINER} '/usr/local/' '/usr/local/'
	buildah add --chmod 755 --from localhost/luarocks $${CONTAINER} '/usr/include/lua' '/usr/include/'
	echo ' - from: bldr neovim'
	buildah add --from localhost/neovim $${CONTAINER} '/usr/local/nvim-linux64' '/usr/local/'
	echo ' - check some apk installed binaries'
	buildah run $${CONTAINER} /bin/bash -c 'which make && make --version'
	echo '-------------------------------'
	buildah run $${CONTAINER} /bin/bash -c 'which gh && gh --version'
	echo ' -------------------------------'
	buildah run $${CONTAINER} /bin/bash -c 'which gcloud && gcloud --version'
	echo ' -------------------------------'
	echo ' CHECK BUILT BINARY ARTIFACTS NOT FROM APK'
	echo ' --- from bldr-neovim '
	buildah run $${CONTAINER} /bin/bash -c 'which nvim && nvim --version'
	echo ' --- from bldr-luarocks '
	buildah run $${CONTAINER} /bin/bash -c 'which luarocks && luarocks'
	echo ' ==============================='
	echo ' Setup '
	echo ' --- bash instead of ash '
	buildah run $${CONTAINER} /bin/bash -c "sed -i 's%/bin/ash%/bin/bash%' /etc/passwd"
	# buildah run $${CONTAINER} /bin/bash -c 'cat /etc/passwd'
	buildah run $${CONTAINER} /bin/bash -c 'ln /bin/sh /usr/bin/sh'
	echo ' --- permissions fo su-exec'
	buildah run $${CONTAINER} /bin/bash -c 'chmod u+s /sbin/su-exec'
	echo ' -------------------------------'
	# buildah run $${CONTAINER} /bin/bash -c 'ls -al /sbin/su-exec'
	echo ' --- su-exec as sudo'
	SRC=files/sudo
	TARG=/usr/bin/sudo
	buildah add --chmod 755 $${CONTAINER} $${SRC} $${TARG}
	buildah commit --rm $${CONTAINER} ghcr.io/grantmacken/$@
	podman images
ifdef GITHUB_ACTIONS
	buildah push ghcr.io/grantmacken/$@
endif

# echo ' - from: bldr rust'
# buildah add --from localhost/bldr-rust $${CONTAINER} '/home/nonroot/.cargo/bin' '/usr/local/bin'
# buildah add --chmod 755 --from localhost/bldr-neovim $${CONTAINER} '/usr/local/bin/nvim' '/usr/local/bin/nvim'
#buildah add --from localhost/bldr-luarocks $${CONTAINER} '/usr/local/share/lua' '/usr/local/share/lua'

pull:
	podman pull ghcr.io/grantmacken/zie-toolbox:latest

run:
	# podman pull registry.fedoraproject.org/fedora-toolbox:40
	toolbox create --image ghcr.io/grantmacken/zie-toolbox tbx
	toolbox enter tbx
