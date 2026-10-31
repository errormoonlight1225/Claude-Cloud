//go:build darwin

// awg-root runs AmneziaWG as a root daemon on jailbroken iOS, without the Network Extension framework.
package main

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime/debug"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/amnezia-vpn/amneziawg-go/v3/conn"
	"github.com/amnezia-vpn/amneziawg-go/v3/device"
	"github.com/amnezia-vpn/amneziawg-go/v3/tun"
)

const (
	configDir  = "/etc/amneziawg"
	runDir     = "/var/run/awg-root"
	pidFile    = runDir + "/pid"
	readyFile  = runDir + "/ready"
	statusFile = runDir + "/status"
	logFile    = "/var/log/awg-root.log"
	dnsKey     = "State:/Network/Service/AmneziaWG/DNS"
)

func usage() {
	fmt.Fprintf(os.Stderr, `usage:
  awg-root up <name|path>   start the tunnel (name = %s/<name>.conf)
  awg-root down             stop the tunnel
  awg-root status           show handshake and traffic
  awg-root list             list configs in %s
  awg-root import <name>    store the config read from stdin as <name>
  awg-root delete <name>    delete a stored config
  awg-root log              show the end of the daemon log
`, configDir, configDir)
	os.Exit(2)
}

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	// Don't pass descriptors inherited from whoever launched us (e.g. the app's output pipe) on to the
	// long-running daemon, or the launcher would wait for EOF forever.
	for fd := 3; fd < 256; fd++ {
		syscall.CloseOnExec(fd)
	}
	if os.Geteuid() != 0 {
		fail("must be run as root (try: su, or sudo)")
	}
	// Installed setuid root so the GUI app can drive it. Unprivileged callers may only use stored configs by name.
	callerIsRoot := os.Getuid() == 0
	if !callerIsRoot {
		if err := syscall.Setgid(0); err != nil {
			fail("setgid: " + err.Error())
		}
		if err := syscall.Setuid(0); err != nil {
			fail("setuid: " + err.Error())
		}
	}
	nameArg := func() string {
		if len(os.Args) != 3 {
			usage()
		}
		if !validName(os.Args[2]) {
			fail("invalid config name " + strconv.Quote(os.Args[2]) + " (use letters, digits, '_', '-', '.')")
		}
		return os.Args[2]
	}
	var err error
	switch os.Args[1] {
	case "up":
		if len(os.Args) != 3 {
			usage()
		}
		if callerIsRoot {
			err = cmdUp(os.Args[2])
		} else {
			err = cmdUp(nameArg())
		}
	case "down":
		err = cmdDown()
	case "status":
		err = cmdStatus()
	case "list":
		err = cmdList()
	case "import":
		err = cmdImport(nameArg())
	case "delete":
		err = cmdDelete(nameArg())
	case "log":
		tailLogTo(os.Stdout, 200)
	case "daemon":
		if !callerIsRoot || len(os.Args) != 3 {
			usage()
		}
		err = runDaemon(os.Args[2])
	default:
		usage()
	}
	if err != nil {
		fail(err.Error())
	}
}

func fail(msg string) {
	fmt.Fprintln(os.Stderr, "awg-root:", msg)
	os.Exit(1)
}

func configPath(arg string) string {
	if strings.ContainsRune(arg, '/') || strings.HasSuffix(arg, ".conf") {
		return arg
	}
	return filepath.Join(configDir, arg+".conf")
}

func cmdList() error {
	matches, err := filepath.Glob(filepath.Join(configDir, "*.conf"))
	if err != nil {
		return err
	}
	for _, m := range matches {
		fmt.Println(strings.TrimSuffix(filepath.Base(m), ".conf"))
	}
	return nil
}

func cmdImport(name string) error {
	data, err := io.ReadAll(io.LimitReader(os.Stdin, 64<<10))
	if err != nil {
		return err
	}
	if _, err := ParseConfig(bytes.NewReader(data)); err != nil {
		return fmt.Errorf("not a valid config: %v", err)
	}
	if err := os.MkdirAll(configDir, 0o700); err != nil {
		return err
	}
	tmp := filepath.Join(configDir, "."+name+".tmp")
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, filepath.Join(configDir, name+".conf")); err != nil {
		os.Remove(tmp)
		return err
	}
	fmt.Println("imported", name)
	return nil
}

func cmdDelete(name string) error {
	if cfg, _ := readReady(); cfg == name {
		return errors.New(name + " is running; turn it off first")
	}
	return os.Remove(filepath.Join(configDir, name+".conf"))
}

