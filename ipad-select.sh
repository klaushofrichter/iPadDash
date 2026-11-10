# Sourced by deploy.sh and the ipad-screenshots skill: turns an iPad name into
# the UDIDs of the matching iPads, one per line, over USB or Wi-Fi.
#   silver | black   the iPad with that color (both are iPad Airs, told apart
#                    by the front color the iPad reports)
#   all              every reachable iPad
#   <UDID prefix>    that iPad
#   (empty)          the only reachable iPad; an error if there are several
#
# Wi-Fi needs "Show this iPad when on Wi-Fi" (Finder, set once over USB) and the
# Mac on the same network. USB is used when an iPad is on both.

# "-n" for an iPad reachable only over Wi-Fi, nothing for one on USB; pass it,
# unquoted, to the libimobiledevice tools: ideviceinstaller $(ipad_link "$u") -u "$u"
ipad_link() {
    idevice_id -l | grep -qx "$1" || printf '%s' -n
}

ipad_color() {
    case $(ideviceinfo $(ipad_link "$1") -u "$1" -k DeviceColor 2>/dev/null) in
        '#e1e4e3') echo silver ;;
        '#3b3b3c') echo black ;;
        *) echo unknown ;;
    esac
}

# Other devices (an iPhone on Wi-Fi) are left out. A device that doesn't answer is
# asked once more, then left out with a warning.
is_ipad() {
    class=$(ideviceinfo $(ipad_link "$1") -u "$1" -k DeviceClass 2>/dev/null) ||
        class=$(ideviceinfo $(ipad_link "$1") -u "$1" -k DeviceClass 2>/dev/null) ||
        { echo "warning: $1 doesn't answer; left out" >&2; return 1; }
    [ "$class" = iPad ]
}

select_ipads() {
    connected=$( (idevice_id -l; idevice_id -n) | sort -u | while read -r u; do if is_ipad "$u"; then echo "$u"; fi; done)
    [ -n "$connected" ] || { echo "error: no iPad connected over USB or Wi-Fi" >&2; return 1; }
    if [ -z "${1:-}" ] && [ "$(echo "$connected" | wc -l)" -gt 1 ]; then
        echo "error: several iPads connected; name one (silver, black or all):" >&2
        for u in $connected; do echo "  $(ipad_color "$u")  $u" >&2; done
        return 1
    fi
    found=""
    for u in $connected; do
        case ${1:-all} in
            all) found="$found $u" ;;
            silver | black) [ "$(ipad_color "$u")" = "$1" ] && found="$found $u" ;;
            *) case $u in "$1"*) found="$found $u" ;; esac ;;
        esac
    done
    [ -n "$found" ] || { echo "error: no connected iPad matches '$1'" >&2; return 1; }
    for u in $found; do echo "$u"; done
}
