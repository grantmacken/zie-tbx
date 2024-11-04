SHELL=/bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.ONESHELL:
.DELETE_ON_ERROR:
.SECONDARY:

MAKEFLAGS += --warn-undefined-variables
MAKEFLAGS += --no-builtin-rules
MAKEFLAGS += --silent

FEDORA_TOOLBOX    := registry.fedoraproject.org/fedora-toolbox:41
WORKING_CONTAINER := fedora-toolbox-working-container

CLI_INSTALL  := bat eza fd-find flatpak-spawn fswatch fzf gh jq rclone ripgrep wl-clipboard yq zoxide
BUILD_INSTALL := make cmake autoconf perl-File-Copy intltool
DEV_INSTALL  := gcc gcc-c++ glibc-devel ncurses-devel openssl-devel libevent-devel readline-devel gettext-devel
# gcc-c++ glibc-devel make ncurses-devel openssl-devel autoconf -y
# kitty-terminfo make cmake ncurses-devel openssl-devel perl-core libevent-devel readline-devel gettext-devel intltool

default: init cli neovim host-spawn luajit luarocks
ifdef GITHUB_ACTIONS
	buildah commit $(WORKING_CONTAINER) ghcr.io/grantmacken/tbx
	buildah push ghcr.io/grantmacken/tbx
endif

dev-gleam: dnf

# erlang

reset:
	buildah rm $(WORKING_CONTAINER) || true
	rm -rfv info
	rm -rfv latest
	rm -rfv files
	rm -rfv tmp

commit:
	podman stop tbx || true
	toolbox rm -f tbx || true
	buildah commit $(WORKING_CONTAINER) tbx
	toolbox create --image localhost/tbx tbx
	toolbox init-container tbx

###############################################

init: info/working.info

info/working.info:
	echo '##[ $@ ]##'
	mkdir -p $(dir $@)
	podman images | grep -oP '$(FEDORA_TOOLBOX)' || buildah pull $(FEDORA_TOOLBOX) | tee  $@
	buildah containers | grep -oP $(WORKING_CONTAINER) || buildah from $(FEDORA_TOOLBOX) | tee -a $@
	echo

dnf: cli-tools build-tools devel
cli-tools: info/cli.info
info/cli.info:
	echo '##[ $@ ]##'
	mkdir -p $(dir $@)
	for item in $(CLI_INSTALL)
	do
	buildah run $(WORKING_CONTAINER) rpm -ql $${item} &>/dev/null ||
	buildah run $(WORKING_CONTAINER) dnf install \
		--allowerasing \
		--skip-unavailable \
		--skip-broken \
		--no-allow-downgrade \
		-y \
		$${item}
	if [ "$${item}" == 'fd-find' ]
	then
	item=fd
	fi
	if [ "$${item}" == 'ripgrep' ]
	then
	item=rg
	fi
	buildah run $(WORKING_CONTAINER) whereis $${item}
	done
	buildah run $(WORKING_CONTAINER) sh -c "dnf -y info installed $(CLI_INSTALL) | \
grep -oP '(Name.+:\s\K.+)|(Ver.+:\s\K.+)|(Sum.+:\s\K.+)' | \
paste - - - " | tee $@

build-tools: info/build-tools.info
info/build-tools.info:
	echo '##[ $@ ]##'
	mkdir -p $(dir $@)
	for item in $(BUILD_INSTALL)
	do
	buildah run $(WORKING_CONTAINER) rpm -ql $${item} &>/dev/null ||
	buildah run $(WORKING_CONTAINER) dnf install \
		--allowerasing \
		--skip-unavailable \
		--skip-broken \
		--no-allow-downgrade \
		-y \
		$${item}
	done
	buildah run $(WORKING_CONTAINER) sh -c "dnf -y info installed $(BUILD_INSTALL) | \
grep -oP '(Name.+:\s\K.+)|(Ver.+:\s\K.+)|(Sum.+:\s\K.+)' | \
paste - - - " | tee $@

devel: info/devel.info
info/devel.info:
	echo '##[ $@ ]##'
	mkdir -p $(dir $@)
	for item in $(DEV_INSTALL)
	do
	buildah run $(WORKING_CONTAINER) rpm -ql $${item} &>/dev/null ||
	buildah run $(WORKING_CONTAINER) dnf install \
		--allowerasing \
		--skip-unavailable \
		--skip-broken \
		--no-allow-downgrade \
		-y \
		$${item}
	done
	buildah run $(WORKING_CONTAINER) sh -c "dnf -y info installed $(DEV_INSTALL) | \
grep -oP '(Name.+:\s\K.+)|(Ver.+:\s\K.+)|(Sum.+:\s\K.+)' | \
paste - - - " | tee $@




