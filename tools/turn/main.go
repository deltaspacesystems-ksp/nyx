// Nyx TURN relay. Voice and screen share are peer-to-peer WebRTC (already end-to-end encrypted
// with DTLS-SRTP); this relay only forwards those encrypted packets when two peers cannot reach
// each other directly. It authenticates with the same time-limited credentials the Nyx server
// hands out (coturn "REST API" scheme), so it needs the same shared secret.
package main

import (
	"flag"
	"log"
	"net"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/pion/logging"
	"github.com/pion/turn/v4"
)

func main() {
	port := flag.Int("port", 3478, "UDP+TCP listen port")
	host := flag.String("public-host", "", "DNS name (or IP) clients use to reach this relay, e.g. turn.deltatechksp.eu")
	secret := flag.String("secret", os.Getenv("NYX_TURN_SECRET"), "shared secret (same as Rtc:TurnSecret in the Nyx server); or set NYX_TURN_SECRET")
	minPort := flag.Int("min-port", 49160, "first UDP port used for relayed media")
	maxPort := flag.Int("max-port", 49200, "last UDP port used for relayed media")
	maxPerUser := flag.Int("max-per-user", 4, "concurrent relay allocations one account may hold")
	maxPerIP := flag.Int("max-per-ip", 8, "concurrent relay allocations one client address may hold")
	flag.Parse()

	if *host == "" || *secret == "" {
		log.Fatal("usage: nyx-turn -public-host turn.example.com -secret <secret> [-port 3478] [-min-port N -max-port M]")
	}

	relayIP := resolve(*host)
	log.Printf("public address %s -> %s, control port %d, relay ports %d-%d", *host, relayIP, *port, *minPort, *maxPort)

	addr := ":" + strconv.Itoa(*port)
	udp, err := net.ListenPacket("udp4", addr)
	if err != nil {
		log.Fatalf("udp listen: %v", err)
	}
	tcp, err := net.Listen("tcp4", addr)
	if err != nil {
		log.Fatalf("tcp listen: %v", err)
	}

	gen := func() turn.RelayAddressGenerator {
		return &turn.RelayAddressGeneratorPortRange{
			RelayAddress: relayIP,
			Address:      "0.0.0.0",
			MinPort:      uint16(*minPort),
			MaxPort:      uint16(*maxPort),
		}
	}

	quota := newQuota(*maxPerUser, *maxPerIP)
	lf := logging.NewDefaultLoggerFactory()
	srv, err := turn.NewServer(turn.ServerConfig{
		Realm:         "nyx",
		LoggerFactory: lf,
		AuthHandler:   turn.LongTermTURNRESTAuthHandler(*secret, lf.NewLogger("auth")),
		QuotaHandler:  quota.allow,
		EventHandler: turn.EventHandler{
			OnAllocationCreated: quota.created,
			OnAllocationDeleted: quota.deleted,
		},
		PacketConnConfigs: []turn.PacketConnConfig{
			{PacketConn: udp, RelayAddressGenerator: gen(), PermissionHandler: publicPeersOnly},
		},
		ListenerConfigs: []turn.ListenerConfig{
			{Listener: tcp, RelayAddressGenerator: gen(), PermissionHandler: publicPeersOnly},
		},
	})
	if err != nil {
		log.Fatalf("start: %v", err)
	}

	log.Print("Nyx TURN relay running")
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	<-sig
	_ = srv.Close()
}

// The relay must not become a way into the server's own network: only public addresses may be
// relayed to. (Peers on the same LAN as the server talk directly and never need a relay.)
func publicPeersOnly(_ net.Addr, peer net.IP) bool {
	return !(peer.IsPrivate() || peer.IsLoopback() || peer.IsLinkLocalUnicast() ||
		peer.IsLinkLocalMulticast() || peer.IsMulticast() || peer.IsUnspecified())
}

// The DNS record may not resolve yet right after boot or before it has been created, so keep trying.
func resolve(host string) net.IP {
	if ip := net.ParseIP(host); ip != nil {
		return ip
	}
	for {
		ips, err := net.LookupIP(host)
		if err == nil {
			for _, ip := range ips {
				if v4 := ip.To4(); v4 != nil {
					return v4
				}
			}
		}
		log.Printf("cannot resolve %s yet (%v), retrying in 15s", host, err)
		time.Sleep(15 * time.Second)
	}
}

// quota stops one leaked or misbehaving account from turning the relay into a free proxy for lots of
// simultaneous sessions: a few concurrent allocations per account and per client address is plenty
// for a call between friends.
type quota struct {
	mu             sync.Mutex
	maxUser, maxIP int
	byUser, byIP   map[string]int
}

func newQuota(maxUser, maxIP int) *quota {
	return &quota{maxUser: maxUser, maxIP: maxIP, byUser: map[string]int{}, byIP: map[string]int{}}
}

// Usernames look like "<expiry>:<account id>"; the expiry changes, the account id does not.
func account(username string) string {
	if i := strings.IndexByte(username, ':'); i >= 0 {
		return username[i+1:]
	}
	return username
}

func host(a net.Addr) string {
	h, _, err := net.SplitHostPort(a.String())
	if err != nil {
		return a.String()
	}
	return h
}

func (q *quota) allow(username, _ string, src net.Addr) bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	ok := q.byUser[account(username)] < q.maxUser && q.byIP[host(src)] < q.maxIP
	if !ok {
		log.Printf("quota reached for %s from %s", account(username), host(src))
	}
	return ok
}

func (q *quota) created(src, _ net.Addr, _, username, _ string, _ net.Addr, _ int) {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.byUser[account(username)]++
	q.byIP[host(src)]++
}

func (q *quota) deleted(src, _ net.Addr, _, username, _ string) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.byUser[account(username)]--; q.byUser[account(username)] <= 0 {
		delete(q.byUser, account(username))
	}
	if q.byIP[host(src)]--; q.byIP[host(src)] <= 0 {
		delete(q.byIP, host(src))
	}
}
