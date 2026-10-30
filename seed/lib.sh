# Shared helpers for the SEED task scripts. Each command is printed with the
# machine it runs on, then run there - so the output can go into a report.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# docker compose exec needs -T when there is no terminal (output piped).
if [ -t 0 ]; then EXEC_TTY=""; else EXEC_TTY="-T"; fi
if [ -t 1 ]; then
    BOLD=$'\e[1m'; DIM=$'\e[2m'; CYAN=$'\e[36m'; RESET=$'\e[0m'
else
    BOLD=""; DIM=""; CYAN=""; RESET=""
fi

machine() {
    case "$1" in
        ca)     echo "CA 172.28.0.10" ;;
        dns)    echo "DNS 172.28.0.53" ;;
        social) echo "web server 172.28.0.20" ;;
        alice)  echo "Alice 172.28.0.100" ;;
        *)      echo "$1" ;;
    esac
}

step() { echo; echo "${BOLD}== $* ==${RESET}"; }
note() { echo "${DIM}# $*${RESET}"; }

# on <machine> '<command>' - show the command, then run it on that lab machine
on() {
    local svc=$1
    shift
    echo "${CYAN}[$(machine "$svc")]\$ $*${RESET}"
    docker compose exec $EXEC_TTY "$svc" bash -c "$*"
}

# mac '<command>' - show the command, then run it here on the Mac
mac() {
    echo "${CYAN}[Mac]\$ $*${RESET}"
    bash -c "$*"
}

pause() {
    if [ -t 0 ]; then read -r -p "${DIM}... Enter to continue${RESET}" _; fi
}
