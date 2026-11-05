# Only on the first virtual console; tty2 stays a normal shell for rescue.
if [ "$(tty)" = /dev/tty1 ]; then exec /usr/local/bin/macboot-session; fi
