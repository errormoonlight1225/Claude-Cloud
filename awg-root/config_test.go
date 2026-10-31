package main

import (
	"strings"
	"testing"
)

const sample = `[Interface]
PrivateKey = SD9EXLnTkG3ou38rDbht7epfwWPnEwM5YLrMeVWpIEQ=
Address = 10.7.0.2/24, fd00::2/64
DNS = 8.8.8.8, 8.8.4.4, example.org
MTU = 1280
Jc = 5
S1 = 10
H1 = 12345
RandomTrailers = on
PostUp = echo ignored # comment

[Peer]
PublicKey = Xm7S2jn9LqXieYhTUR8QFEFKhVqz8tHlelP4At0zoVM=
PresharedKey = bQNSih/FpRQeiskP7D0NsSXkmDvHZepMr5Ntwkcgi7c=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 64.83.14.133:51820
PersistentKeepalive = 25
`

func TestParseAndUAPI(t *testing.T) {
	cfg, err := ParseConfig(strings.NewReader(sample))
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.Addresses) != 2 || cfg.Addresses[0].String() != "10.7.0.2/24" {
		t.Fatalf("addresses: %v", cfg.Addresses)
	}
	if len(cfg.DNS) != 3-1 || cfg.DNS[0].String() != "8.8.8.8" {
		t.Fatalf("dns: %v", cfg.DNS)
	}
	if cfg.MTU != 1280 || len(cfg.Ignored) != 1 {
		t.Fatalf("mtu/ignored: %d %v", cfg.MTU, cfg.Ignored)
	}
	u, err := cfg.UAPI([]string{"64.83.14.133:51820"})
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"private_key=483f445c",
		"jc=5\n", "s1=10\n", "h1=12345\n", "random_trailers=1\n",
		"replace_peers=true\n",
		"endpoint=64.83.14.133:51820\n",
		"persistent_keepalive_interval=25\n",
		"allowed_ip=0.0.0.0/0\n", "allowed_ip=::/0\n",
	} {
		if !strings.Contains(u, want) {
			t.Errorf("UAPI missing %q:\n%s", want, u)
		}
	}
	if strings.Index(u, "private_key") > strings.Index(u, "jc=") || strings.Index(u, "jc=") > strings.Index(u, "public_key") {
		t.Errorf("unexpected key order:\n%s", u)
	}
}

func TestRejectsBadInput(t *testing.T) {
	for name, in := range map[string]string{
		"no peer":     "[Interface]\nPrivateKey = SD9EXLnTkG3ou38rDbht7epfwWPnEwM5YLrMeVWpIEQ=\n",
		"no key":      "[Interface]\nAddress = 10.0.0.2/24\n[Peer]\nPublicKey = x\n",
		"unknown key": "[Interface]\nPrivateKey = SD9EXLnTkG3ou38rDbht7epfwWPnEwM5YLrMeVWpIEQ=\nBogus = 1\n[Peer]\nPublicKey = x\n",
		"bad line":    "[Interface]\nnonsense\n",
	} {
		if _, err := ParseConfig(strings.NewReader(in)); err == nil {
			t.Errorf("%s: expected error", name)
		}
	}
}
