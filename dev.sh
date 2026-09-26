#!/bin/sh
# One entrypoint for the whole containerized workflow.
#   ./dev.sh build     -> compile kernel + assemble zigkernel.iso
#   ./dev.sh run        -> boot it in QEMU (serial on stdout)
#   ./dev.sh shell      -> drop into the build container
set -eu
cd "$(dirname "$0")"

ENGINE="${ENGINE:-}"
if [ -z "$ENGINE" ]; then
    if command -v podman >/dev/null 2>&1; then
        ENGINE=podman
    elif command -v docker >/dev/null 2>&1; then
        ENGINE=docker
    else
        echo "Need podman or docker installed on the host." >&2
        exit 1
    fi
fi

IMAGE=marble

if ! "$ENGINE" image exists "$IMAGE" 2>/dev/null && \
   ! "$ENGINE" image inspect "$IMAGE" >/dev/null 2>&1; then
    "$ENGINE" build -t "$IMAGE" -f Containerfile .
fi

KVM_ARGS=""
if [ -e /dev/kvm ]; then
    KVM_ARGS="--device /dev/kvm"
fi

run_container() {
    # $KVM_ARGS is left unquoted so it expands to zero arguments when empty
    # or two distinct arguments (--device and /dev/kvm) when set.
    "$ENGINE" run --rm -it $KVM_ARGS \
        -e DISPLAY="$DISPLAY" \
        -v /tmp/.X11-unix:/tmp/.X11-unix:ro \
        -v "$PWD:/work:Z" -w /work "$IMAGE" "$@"
}

case "${1:-build}" in
    build) run_container ./scripts/build.sh ;;
    run)   run_container sh -c './scripts/build.sh && ./scripts/run.sh' ;;
    shell) run_container sh ;;
    *) echo "usage: $0 {build|run|shell}" >&2; exit 1 ;;
esac
