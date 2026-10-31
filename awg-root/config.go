package main

import (
	"bufio"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"net/netip"
	"strconv"
	"strings"
)

// Config is a parsed awg-quick / wg-quick style configuration.
type Config struct {
	PrivateKey string // base64
	ListenPort string
	Addresses  []netip.Prefix
	DNS        []netip.Addr
	MTU        int
	// Extra holds the AmneziaWG-specific interface settings already converted to UAPI "key=value" pairs, in file order.
	Extra   [][2]string
	Peers   []Peer
	Ignored []string
}

type Peer struct {
	PublicKey    string // base64
	PresharedKey string // base64
	AllowedIPs   []netip.Prefix
	Endpoint     string // host:port as written
	Keepalive    string
}

// Interface keys that are copied verbatim into the UAPI configuration, mapped to their UAPI names.
var plainUAPIKeys = map[string]string{
	"jc": "jc", "jmin": "jmin", "jmax": "jmax",
	"s1": "s1", "s2": "s2", "s3": "s3", "s4": "s4",
	"h1": "h1", "h2": "h2", "h3": "h3", "h4": "h4",
	"i1": "i1", "i2": "i2", "i3": "i3", "i4": "i4", "i5": "i5",
	"contentpaddingaddition": "content_padding_addition",
	"rekeyaftertime":         "rekey_after_time",
	"rekeytimeout":           "rekey_timeout",
	"rejectaftertime":        "reject_after_time",
	"keepalivetimeout":       "keepalive_timeout",
	"maxhandshakeattempts":   "max_handshake_attempts",
}

var boolUAPIKeys = map[string]string{
	"randomtrailers": "random_trailers",
	"disablecookies": "disable_cookies",
}

// wg-quick keys that only make sense for the shell implementation; they are skipped.
var ignoredKeys = map[string]bool{
	"table": true, "preup": true, "postup": true, "predown": true, "postdown": true,
	"saveconfig": true, "fwmark": true,
}

func keyToHex(b64 string) (string, error) {
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(b64))
	if err != nil || len(raw) != 32 {
		return "", fmt.Errorf("invalid key %q", b64)
	}
	return hex.EncodeToString(raw), nil
}

func uapiBool(v string) string {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "on", "1", "true", "t", "yes":
		return "1"
	}
	return "0"
}

