
function containerd_install() {
    local src="$DIR/addons/containerd/1.3.7"

    if [ "$SKIP_CONTAINERD_INSTALL" != "1" ]; then
        containerd_binaries "$src"
        containerd_configure
        containerd_service "$src"
    fi

    containerd_configure_ctl "$src"

    # NOTE: this will not remove the proxy
    if [ -n "$PROXY_ADDRESS" ]; then
        containerd_configure_proxy
    fi

    if [ -n "$DOCKER_REGISTRY_IP" ]; then
        containerd_configure_registry "$DOCKER_REGISTRY_IP"
        if [ "$CONTAINERD_REGISTRY_CA_ADDED" = "1" ]; then
            restart_containerd
        fi
    fi

    load_images $src/images
}

function containerd_binaries() {
    local src="$1"

    if [ ! -f "$src/assets/containerd.tar.gz" ] && [ "$AIRGAP" != "1" ]; then
        mkdir -p "$src/assets"
        curl -L https://github.com/containerd/containerd/releases/download/v1.3.7/containerd-1.3.7-linux-amd64.tar.gz > "$src/assets/containerd.tar.gz"
    fi
    tar xzf "$src/assets/containerd.tar.gz" -C /usr

    if [ ! -f "$src/assets/runc" ] && [ "$AIRGAP" != "1" ]; then
        curl -L https://github.com/opencontainers/runc/releases/download/v1.0.0-rc91/runc.amd64 > "$src/assets/runc"
    fi
    chmod 0755 "$src/assets/runc"
    mv "$src/assets/runc" /usr/bin
}

function containerd_service() {
    local src="$1"

    local systemdVersion=$(systemctl --version | head -1 | awk '{ print $2 }')
    if [ $systemdVersion -ge 226 ]; then
        cp "$src/containerd.service" /etc/systemd/system/containerd.service
    else
        cat "$src/containerd.service" | sed '/TasksMax/s//# &/' > /etc/systemd/system/containerd.service
    fi

    systemctl daemon-reload
    systemctl enable containerd.service
    systemctl start containerd.service
}

function containerd_configure() {
    if [ -s "/etc/containerd/config.toml" ]; then
        return 0
    fi

    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml

    sed -i '/systemd_cgroup/d' /etc/containerd/config.toml
    cat >> /etc/containerd/config.toml <<EOF
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = true
EOF

    # Always set for joining nodes since it's passed as a flag in the generated join script, but not
    # usually set for the initial install
    if [ -n "$DOCKER_REGISTRY_IP" ]; then
        containerd_configure_registry "$DOCKER_REGISTRY_IP"
    fi
}

function containerd_configure_ctl() {
    local src="$1"

    if [ -e "/etc/crictl.yaml" ]; then
        return 0
    fi

    cp "$src/crictl.yaml" /etc/crictl.yaml
}

function containerd_registry_init() {
    if [ -z "$REGISTRY_VERSION" ]; then
        return 0
    fi

    local registryIP=$(kubectl -n kurl get service registry -o=jsonpath='{@.spec.clusterIP}' 2>/dev/null || true)
    if [ -z "$registryIP" ]; then
        kubectl -n kurl create service clusterip registry --tcp=443:443
        registryIP=$(kubectl -n kurl get service registry -o=jsonpath='{@.spec.clusterIP}')
    fi

    containerd_configure_registry "$registryIP"
    systemctl restart containerd
}

CONTAINERD_REGISTRY_CA_ADDED=0
function containerd_configure_registry() {
    local registryIP="$1"

    if grep -q "plugins.\"io.containerd.grpc.v1.cri\".registry.configs.\"${registryIP}\".tls" /etc/containerd/config.toml; then
        echo "Registry ${registryIP} TLS already configured for containerd"
        return 0
    fi

    cat >> /etc/containerd/config.toml <<EOF
[plugins."io.containerd.grpc.v1.cri".registry.configs."${registryIP}".tls]
  ca_file = "/etc/kubernetes/pki/ca.crt"
EOF

    CONTAINERD_REGISTRY_CA_ADDED=1
}

containerd_configure_proxy() {
    local previous_proxy="$(cat /etc/systemd/system/containerd.service.d/http-proxy.conf 2>/dev/null | grep -io 'https*_proxy=[^\" ]*' | awk 'BEGIN { FS="=" }; { print $2 }')"
    local previous_no_proxy="$(cat /etc/systemd/system/containerd.service.d/http-proxy.conf 2>/dev/null | grep -io 'no_proxy=[^\" ]*' | awk 'BEGIN { FS="=" }; { print $2 }')"
    if [ "$PROXY_ADDRESS" = "$previous_proxy" ] && [ "$NO_PROXY_ADDRESSES" = "$previous_no_proxy" ]; then
        return
    fi

    mkdir -p /etc/systemd/system/containerd.service.d
    local file=/etc/systemd/system/containerd.service.d/http-proxy.conf

    echo "# Generated by kURL" > $file
    echo "[Service]" >> $file

    if echo "$PROXY_ADDRESS" | grep -q "^https"; then
        echo "Environment=\"HTTPS_PROXY=${PROXY_ADDRESS}\" \"NO_PROXY=${NO_PROXY_ADDRESSES}\"" >> $file
    else
        echo "Environment=\"HTTP_PROXY=${PROXY_ADDRESS}\" \"NO_PROXY=${NO_PROXY_ADDRESSES}\"" >> $file
    fi

    restart_containerd
}

function restart_containerd() {
    systemctl daemon-reload
    systemctl restart containerd
}
