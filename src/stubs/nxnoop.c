// nxnoop - succeeds and does nothing.
//
// Package scripts run `uicache` to tell SpringBoard about a new app and
// `sbreload` to restart it. Neither exists inside Nyxian: this ROM's home
// screen reads /var/jb/Applications itself every time it is shown. The real
// tools (Procursus' uikittools) fail here, which would leave the package half
// installed, so the bootstrap puts this in their place.

int main(void)
{
    return 0;
}
