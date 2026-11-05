# Only on the first virtual console; tty2 stays a normal shell for rescue. The session sets
# MACBOOT_NO_SESSION=1 before dropping to a shell here, so a failed session cannot loop.
if [ "$(tty)" = /dev/tty1 ] && [ -z "${MACBOOT_NO_SESSION:-}" ]; then exec /usr/local/bin/macboot-session; fi
