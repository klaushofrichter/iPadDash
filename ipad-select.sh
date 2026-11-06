# Sourced by deploy.sh and the ipad-screenshots skill: turns an iPad name into
# the UDIDs of the matching USB-connected iPads, one per line.
#   silver | black   the iPad with that color (both are iPad Airs, told apart
#                    by the front color the iPad reports)
#   all              every connected iPad
#   <UDID prefix>    that iPad
#   (empty)          the only connected iPad; an error if there are several

ipad_color() {
    case $(ideviceinfo -u "$1" -k DeviceColor 2>/dev/null) in
        '#e1e4e3') echo silver ;;
        '#3b3b3c') echo black ;;
        *) echo unknown ;;
    esac
}

select_ipads() {
    connected=$(idevice_id -l)
    [ -n "$connected" ] || { echo "error: no iPad connected over USB" >&2; return 1; }
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