// readReady returns the config name and interface of the running tunnel.
func readReady() (config, iface string) {
	data, err := os.ReadFile(readyFile)
	if err != nil {
		return "", ""
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	iface = strings.TrimSpace(lines[0])
	if len(lines) > 1 {
		config = strings.TrimSpace(lines[1])
	}
	return config, iface
}

func runningPid() int {
	data, err := os.ReadFile(pidFile)
	if err != nil {
		return 0
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil || pid <= 0 {
		return 0
	}
	if syscall.Kill(pid, 0) != nil {
		return 0
	}
	return pid
}

func cmdUp(arg string) error {
	path := configPath(arg)
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	_, err = ParseConfig(f)
	f.Close()
	if err != nil {
		return fmt.Errorf("%s: %v", path, err)
	}
	if pid := runningPid(); pid != 0 {
		return fmt.Errorf("already running (pid %d); run 'awg-root down' first", pid)
	}
	if err := os.MkdirAll(runDir, 0o755); err != nil {
		return err
	}
	os.Remove(readyFile)
	self, err := os.Executable()
	if err != nil {
		return err
	}
	logf, err := os.OpenFile(logFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	defer logf.Close()
	cmd := exec.Command(self, "daemon", path)
	cmd.Stdout, cmd.Stderr = logf, logf
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return err
	}
	fmt.Printf("starting tunnel from %s (pid %d)...\n", path, cmd.Process.Pid)
	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()
	deadline := time.After(20 * time.Second)
	for {
		select {
		case err := <-exited:
			tailLog(25)
			return fmt.Errorf("daemon exited during startup: %v", err)
		case <-deadline:
			tailLog(25)
			return errors.New("timed out waiting for the tunnel to come up; see " + logFile)
		case <-time.After(300 * time.Millisecond):
			if _, iface := readReady(); iface != "" {
				fmt.Printf("tunnel up on %s. Check the handshake with: awg-root status\n", iface)
				return nil
			}
		}
	}
}

func cmdDown() error {
	pid := runningPid()
	if pid == 0 {
		fmt.Println("not running")
		return nil
	}
	if err := syscall.Kill(pid, syscall.SIGTERM); err != nil {
		return err
	}
	for i := 0; i < 50; i++ {
		time.Sleep(200 * time.Millisecond)
		if syscall.Kill(pid, 0) != nil {
			fmt.Println("tunnel down")
			return nil
		}
	}
	syscall.Kill(pid, syscall.SIGKILL)
	return errors.New("daemon did not exit in time and was killed; routes may need a reboot to clear")
}

func cmdStatus() error {
	pid := runningPid()
	if pid == 0 {
		fmt.Println("not running")
		return nil
	}
	config, iface := readReady()
	before, _ := os.Stat(statusFile)
	if err := syscall.Kill(pid, syscall.SIGUSR1); err != nil {
		return err
	}
	var data []byte
	for i := 0; i < 20; i++ {
		time.Sleep(100 * time.Millisecond)
		st, err := os.Stat(statusFile)
		if err == nil && (before == nil || st.ModTime().After(before.ModTime())) {
			data, _ = os.ReadFile(statusFile)
			break
		}
	}
	fmt.Printf("config: %s\n", config)
	fmt.Printf("interface: %s (pid %d)\n", iface, pid)
	if data == nil {
		return errors.New("no status reply from daemon")
	}
	for _, line := range strings.Split(string(data), "\n") {
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		switch k {
		case "endpoint":
			fmt.Println("  endpoint:", v)
		case "last_handshake_time_sec":
			sec, _ := strconv.ParseInt(v, 10, 64)
			if sec == 0 {
				fmt.Println("  latest handshake: never")
			} else {
				fmt.Printf("  latest handshake: %s ago\n", time.Since(time.Unix(sec, 0)).Round(time.Second))
			}
		case "rx_bytes":
			fmt.Println("  received bytes:", v)
		case "tx_bytes":
			fmt.Println("  sent bytes:", v)
		}
	}
	return nil
}

func tailLog(n int) {
	fmt.Fprintln(os.Stderr, "--- last lines of", logFile, "---")
	tailLogTo(os.Stderr, n)
}

func tailLogTo(w io.Writer, n int) {
	data, err := os.ReadFile(logFile)
	if err != nil {
		fmt.Fprintln(w, "(no log yet)")
		return
	}
	lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	fmt.Fprintln(w, strings.Join(lines, "\n"))
}

// ---- daemon ----

type netState struct {
	iface      string
	hostRoutes []string // endpoint IPs that got a host route via the original gateway
	dnsSet     bool
}

func run(name string, args ...string) error {
	out, err := exec.Command(name, args...).CombinedOutput()
	msg := strings.TrimSpace(string(out))
	fmt.Printf("[#] %s %s", name, strings.Join(args, " "))
	if msg != "" {
		fmt.Printf("  -> %s", msg)
	}
	fmt.Println()
	if err != nil {
		return fmt.Errorf("%s %s: %v %s", name, strings.Join(args, " "), err, msg)
	}
	return nil
}

func resolveEndpoint(ep string) (netip.AddrPort, error) {
	host, port, err := net.SplitHostPort(ep)
	if err != nil {
		return netip.AddrPort{}, err
	}
	p, err := strconv.ParseUint(port, 10, 16)
	if err != nil {
		return netip.AddrPort{}, err
	}
	if a, err := netip.ParseAddr(host); err == nil {
		return netip.AddrPortFrom(a, uint16(p)), nil
	}
	ips, err := net.LookupIP(host)
	if err != nil {
		return netip.AddrPort{}, err
	}
	for _, want4 := range []bool{true, false} { // prefer IPv4
		for _, ip := range ips {
			if (ip.To4() != nil) == want4 {
				a, _ := netip.AddrFromSlice(ip)
				return netip.AddrPortFrom(a.Unmap(), uint16(p)), nil
			}
		}
	}
	return netip.AddrPort{}, fmt.Errorf("no address for %s", host)
}

// currentRoute asks the routing table how a destination is reached right now (before our routes exist).
func currentRoute(ip netip.Addr) (gateway, iface string) {
	family := "-inet"
	if ip.Is6() {
		family = "-inet6"
	}
	out, err := exec.Command("route", "-n", "get", family, ip.String()).Output()
	if err != nil {
		return "", ""
	}
	sc := bufio.NewScanner(strings.NewReader(string(out)))
	for sc.Scan() {
		k, v, ok := strings.Cut(strings.TrimSpace(sc.Text()), ":")
		if !ok {
			continue
		}
		switch strings.TrimSpace(k) {
		case "gateway":
			gateway = strings.TrimSpace(v)
		case "interface":
			iface = strings.TrimSpace(v)
		}
	}
	return gateway, iface
}

func setupNetwork(cfg *Config, st *netState, endpoints []netip.AddrPort) error {
	mtu := cfg.MTU
	if mtu == 0 {
		mtu = 1280
	}
	// Keep the endpoints reachable through the physical network before the tunnel takes over the default route.
	for _, ep := range endpoints {
		if !ep.IsValid() {
			continue
		}
		gw, ifname := currentRoute(ep.Addr())
		family := "-inet"
		if ep.Addr().Is6() {
			family = "-inet6"
		}
		var target []string
		switch {
		case gw != "" && !strings.HasPrefix(ifname, "utun"):
			target = []string{gw}
		case ifname != "" && !strings.HasPrefix(ifname, "utun"):
			target = []string{"-interface", ifname}
		default:
			fmt.Printf("[!] no physical route found for %s; continuing\n", ep.Addr())
			continue
		}
		add := append([]string{"-q", "-n", "add", family, "-host", ep.Addr().String()}, target...)
		err := run("route", add...)
		if err != nil {
			// A cloned host route (e.g. left behind by an earlier ping) may already exist and would later expire.
			run("route", "-q", "-n", "delete", family, "-host", ep.Addr().String())
			err = run("route", add...)
		}
		if err == nil {
			st.hostRoutes = append(st.hostRoutes, family+" "+ep.Addr().String())
		}
	}
	for _, a := range cfg.Addresses {
		var err error
		if a.Addr().Is4() {
			err = run("ifconfig", st.iface, "inet", a.String(), a.Addr().String(), "alias")
		} else {
			err = run("ifconfig", st.iface, "inet6", a.String(), "alias")
		}
		if err != nil {
			return err
		}
	}
	if err := run("ifconfig", st.iface, "mtu", strconv.Itoa(mtu), "up"); err != nil {
		return err
	}
	for _, p := range cfg.Peers {
		for _, a := range p.AllowedIPs {
			family := "-inet"
			if a.Addr().Is6() {
				family = "-inet6"
			}
			targets := []string{a.Masked().String()}
			if a.Bits() == 0 { // split the default route so the original one stays for the endpoint and LAN
				if a.Addr().Is4() {
					targets = []string{"0.0.0.0/1", "128.0.0.0/1"}
				} else {
					targets = []string{"::/1", "8000::/1"}
				}
			}
			for _, t := range targets {
				if err := run("route", "-q", "-n", "add", family, t, "-interface", st.iface); err != nil {
					fmt.Printf("[!] %v\n", err)
				}
			}
		}
	}
	if len(cfg.DNS) > 0 {
		var servers []string
		for _, d := range cfg.DNS {
			servers = append(servers, d.String())
		}
		script := fmt.Sprintf("open\nd.init\nd.add ServerAddresses * %s\nd.add SupplementalMatchDomains * \"\"\nd.add InterfaceName %s\nset %s\nquit\n",
			strings.Join(servers, " "), st.iface, dnsKey)
		cmd := exec.Command("scutil")
		cmd.Stdin = strings.NewReader(script)
		if out, err := cmd.CombinedOutput(); err != nil {
			fmt.Printf("[!] setting DNS via scutil failed: %v %s\n", err, out)
		} else {
			st.dnsSet = true
			fmt.Printf("[#] DNS set to %s\n", strings.Join(servers, ", "))
		}
	}
	return nil
}

func teardownNetwork(st *netState) {
	if st.dnsSet {
		cmd := exec.Command("scutil")
		cmd.Stdin = strings.NewReader("open\nremove " + dnsKey + "\nquit\n")
		cmd.Run()
		fmt.Println("[#] DNS removed")
	}
	for _, r := range st.hostRoutes {
		family, ip, _ := strings.Cut(r, " ")
		run("route", "-q", "-n", "delete", family, "-host", ip)
	}
	// Routes through the utun interface disappear together with the interface.
}

func runDaemon(path string) error {
	debug.SetGCPercent(25)
	os.Setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:"+os.Getenv("PATH"))
	fmt.Printf("==== %s awg-root starting with %s\n", time.Now().Format(time.RFC3339), path)
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	cfg, err := ParseConfig(f)
	f.Close()
	if err != nil {
		return err
	}
	for _, k := range cfg.Ignored {
		fmt.Printf("[!] ignoring unsupported key %q\n", k)
	}

	endpoints := make([]netip.AddrPort, len(cfg.Peers))
	resolved := make([]string, len(cfg.Peers))
	for i, p := range cfg.Peers {
		if p.Endpoint == "" {
			continue
		}
		ep, err := resolveEndpoint(p.Endpoint)
		if err != nil {
			return fmt.Errorf("resolving %s: %v", p.Endpoint, err)
		}
		endpoints[i], resolved[i] = ep, ep.String()
		fmt.Printf("[#] endpoint %s -> %s\n", p.Endpoint, ep)
	}
	uapi, err := cfg.UAPI(resolved)
	if err != nil {
		return err
	}

	mtu := cfg.MTU
	if mtu == 0 {
		mtu = 1280
	}
	tunDev, err := tun.CreateTUN("utun", mtu)
	if err != nil {
		return fmt.Errorf("creating utun: %v", err)
	}
	st := &netState{}
	if st.iface, err = tunDev.Name(); err != nil {
		tunDev.Close()
		return err
	}
	fmt.Printf("[#] created %s\n", st.iface)

	logger := device.NewLogger(device.LogLevelVerbose, "("+st.iface+") ")
	dev := device.NewDevice(tunDev, conn.NewDefaultBind(), logger)
	if err := dev.IpcSet(uapi); err != nil {
		dev.Close()
		return fmt.Errorf("applying configuration: %v", err)
	}
	if err := setupNetwork(cfg, st, endpoints); err != nil {
		teardownNetwork(st)
		dev.Close()
		return err
	}
	if err := dev.Up(); err != nil {
		teardownNetwork(st)
		dev.Close()
		return err
	}

	os.WriteFile(pidFile, []byte(strconv.Itoa(os.Getpid())+"\n"), 0o644)
	os.WriteFile(readyFile, []byte(st.iface+"\n"+strings.TrimSuffix(filepath.Base(path), ".conf")+"\n"), 0o644)
	fmt.Println("[#] tunnel is up")

	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP, syscall.SIGUSR1)
	for {
		select {
		case s := <-sigs:
			if s == syscall.SIGUSR1 {
				if text, err := dev.IpcGet(); err == nil {
					os.WriteFile(statusFile, []byte(text), 0o600)
				}
				continue
			}
			fmt.Printf("[#] received %v, shutting down\n", s)
		case <-dev.Wait():
			fmt.Println("[!] device closed unexpectedly")
		}
		teardownNetwork(st)
		dev.Close()
		os.Remove(readyFile)
		os.Remove(pidFile)
		os.Remove(statusFile)
		fmt.Println("[#] tunnel is down")
		return nil
	}
}
