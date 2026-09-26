// Checks that a running nyx-turn accepts credentials made the way the Nyx server makes them
// (username "<expiry>:<user>", password base64(HMAC-SHA1(secret, username))) and rejects others.
package main

import (
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"flag"
	"fmt"
	"net"
	"os"
	"strconv"
	"time"

	"github.com/pion/logging"
	"github.com/pion/turn/v4"
)

func creds(secret string) (string, string) {
	user := strconv.FormatInt(time.Now().Add(time.Hour).Unix(), 10) + ":verify"
	mac := hmac.New(sha1.New, []byte(secret))
	mac.Write([]byte(user))
	return user, base64.StdEncoding.EncodeToString(mac.Sum(nil))
}

func try(server, secret string) error {
	conn, err := net.ListenPacket("udp4", "0.0.0.0:0")
	if err != nil {
		return err
	}
	defer conn.Close()
	user, pass := creds(secret)
	c, err := turn.NewClient(&turn.ClientConfig{
		STUNServerAddr: server, TURNServerAddr: server, Conn: conn,
		Username: user, Password: pass, Realm: "nyx",
		LoggerFactory: logging.NewDefaultLoggerFactory(),
	})
	if err != nil {
		return err
	}
	defer c.Close()
	if err := c.Listen(); err != nil {
		return err
	}
	relay, err := c.Allocate()
	if err != nil {
		return err
	}
	defer relay.Close()
	fmt.Println("  relay allocated at", relay.LocalAddr())
	return nil
}

// holdMany opens n allocations for one account at the same time; a quota must stop some of them.
func holdMany(server, secret string, n int) (ok int) {
	var closers []func()
	defer func() {
		for _, c := range closers {
			c()
		}
	}()
	user, pass := creds(secret)
	for i := 0; i < n; i++ {
		conn, err := net.ListenPacket("udp4", "0.0.0.0:0")
		if err != nil {
			continue
		}
		c, err := turn.NewClient(&turn.ClientConfig{
			STUNServerAddr: server, TURNServerAddr: server, Conn: conn,
			Username: user, Password: pass, Realm: "nyx",
			LoggerFactory: logging.NewDefaultLoggerFactory(),
		})
		if err != nil {
			conn.Close()
			continue
		}
		closers = append(closers, func() { c.Close(); conn.Close() })
		if err := c.Listen(); err != nil {
			continue
		}
		relay, err := c.Allocate()
		if err != nil {
			continue
		}
		closers = append(closers, func() { relay.Close() })
		ok++
	}
	return ok
}

func main() {
	server := flag.String("server", "127.0.0.1:3478", "host:port of nyx-turn")
	secret := flag.String("secret", "", "shared secret")
	hold := flag.Int("hold", 0, "if > 0: open this many allocations for one account and report how many the quota allowed")
	flag.Parse()
	if *hold > 0 {
		n := holdMany(*server, *secret, *hold)
		fmt.Printf("allocations granted: %d of %d\n", n, *hold)
		return
	}
	fmt.Println("correct secret:")
	if err := try(*server, *secret); err != nil {
		fmt.Println("  FAILED:", err)
		os.Exit(1)
	}
	fmt.Println("wrong secret (must be rejected):")
	if err := try(*server, *secret+"x"); err == nil {
		fmt.Println("  FAILED: accepted a wrong secret")
		os.Exit(1)
	} else {
		fmt.Println("  rejected:", err)
	}
}