## NEOVIM
latest/neovim.json:
	echo '##[ $@ ]##'
	mkdir -p $(dir $@)
	wget -q -O - 'https://api.github.com/repos/neovim/neovim/releases/tags/nightly' > $@

neovim: info/neovim.info
info/neovim.info: latest/neovim.json
	echo '##[ $@ ]##'
	mkdir -p $(dir $@)
	buildah run $(WORKING_CONTAINER) sh -c "rm -rf /tmp/*"
	SRC=$$(jq  -r '.assets[].browser_download_url' $< | grep -oP '.+nvim-linux64.tar.gz$$')
	echo "source: $${SRC}"
	mkdir -p files/usr/local
	wget $${SRC} -q -O- | tar xz --strip-components=1 -C files/usr/local
	buildah add --chmod 755 $(WORKING_CONTAINER) files/usr/local /usr/local
	buildah run $(WORKING_CONTAINER) sh -c 'nvim -V1 -v' | tee $@

## HOST-SPAWN

latest/host-spawn.json:
	echo '##[ $@ ]##'
	mkdir -p $(dir $@)
	wget -q -O - https://api.github.com/repos/1player/host-spawn/releases/latest > $@

host-spawn: info/host-spawn.info
info/host-spawn.info: latest/host-spawn.json
	echo '##[ $@ ]##'
	SRC=$$(jq  -r '.assets[].browser_download_url' $< | grep -oP '.+x86_64$$')
	TARG=/usr/local/bin/host-spawn
	echo "$$SRC"
	buildah add --chmod 755 $(WORKING_CONTAINER) $${SRC} $${TARG}
	buildah run $(WORKING_CONTAINER) sh -c 'ls -al /usr/local/bin/'
	buildah run $(WORKING_CONTAINER) sh -c 'echo -n " - check: " &&  which host-spawn'
	buildah run $(WORKING_CONTAINER) sh -c 'echo -n " - check: " &&  which host-spawn'
	buildah run $(WORKING_CONTAINER) sh -c 'echo -n " - host-spawn version: " &&  host-spawn --version' | tee $@
	buildah run $(WORKING_CONTAINER) sh -c 'host-spawn --help' | tee -a $@
	echo ' - add symlinks to exectables on host using host-spawn'
	# buildah run $(WORKING_CONTAINER) /bin/bash -c 'ln -fs /usr/local/bin/host-spawn /usr/local/bin/make'
	buildah run $(WORKING_CONTAINER) /bin/bash -c 'ln -fs /usr/local/bin/host-spawn /usr/local/bin/flatpak'
	buildah run $(WORKING_CONTAINER) /bin/bash -c 'ln -fs /usr/local/bin/host-spawn /usr/local/bin/podman'
	buildah run $(WORKING_CONTAINER) /bin/bash -c 'ln -fs /usr/local/bin/host-spawn /usr/local/bin/buildah'
	buildah run $(WORKING_CONTAINER) /bin/bash -c 'ln -fs /usr/local/bin/host-spawn /usr/local/bin/systemctl'
	buildah run $(WORKING_CONTAINER) /bin/bash -c 'ln -fs /usr/local/bin/host-spawn /usr/local/bin/rpm-ostree'


## https://github.com/openresty/luajit2
latest/luajit.json:
	echo '##[ $@ ]##'
	mkdir -p $(dir $@)
	wget -q -O - https://api.github.com/repos/openresty/luajit2/tags |
	jq '.[0]' > $@

luajit: info/luajit.info
info/luajit.info: latest/luajit.json
	echo '##[ $@ ]##'
	NAME=$$(jq -r '.name' $< | sed 's/v//')
	URL=$$(jq -r '.tarball_url' $<)
	echo "name: $${NAME}"
	echo "url: $${URL}"
	mkdir -p files/luajit
	wget $${URL} -q -O- | tar xz --strip-components=1 -C files/luajit
	buildah run $(WORKING_CONTAINER) sh -c "rm -rf /tmp/*"
	buildah add --chmod 755 $(WORKING_CONTAINER) files/luajit /tmp
	buildah run $(WORKING_CONTAINER) sh -c 'cd /tmp && make && make install' &>/dev/null
	buildah run $(WORKING_CONTAINER) ln -sf /usr/local/bin/luajit-$${NAME} /usr/local/bin/luajit
	buildah run $(WORKING_CONTAINER) ln -sf  /usr/local/bin/luajit /usr/local/bin/lua
	buildah run $(WORKING_CONTAINER) ln -sf /usr/local/bin/luajit /usr/local/bin/lua-5.1
	buildah run $(WORKING_CONTAINER) sh -c 'lua -v' | tee $@

