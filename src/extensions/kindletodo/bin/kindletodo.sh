#!/bin/sh
#
# KindleTodo device-side helper (busybox ash). Invoked by KUAL.
#
#   open          start KOReader straight into the todo editor
#   start|stop    start/stop the sleep hook (lasts until reboot)
#   run           (internal) the sleep hook loop itself
#   status        show hook + wallpaper status on screen
#   render        re-render the wallpaper now
#   preview       paint the wallpaper for 10 s, then return to the home screen
#   running       exit 0 if the sleep hook is running (used by the editor)
#   diagnose      write a compatibility report to /mnt/us/kindletodo/diagnostics.txt
#   uninstall     remove everything except the tasks in /mnt/us/kindletodo
#
# Nothing here writes outside /mnt/us and /var/tmp: no rootfs changes.
#
# The sleep hook blocks in `lipc-wait-event` and only wakes on powerd events,
# so it uses no CPU while you read. On goingToScreenSaver it waits for the
# stock screensaver to finish drawing, then paints the todo image over it.

# US/TMPD are overridable only for off-device testing.
US="${KINDLETODO_US:-/mnt/us}"
TMPD="${KINDLETODO_TMP:-/var/tmp}"
EXT_DIR="${US}/extensions/kindletodo"
KO_DIR="${US}/koreader"
PLUGIN_DIR="${KO_DIR}/plugins/kindletodo.koplugin"
HOME_DIR="${US}/kindletodo"
IMG="${HOME_DIR}/wallpaper.png"
PREV="${HOME_DIR}/wallpaper.prev.png"
LOG="${HOME_DIR}/kindletodo.log"
RUN_COPY="${TMPD}/kindletodo-hook.sh"
PIDFILE="${TMPD}/kindletodo-hook.pid"
FIFO="${TMPD}/kindletodo-hook.fifo"
ASLEEP="${TMPD}/kindletodo.asleep"
PAINTED="${TMPD}/kindletodo.painted"
DIAG="${HOME_DIR}/diagnostics.txt"
SCRIPTLET="${US}/documents/KindleTodo.sh"

mkdir -p "${HOME_DIR}"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') hook: $*" >>"${LOG}"
}

# Two short lines at the bottom of the screen (used from KUAL).
say() {
    [ -n "${QUIET}" ] && return 0
    usleep 150000 2>/dev/null
    eips 0 0 "                                                  " >/dev/null 2>&1
    eips 0 0 "KindleTodo: $*" >/dev/null 2>&1
}

hook_pid() {
    [ -f "${PIDFILE}" ] || return 1
    set -- $(cat "${PIDFILE}")
    [ -n "$1" ] && kill -0 "$1" 2>/dev/null && echo "$1" && return 0
    return 1
}

koreader_running() {
    # KOReader draws its own sleep screen while it is in the foreground.
    ps 2>/dev/null | grep -q "[r]eader\.lua"
}

# Paint the todo image on the framebuffer. Stock eips first; a full FBInk
# (e.g. from the KUAL/MRPI helper "libkh") as a fallback.
paint() {
    img="${IMG}"
    [ -f "${img}" ] || img="${PREV}"
    [ -f "${img}" ] || { log "no wallpaper to paint"; return 1; }
    if eips -f -g "${img}" >/dev/null 2>&1; then
        return 0
    fi
    # /mnt/us may not allow exec (vfat/fuse), so run FBInk from a /var/tmp copy.
    for fb in "${US}/libkh/bin/fbink" /usr/bin/fbink /usr/local/bin/fbink; do
        [ -f "${fb}" ] || continue
        cp -f "${fb}" "${TMPD}/kindletodo-fbink" 2>/dev/null && chmod 755 "${TMPD}/kindletodo-fbink" || continue
        if "${TMPD}/kindletodo-fbink" -q -f -c -g file="${img}" >/dev/null 2>&1; then
            return 0
        fi
    done
    log "paint failed (eips and fbink)"
    return 1
}

paint_if_asleep() {
    [ -f "${ASLEEP}" ] || return 0
    [ -f "${PAINTED}" ] && return 0
    paint && touch "${PAINTED}"
}

# Re-render only if the date or tasks changed since the last render.
refresh_if_stale() {
    [ -f "${PLUGIN_DIR}/kindletodo_cli.lua" ] && [ -f "${KO_DIR}/luajit" ] || return 0
    (cd "${KO_DIR}" && KINDLETODO_HOME="${HOME_DIR}" ./luajit \
        plugins/kindletodo.koplugin/kindletodo_cli.lua render-if-stale) >>"${LOG}" 2>&1 \
        || log "render-if-stale failed; keeping previous image"
}

paint_delay() {
    d="$(cat "${HOME_DIR}/paint_delay" 2>/dev/null)"
    case "${d}" in ''|*[!0-9]*) echo 2 ;; *) echo "${d}" ;; esac
}