func splitList(v string) []string {
	var out []string
	for _, p := range strings.Split(v, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

func parsePrefix(s string) (netip.Prefix, error) {
	if strings.Contains(s, "/") {
		return netip.ParsePrefix(s)
	}
	a, err := netip.ParseAddr(s)
	if err != nil {
		return netip.Prefix{}, err
	}
	return netip.PrefixFrom(a, a.BitLen()), nil
}

// ParseConfig parses the configuration file contents.
func ParseConfig(r io.Reader) (*Config, error) {
	cfg := &Config{}
	section := ""
	var peer *Peer
	flush := func() {
		if peer != nil {
			cfg.Peers = append(cfg.Peers, *peer)
			peer = nil
		}
	}
	sc := bufio.NewScanner(r)
	lineNo := 0
	for sc.Scan() {
		lineNo++
		line := sc.Text()
		if i := strings.IndexByte(line, '#'); i >= 0 {
			line = line[:i]
		}
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		switch strings.ToLower(line) {
		case "[interface]":
			flush()
			section = "interface"
			continue
		case "[peer]":
			flush()
			section = "peer"
			peer = &Peer{}
			continue
		}
		eq := strings.IndexByte(line, '=')
		if eq < 0 {
			return nil, fmt.Errorf("line %d: invalid line %q", lineNo, line)
		}
		key := strings.ToLower(strings.TrimSpace(line[:eq]))
		val := strings.TrimSpace(line[eq+1:])
		switch section {
		case "interface":
			switch {
			case key == "privatekey":
				cfg.PrivateKey = val
			case key == "listenport":
				cfg.ListenPort = val
			case key == "address":
				for _, item := range splitList(val) {
					p, err := parsePrefix(item)
					if err != nil {
						return nil, fmt.Errorf("line %d: bad address %q", lineNo, item)
					}
					cfg.Addresses = append(cfg.Addresses, p)
				}
			case key == "dns":
				for _, item := range splitList(val) {
					if a, err := netip.ParseAddr(item); err == nil {
						cfg.DNS = append(cfg.DNS, a)
					} // search domains are not supported and silently skipped
				}
			case key == "mtu":
				n, err := strconv.Atoi(val)
				if err != nil {
					return nil, fmt.Errorf("line %d: bad MTU %q", lineNo, val)
				}
				cfg.MTU = n
			case key == "headerprotectionkey":
				h, err := keyToHex(val)
				if err != nil {
					return nil, fmt.Errorf("line %d: %v", lineNo, err)
				}
				cfg.Extra = append(cfg.Extra, [2]string{"header_protection_key", h})
			case plainUAPIKeys[key] != "":
				cfg.Extra = append(cfg.Extra, [2]string{plainUAPIKeys[key], val})
			case boolUAPIKeys[key] != "":
				cfg.Extra = append(cfg.Extra, [2]string{boolUAPIKeys[key], uapiBool(val)})
			case ignoredKeys[key]:
				cfg.Ignored = append(cfg.Ignored, key)
			default:
				return nil, fmt.Errorf("line %d: unrecognized interface key %q", lineNo, key)
			}
		case "peer":
			switch key {
			case "publickey":
				peer.PublicKey = val
			case "presharedkey":
				peer.PresharedKey = val
			case "allowedips":
				for _, item := range splitList(val) {
					p, err := parsePrefix(item)
					if err != nil {
						return nil, fmt.Errorf("line %d: bad allowed IP %q", lineNo, item)
					}
					peer.AllowedIPs = append(peer.AllowedIPs, p)
				}
			case "endpoint":
				peer.Endpoint = val
			case "persistentkeepalive":
				peer.Keepalive = val
			default:
				if ignoredKeys[key] {
					cfg.Ignored = append(cfg.Ignored, key)
				} else {
					return nil, fmt.Errorf("line %d: unrecognized peer key %q", lineNo, key)
				}
			}
		default:
			return nil, fmt.Errorf("line %d: key outside of a section", lineNo)
		}
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	flush()
	if cfg.PrivateKey == "" {
		return nil, fmt.Errorf("missing PrivateKey")
	}
	if len(cfg.Peers) == 0 {
		return nil, fmt.Errorf("missing [Peer]")
	}
	return cfg, nil
}

// UAPI renders the cross-platform configuration protocol text. resolved[i] must be the "ip:port" for peer i
// ("" when the peer has no endpoint).
func (c *Config) UAPI(resolved []string) (string, error) {
	var b strings.Builder
	priv, err := keyToHex(c.PrivateKey)
	if err != nil {
		return "", err
	}
	fmt.Fprintf(&b, "private_key=%s\n", priv)
	if c.ListenPort != "" {
		fmt.Fprintf(&b, "listen_port=%s\n", c.ListenPort)
	}
	for _, kv := range c.Extra {
		fmt.Fprintf(&b, "%s=%s\n", kv[0], kv[1])
	}
	b.WriteString("replace_peers=true\n")
	for i, p := range c.Peers {
		pub, err := keyToHex(p.PublicKey)
		if err != nil {
			return "", err
		}
		fmt.Fprintf(&b, "public_key=%s\n", pub)
		if p.PresharedKey != "" {
			psk, err := keyToHex(p.PresharedKey)
			if err != nil {
				return "", err
			}
			fmt.Fprintf(&b, "preshared_key=%s\n", psk)
		}
		if i < len(resolved) && resolved[i] != "" {
			fmt.Fprintf(&b, "endpoint=%s\n", resolved[i])
		}
		ka := p.Keepalive
		if ka == "" || strings.EqualFold(ka, "off") {
			ka = "0"
		}
		fmt.Fprintf(&b, "persistent_keepalive_interval=%s\n", ka)
		if len(p.AllowedIPs) > 0 {
			b.WriteString("replace_allowed_ips=true\n")
			for _, a := range p.AllowedIPs {
				fmt.Fprintf(&b, "allowed_ip=%s\n", a.String())
			}
		}
	}
	return b.String(), nil
}
