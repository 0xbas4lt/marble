FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    ZIG_VERSION=0.16.0 \
    LIMINE_BRANCH=v9.x-binary

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates xz-utils git make gcc libc6-dev \
        xorriso mtools qemu-system-x86 qemu-system-gui libgtk-3-0 \
    && rm -rf /var/lib/apt/lists/*

# --- Zig toolchain ---
RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
        -o /tmp/zig.tar.xz \
    && mkdir -p /opt/zig \
    && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && rm /tmp/zig.tar.xz
ENV PATH="/opt/zig:${PATH}"

# --- Limine bootloader: binary branch ships pre-built loader stages
# plus the host-side `limine` deploy tool we build here. ---
RUN git clone --branch="${LIMINE_BRANCH}" --depth=1 \
        https://github.com/limine-bootloader/limine.git /opt/limine \
    && make -C /opt/limine
ENV PATH="/opt/limine:${PATH}"

WORKDIR /work
CMD ["/bin/bash"]