on_sleep() {
    rm -f "${PAINTED}"
    touch "${ASLEEP}"
    koreader_running && return 0
    (
        refresh_if_stale
        sleep "$(paint_delay)"
        paint_if_asleep
    ) &
}

run_hook() {
    if hook_pid >/dev/null; then
        echo "already running"
        exit 0
    fi
    command -v lipc-wait-event >/dev/null 2>&1 || { log "lipc-wait-event not found; hook not started"; exit 1; }
    rm -f "${FIFO}" "${ASLEEP}" "${PAINTED}"
    mkfifo "${FIFO}" || { log "mkfifo failed"; exit 1; }
    lipc-wait-event -m com.lab126.powerd goingToScreenSaver,outOfScreenSaver,readyToSuspend >"${FIFO}" 2>/dev/null &
    LPID=$!
    echo "$$ ${LPID}" >"${PIDFILE}"
    trap 'kill ${LPID} 2>/dev/null; rm -f "${FIFO}" "${PIDFILE}" "${ASLEEP}" "${PAINTED}"; exit 0' TERM INT
    log "started (pid $$, listener ${LPID})"
    while read -r ev rest; do
        case "${ev}" in
            goingToScreenSaver) on_sleep ;;
            # Last chance before the SoC suspends: paint if the delayed job hasn't yet.
            readyToSuspend) koreader_running || paint_if_asleep ;;
            outOfScreenSaver) rm -f "${ASLEEP}" "${PAINTED}" ;;
        esac
    done <"${FIFO}"
    log "listener exited"
    rm -f "${FIFO}" "${PIDFILE}"
}

start_hook() {
    if pid="$(hook_pid)"; then
        say "sleep hook already running (${pid})"
        return 0
    fi
    # Run from /var/tmp so USB mass-storage mode (which unmounts /mnt/us)
    # doesn't pull the script out from under the shell.
    cp -f "${EXT_DIR}/bin/kindletodo.sh" "${RUN_COPY}" && chmod 755 "${RUN_COPY}"
    nohup sh "${RUN_COPY}" run >/dev/null 2>&1 &
    sleep 1
    if hook_pid >/dev/null; then say "sleep hook started"; else say "sleep hook FAILED - see kindletodo.log"; fi
}

stop_hook() {
    if [ -f "${PIDFILE}" ]; then
        set -- $(cat "${PIDFILE}")
        kill "$@" 2>/dev/null
    fi
    rm -f "${PIDFILE}" "${FIFO}" "${ASLEEP}" "${PAINTED}"
    log "stopped"
    say "sleep hook stopped"
}

render_now() {
    if [ ! -f "${KO_DIR}/luajit" ]; then say "KOReader not found"; return 1; fi
    out="$(cd "${KO_DIR}" && KINDLETODO_HOME="${HOME_DIR}" ./luajit \
        plugins/kindletodo.koplugin/kindletodo_cli.lua render 2>&1)"
    echo "${out}" >>"${LOG}"
    case "${out}" in ok*) say "wallpaper rendered" ;; *) say "render FAILED, old image kept" ;; esac
}

status() {
    if pid="$(hook_pid)"; then h="hook on"; else h="hook OFF"; fi
    if [ -f "${IMG}" ]; then w="image $(cut -d' ' -f1 "${HOME_DIR}/wallpaper.stamp" 2>/dev/null)"; else w="no image"; fi
    say "${h}, ${w}"
}

preview() {
    paint || { say "nothing to preview"; return 1; }
    sleep 10
    # Ask the framework to redraw by going to the home screen.
    lipc-set-prop com.lab126.appmgrd start app://com.lab126.booklet.home >/dev/null 2>&1
}

open_editor() {
    if [ ! -x "${KO_DIR}/koreader.sh" ] && [ ! -f "${KO_DIR}/koreader.sh" ]; then
        say "KOReader is not installed"
        return 1
    fi
    if [ ! -f "${PLUGIN_DIR}/main.lua" ]; then
        say "plugin missing in koreader/plugins"
        return 1
    fi
    # Re-arm the sleep hook after a reboot, cheaply.
    hook_pid >/dev/null || QUIET=1 start_hook
    touch "${HOME_DIR}/open.flag"
    # Same launch path as the KMC "KOReader" scriptlet, else KOReader's own script.
    if [ -x /var/local/kmc/bin/kpm ]; then
        exec /var/local/kmc/bin/kpm launch koreader --asap
    fi
    cd "${US}" && exec sh "${KO_DIR}/koreader.sh" --asap
}

