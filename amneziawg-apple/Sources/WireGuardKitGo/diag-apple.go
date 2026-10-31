package main

import (
	"fmt"
	"net"
	"strings"
	"time"

	"github.com/amnezia-vpn/amneziawg-go/v3/device"
	"golang.org/x/net/route"
	"golang.org/x/sys/unix"
)

/* One-shot network diagnostics for older iOS versions, written to the tunnel log. */

func startDiagnostics(logger *device.Logger, settings string) {
	go func() {
		time.Sleep(1500 * time.Millisecond)
		logInterfaces(logger)
		logRoutes(logger)
		ifi := physicalInterface()
		index := 0
		if ifi != nil {
			index = ifi.Index
		}
		// A well-formed DNS query for example.com (A), to see whether any traffic from this process gets answered.
		dnsQuery := []byte{0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
			7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 3, 'c', 'o', 'm', 0, 0x00, 0x01, 0x00, 0x01}
		for _, bound := range []int{0, index} {
			probeUDP(logger, "8.8.8.8:53", dnsQuery, bound, true)
		}
		for _, line := range strings.Split(settings, "\n") {
			if strings.HasPrefix(line, "endpoint=") {
				endpoint := strings.TrimPrefix(line, "endpoint=")
				for _, bound := range []int{0, index} {
					probeUDP(logger, endpoint, []byte{0}, bound, false)
				}
			}
		}
	}()
}

func logInterfaces(logger *device.Logger) {
	ifaces, err := net.Interfaces()
	if err != nil {
		logger.Errorf("Diag: net.Interfaces failed: %v", err)
		return
	}
	for _, ifi := range ifaces {
		addrs, _ := ifi.Addrs()
		logger.Verbosef("Diag: iface %s index=%d flags=%v mtu=%d addrs=%v", ifi.Name, ifi.Index, ifi.Flags, ifi.MTU, addrs)
	}
}

func routeAddrString(a route.Addr) string {
	switch v := a.(type) {
	case *route.Inet4Addr:
		return net.IP(v.IP[:]).String()
	case *route.Inet6Addr:
		return net.IP(v.IP[:]).String()
	case *route.LinkAddr:
		return fmt.Sprintf("link#%d", v.Index)
	case nil:
		return "-"
	}
	return fmt.Sprintf("%T", a)
}

func logRoutes(logger *device.Logger) {
	for _, family := range []int{unix.AF_INET, unix.AF_INET6} {
		rib, err := route.FetchRIB(family, route.RIBTypeRoute, 0)
		if err != nil {
			logger.Errorf("Diag: FetchRIB(%d) failed: %v", family, err)
			continue
		}
		msgs, err := route.ParseRIB(route.RIBTypeRoute, rib)
		if err != nil {
			logger.Errorf("Diag: ParseRIB(%d) failed: %v", family, err)
			continue
		}
		for _, m := range msgs {
			rm, ok := m.(*route.RouteMessage)
			if !ok || len(rm.Addrs) < 3 {
				continue
			}
			logger.Verbosef("Diag: route af=%d dst=%s gw=%s mask=%s flags=0x%x ifindex=%d",
				family, routeAddrString(rm.Addrs[0]), routeAddrString(rm.Addrs[1]), routeAddrString(rm.Addrs[2]), rm.Flags, rm.Index)
		}
	}
}

func probeUDP(logger *device.Logger, target string, payload []byte, boundIf int, wantReply bool) {
	addr, err := net.ResolveUDPAddr("udp4", target)
	if err != nil {
		logger.Errorf("Diag: probe resolve %s: %v", target, err)
		return
	}
	fd, err := unix.Socket(unix.AF_INET, unix.SOCK_DGRAM, 0)
	if err != nil {
		logger.Errorf("Diag: probe socket: %v", err)
		return
	}
	defer unix.Close(fd)
	if boundIf != 0 {
		if err := unix.SetsockoptInt(fd, unix.IPPROTO_IP, unix.IP_BOUND_IF, boundIf); err != nil {
			logger.Errorf("Diag: probe IP_BOUND_IF(%d): %v", boundIf, err)
		}
	}
	tv := unix.NsecToTimeval(int64(2 * time.Second))
	_ = unix.SetsockoptTimeval(fd, unix.SOL_SOCKET, unix.SO_RCVTIMEO, &tv)
	sa := &unix.SockaddrInet4{Port: addr.Port}
	copy(sa.Addr[:], addr.IP.To4())
	if err := unix.Sendto(fd, payload, 0, sa); err != nil {
		logger.Verbosef("Diag: probe sendto %s bound_if=%d: FAILED: %v", target, boundIf, err)
		return
	}
	if !wantReply {
		logger.Verbosef("Diag: probe sendto %s bound_if=%d: ok", target, boundIf)
		return
	}
	buf := make([]byte, 512)
	n, _, err := unix.Recvfrom(fd, buf, 0)
	if err != nil {
		logger.Verbosef("Diag: probe sendto %s bound_if=%d: sent, no reply: %v", target, boundIf, err)
		return
	}
	logger.Verbosef("Diag: probe sendto %s bound_if=%d: got %d-byte reply", target, boundIf, n)
}
