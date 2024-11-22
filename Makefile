SHELL=/bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.ONESHELL:
.DELETE_ON_ERROR:
# .SECONDARY:

MAKEFLAGS += --warn-undefined-variables
MAKEFLAGS += --no-builtin-rules
MAKEFLAGS += --silent

IMAGE     := ghcr.io/grantmacken/zie-toolbox
CONTAINER := zie-toolbox-working-container
DEPS := gcc gcc-c++ glibc-devel ncurses-devel openssl-devel libevent-devel readline-devel gettext-devel

default: from-tbx deps luajit luarocks nlua

from-tbx: info/tbx.info
info/tbx.info:
	echo '##[ $@ ]##'
	mkdir -p $(dir $@)
	podman images | grep -oP '$(IMAGE)' || buildah pull $(IMAGE):latest | tee  $@
	buildah from  $(IMAGE) | tee -a $@

# luarocks:info/deps.info info/luajit.info info/luarocks.info

deps: info/deps.info
info/deps.info:
	echo '##[ $@ ]##'
	mkdir -p $(dir $@)
	for item in $(DEPS)
	do
	buildah run $(CONTAINER) dnf install \
		--allowerasing \
		--skip-unavailable \
		--skip-broken \
		--no-allow-downgrade \
		-y \
		$${item} &>/dev/null
	done
	buildah run $(CONTAINER) sh -c "dnf -y info installed $(DEPS) | \
grep -oP '(Name.+:\s\K.+)|(Ver.+:\s\K.+)|(Sum.+:\s\K.+)' | \
paste - - - " | tee $@

## https://github.com/openresty/luajit2
luajit: info/luajit.info

latest/luajit.json:
	echo '##[ $@ ]##'
	mkdir -p $(dir $@)
	wget -q -O - https://api.github.com/repos/openresty/luajit2/tags |
	jq '.[0]' > $@

info/luajit.info: latest/luajit.json
	echo '##[ $@ ]##'
	NAME=$$(jq -r '.name' $< | sed 's/v//')
	URL=$$(jq -r '.tarball_url' $<)
	echo "name: $${NAME}"
	echo "url: $${URL}"
	mkdir -p files/luajit
	wget $${URL} -q -O- | tar xz --strip-components=1 -C files/luajit
	buildah run $(CONTAINER) sh -c "rm -rf /tmp/*"
	buildah add --chmod 755 $(CONTAINER) files/luajit /tmp
	buildah run $(CONTAINER) sh -c 'cd /tmp && make && make install' &>/dev/null
	buildah run $(CONTAINER) ln -sf /usr/local/bin/luajit-$${NAME} /usr/local/bin/luajit
	buildah run $(CONTAINER) ln -sf  /usr/local/bin/luajit /usr/local/bin/lua
	buildah run $(CONTAINER) ln -sf /usr/local/bin/luajit /usr/local/bin/lua-5.1
	buildah run $(CONTAINER) sh -c 'lua -v' | tee $@

luarocks: info/luarocks.info

latest/luarocks.json:
	echo '##[ $@ ]##'
	mkdir -p $(dir $@)
	wget -q -O - 'https://api.github.com/repos/luarocks/luarocks/tags' |
	jq  '.[0]' > $@

info/luarocks.info: latest/luarocks.json
	echo '##[ $@ ]##'
	buildah run $(CONTAINER) rm -rf /tmp/*
	buildah run $(CONTAINER) mkdir -p /etc/xdg/luarocks
	NAME=$$(jq -r '.name' $< | sed 's/v//')
	URL=$$(jq -r '.tarball_url' $<)
	echo "name: $${NAME}"
	echo "url: $${URL}"
	echo "waiting for download ... "
	mkdir -p files/luarocks
	wget $${URL} -q -O- | tar xz --strip-components=1 -C files/luarocks
	buildah add --chmod 755 $(CONTAINER) files/luarocks /tmp
	buildah run $(CONTAINER) sh -c "wget $${URL} -q -O- | tar xz --strip-components=1 -C /tmp"
	buildah run $(CONTAINER) sh -c 'cd /tmp && ./configure \
 --lua-version=5.1 --with-lua-interpreter=luajit \
 --sysconfdir=/etc/xdg --force-config --disable-incdir-check' &>/dev/null
	buildah run $(CONTAINER) sh -c 'cd /tmp && make && make install' &>/dev/null
	buildah run $(CONTAINER) rm -rf /tmp/*
	echo '- change system luarocks config '
	buildah run $(CONTAINER) sed -i 's%luarocks%local/share/luarocks%g' /etc/xdg/luarocks/config-5.1.lua
	buildah run $(CONTAINER) cat /etc/xdg/luarocks/config-5.1.lua
	buildah run $(CONTAINER) sh -c 'luarocks' | tee $@


nlua: info/nlua.info
info/nlua.info:
	buildah run $(CONTAINER) luarocks install nlua
	# confirm it is working
	buildah run $(CONTAINER) sh -c 'echo "print(1 + 2)" | nlua'
	buildah run $(CONTAINER) sh -c 'nlua -e "print(package.path)" '
	buildah run $(CONTAINER) sh -c 'nlua -e "print(package.cpath)" '
	buildah run $(CONTAINER) nlua -e "print(vim.fn.stdpath('data'))"
	# use nlua as lua interpreter when using luarocks
	buildah run $(CONTAINER) sed -i 's/luajit/nlua/g' /etc/xdg/luarocks/config-5.1.lua
	buildah run $(CONTAINER) nlua 
	# checks
	#