diagnose() {
    {
        echo "KindleTodo diagnostics - $(date)"
        echo
        echo "== Device =="
        sn="$(cat /proc/usid 2>/dev/null)"
        echo "serial prefix:  $(echo "${sn}" | cut -c1-6)  (PW4 codes at chars 4-6: 0PP 0T1-0T7 0TJ-0TN 102 103 16Q-16V)"
        case "$(echo "${sn}" | cut -c4-6)" in
            0PP|0T1|0T2|0T3|0T4|0T5|0T6|0T7|0TJ|0TK|0TL|0TM|0TN|102|103|16Q|16R|16S|16T|16U|16V)
                echo "model:          Kindle Paperwhite 4 (10th gen), 1072x1448 - SUPPORTED" ;;
            10L|0WF|0WG|0WH|0WJ|0VB)
                echo "model:          Kindle 10th gen (2019), 600x800 - SUPPORTED" ;;
            *)  echo "model:          not in table - size taken from the editor's screen" ;;
        esac
        echo "firmware:       $(cat /etc/prettyversion.txt 2>/dev/null | head -1)"
        echo "kernel:         $(uname -r)"
        [ -e /lib/ld-linux-armhf.so.3 ] && echo "float ABI:      hard-float (FW >= 5.16.3: use koreader-kindlehf)" \
                                         || echo "float ABI:      soft-float (use koreader-kindlepw2)"
        echo "framebuffer:    $(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null) bpp $(cat /sys/class/graphics/fb0/bits_per_pixel 2>/dev/null) rotate $(cat /sys/class/graphics/fb0/rotate 2>/dev/null)"
        echo "userstore free: $(df -h /mnt/us 2>/dev/null | tail -1)"
        echo
        echo "== Jailbreak / launchers =="
        for p in /mnt/us/extensions/kual /mnt/us/documents/KUAL.azw2 /var/local/kmc/bin/kpm \
                 /mnt/us/libkh/bin/fbink /mnt/us/koreader /mnt/us/documents/KindleTodo.sh; do
            [ -e "${p}" ] && echo "present:  ${p}" || echo "absent:   ${p}"
        done
        echo
        echo "== Tools =="
        for t in lipc-wait-event lipc-get-prop lipc-set-prop eips fbink mkfifo usleep; do
            w="$(command -v "${t}" 2>/dev/null)"
            echo "${t}: ${w:-MISSING}"
        done
        echo "koreader luajit: $([ -f ${KO_DIR}/luajit ] && echo yes || echo MISSING)"
        echo "plugin:          $([ -f ${PLUGIN_DIR}/main.lua ] && echo yes || echo MISSING)"
        echo
        echo "== Power / screensaver =="
        echo "powerd state:     $(lipc-get-prop com.lab126.powerd state 2>&1)"
        echo "blanket modules:  $(lipc-get-prop com.lab126.blanket load 2>&1)"
        case "$(lipc-get-prop com.lab126.blanket load 2>/dev/null)" in
            *ad_screensaver*) echo "special offers:   YES (ads screensaver active; the hook paints over it)" ;;
            *) echo "special offers:   no" ;;
        esac
        echo "stock images:     $(ls /usr/share/blanket/screensaver 2>/dev/null | tr '\n' ' ')"
        echo
        echo "== KindleTodo =="
        if pid="$(hook_pid)"; then echo "sleep hook: running (${pid})"; else echo "sleep hook: not running"; fi
        if [ -f "${KO_DIR}/luajit" ] && [ -f "${PLUGIN_DIR}/kindletodo_cli.lua" ]; then
            (cd "${KO_DIR}" && KINDLETODO_HOME="${HOME_DIR}" ./luajit plugins/kindletodo.koplugin/kindletodo_cli.lua check 2>&1)
        fi
        echo
        echo "== Live paint test =="
        if [ -f "${IMG}" ]; then
            if eips -f -g "${IMG}" >/dev/null 2>&1; then
                echo "eips -g: OK (screen should have shown the todo image)"
            else
                echo "eips -g: FAILED"
            fi
        else
            echo "skipped: no wallpaper yet (open the editor once)"
        fi
        echo
        echo "== Last log lines =="
        tail -n 15 "${LOG}" 2>/dev/null
    } >"${DIAG}" 2>&1
    say "report: kindletodo/diagnostics.txt"
}

uninstall() {
    QUIET=1 stop_hook
    rm -f "${RUN_COPY}" "${DIAG}" "${HOME_DIR}/open.flag" "${SCRIPTLET}"
    rm -rf "${PLUGIN_DIR}"
    say "removed; tasks kept in /mnt/us/kindletodo"
    log "uninstalled"
    # Remove our own KUAL entry last.
    rm -rf "${EXT_DIR}"
}

case "$1" in
    open) open_editor ;;
    start) start_hook ;;
    stop) stop_hook ;;
    run) run_hook ;;
    status) status ;;
    render) render_now ;;
    preview) preview ;;
    running) hook_pid >/dev/null ;;
    diagnose) diagnose ;;
    uninstall) uninstall ;;
    *) echo "usage: $0 {open|start|stop|running|status|render|preview|diagnose|uninstall}"; exit 2 ;;
esac
