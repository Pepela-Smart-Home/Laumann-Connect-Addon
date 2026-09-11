# Laumann Connect — HAOS Supervisor Add-on.
#
# Explicits FROM, NO `ARG BUILD_FROM` and NO build.yaml: since Supervisor 2026.04.0
# the Supervisor only injects BUILD_FROM when a build.yaml exists (see
# supervisor/docker/app.py), and build.yaml itself is deprecated. Do not resurrect it.
#
# base:3.24-2026.08.0 — OCI index sha256:93ef607824e3f27e868f11b10938283a98bf880e
# d57bcf8eaa81c6c2d521f6f5 (amd64 + arm64), verified 2026-09-11. Ships bash, curl, jq,
# ca-certificates, s6-overlay 3.2.3.0, bashio 0.17.5, and sets
# S6_BEHAVIOUR_IF_STAGE2_FAILS=2 — a failing oneshot stops the container, which is
# exactly the behaviour this add-on needs. Pinned by digest (not just the tag) so a
# later re-push of the same tag upstream — the HA base images have done this before —
# can never silently change what customer supervisors build against, unlike the frpc
# binary above whose checksum is already enforced at build time.
FROM ghcr.io/home-assistant/base:3.24-2026.08.0@sha256:93ef607824e3f27e868f11b10938283a98bf880ed57bcf8eaa81c6c2d521f6f5

# BUILD_ARCH is passed by the Supervisor on every add-on build
# (supervisor/docker/app.py: build_args["BUILD_ARCH"] = self.arch, unconditionally).
# The uname fallback only matters for a manual `docker build` during development.
ARG BUILD_ARCH=""

# frp 0.61.1 mirrors the frps pin in Pepela-Cloud/docker-compose.yml
# (snowdreamtech/frps:0.61.1, identical in docker-compose.multi-customer.yml).
# No sibling repo pins an frpc version anywhere — "the same version as the other end
# of the cable" is the deliberate choice here, NOT "whatever is newest" (upstream is
# on 0.71.x). Both SHA-256 sums verified against the release's checksum file
# (2026-09-11).
ARG FRP_VERSION="0.61.1"
ARG FRP_SHA256_AMD64="bff260b68ca7b1461182a46c4f34e9709ba32764eed30a15dd94ac97f50a2c40"
ARG FRP_SHA256_ARM64="af6366f2b43920ebfe6235dba6060770399ed1fb18601e5818552bd46a7621f8"

RUN set -eu; \
    arch="${BUILD_ARCH}"; \
    if [ -z "${arch}" ]; then \
      case "$(uname -m)" in \
        x86_64)        arch="amd64" ;; \
        aarch64|arm64) arch="aarch64" ;; \
        *) echo "Unsupported host arch $(uname -m)" >&2; exit 1 ;; \
      esac; \
    fi; \
    case "${arch}" in \
      amd64)   frp_arch="amd64"; frp_sha="${FRP_SHA256_AMD64}" ;; \
      aarch64) frp_arch="arm64"; frp_sha="${FRP_SHA256_ARM64}" ;; \
      *) echo "Unsupported BUILD_ARCH '${arch}'" >&2; exit 1 ;; \
    esac; \
    tarball="frp_${FRP_VERSION}_linux_${frp_arch}.tar.gz"; \
    curl -fsSL --proto '=https' --proto-redir '=https' -o "/tmp/${tarball}" \
      "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${tarball}"; \
    echo "${frp_sha}  /tmp/${tarball}" | sha256sum -c -; \
    tar -xzf "/tmp/${tarball}" -C /tmp; \
    install -m 0755 "/tmp/frp_${FRP_VERSION}_linux_${frp_arch}/frpc" /usr/bin/frpc; \
    rm -rf "/tmp/frp_${FRP_VERSION}_linux_${frp_arch}" "/tmp/${tarball}"; \
    install -d -m 0700 /etc/frp

COPY rootfs /

# Explicitly set the executable bit: a checkout under Windows or a restrictive umask
# loses it, and a non-executable s6-rc `run` script is a silent startup failure.
RUN chmod 0755 /etc/s6-overlay/s6-rc.d/pairing/run \
               /etc/s6-overlay/s6-rc.d/frpc/run \
               /etc/s6-overlay/s6-rc.d/frpc/finish \
 && chmod 0644 /usr/lib/laumann-connect/pairing.sh

# NO CMD: services run as s6-rc services under the base image's /init entrypoint.
# A CMD would start an unwanted additional process alongside them.

LABEL io.hass.name="Laumann Connect" \
      io.hass.type="addon" \
      io.hass.arch="aarch64|amd64"