latest/luarocks.json:
	echo '##[ $@ ]##'
	mkdir -p $(dir $@)
	wget -q -O - 'https://api.github.com/repos/luarocks/luarocks/tags' |
	jq  '.[0]' > $@

luarocks: info/luarocks.info
info/luarocks.info: latest/luarocks.json
	echo '##[ $@ ]##'
	buildah run $(WORKING_CONTAINER) sh -c "rm -rf /tmp/*"
	NAME=$$(jq -r '.name' $< | sed 's/v//')
	URL=$$(jq -r '.tarball_url' $<)
	echo "name: $${NAME}"
	echo "url: $${URL}"
	echo "waiting for download ... "
	mkdir -p files/luarocks
	wget $${URL} -q -O- | tar xz --strip-components=1 -C files/luarocks
	buildah add --chmod 755 $(WORKING_CONTAINER) files/luarocks /tmp
	buildah run $(WORKING_CONTAINER) sh -c "wget $${URL} -q -O- | tar xz --strip-components=1 -C /tmp"
	buildah run $(WORKING_CONTAINER) sh -c 'cd /tmp && ./configure \
		--lua-version=5.1 \
		--with-lua-bin=/usr/local/bin \
		--with-lua-lib=/usr/local/lib/lua\
		--with-lua-include=/usr/local/include/luajit-2.1'
	buildah run $(WORKING_CONTAINER) sh -c 'cd /tmp && make && make install' &>/dev/null
	buildah run $(WORKING_CONTAINER) sh -c 'luarocks config variables.LUA_INCDIR /usr/local/include/luajit-2.1'
	buildah run $(WORKING_CONTAINER) sh -c 'luarocks' | tee $@


############################################################
### dev gleam

latest/erlang.json:
	echo '##[ $@ ]##'
	mkdir -p $(dir $@)
	wget -q -O - https://api.github.com/repos/erlang/otp/releases |
	jq  '[ .[] | select(.name | startswith("OTP 27")) ] | first' > $@

erlang: info/erlang.info
info/erlang.info: latest/erlang.json
	echo '##[ $@ ]##'
	jq -r '.tarball_url' $<
	NAME=$$(jq -r '.name' $< | sed 's/v//')
	URL=$$(jq -r '.tarball_url' $<)
	echo "name: $${NAME}"
	echo "url: $${URL}"
	echo "waiting for download ... "
	DOWNLOAD=files/$(basename $(notdir $@))
	mkdir -p $$DOWNLOAD
	wget $${URL} -q -O- | tar xz --strip-components=1 -C $$DOWNLOAD
	buildah run $(WORKING_CONTAINER) sh -c "rm -rf /tmp/*"
	buildah add --chmod 755 $(WORKING_CONTAINER) $$DOWNLOAD /tmp
	buildah run $(WORKING_CONTAINER)  /bin/bash -c 'cd /tmp && ./configure \
--without-javac --without-odbc --without-wx --without-debugger --without-observer --without-cdv --without-et'
	buildah run $(WORKING_CONTAINER)  /bin/bash -c 'cd /tmp && make && make install'
	buildah run $(WORKING_CONTAINER) sh -c 'erl -version' > $@
	echo -n 'OTP Release: ' >> $@
	buildah run $(WORKING_CONTAINER) erl -noshell -eval "erlang:display(erlang:system_info(otp_release)), halt()." >>  $@

rebar3: info/rebar3.info
info/rebar3.info:
	echo '##[ $@ ]##'
	echo "waiting for download ... "
	buildah add --chmod 755 $(WORKING_CONTAINER) https://s3.amazonaws.com/rebar3/rebar3 /usr/local/bin/rebar3
	buildah run $(WORKING_CONTAINER) ls -al /usr/local/bin/
	buildah run $(WORKING_CONTAINER) rebar3 help | tee $@
