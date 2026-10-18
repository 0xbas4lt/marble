osname := "marble"

build:
    just container ./scripts/build.sh

run: build
    just container ./scripts/run.sh

test:
    just container ./scripts/test.sh

shell:
    just container sh
    
container *args:
    #!/bin/sh
    set -eu
    
    if command -v podman >/dev/null 2>&1; then
        engine=podman
    elif command -v docker >/dev/null 2>&1; then
        engine=docker
    else
        echo "Need podman or docker installed on the host." >&2
        exit 1
    fi

    image={{osname}}.img

    if ! "$engine" image exists $image 2>/dev/null &&
       ! "$engine" image inspect $image >/dev/null 2>&1; then
        "$engine" build -t $image -f Containerfile .
    fi

    kvm_args=
    if [ -e /dev/kvm ]; then
        kvm_args="--device /dev/kvm"
    fi

    "$engine" run --rm -it $kvm_args \
        -e DISPLAY="$DISPLAY" \
        -e ZIG_GLOBAL_CACHE_DIR="/work/.zig-global-cache" \
        -v /tmp/.X11-unix:/tmp/.X11-unix:ro \
        -v "$PWD:/work:Z" \
        -w /work \
        $image \
        {{args}}

clean:
    rm -rf zig-out build

distclean: clean
    #!/bin/sh
    set -eu

    rm -rf .zig-cache .zig-global-cache

    if command -v podman >/dev/null 2>&1; then
        engine=podman
    elif command -v docker >/dev/null 2>&1; then
        engine=docker
    else
        echo "Need podman or docker installed on the host." >&2
        exit 1
    fi

    if "$engine" image inspect "{{osname}}.img" >/dev/null 2>&1; then
        "$engine" image rm "{{osname}}.img"
    fi
