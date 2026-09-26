package spikefixture

import (
	"bytes"
	"context"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func CheckFullDuplex(t *testing.T) {
	target, e := net.Listen("tcp4", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	defer target.Close()
	// An embedded proxy command is opaque data; the decoy must never be dialed.
	decoy, e := net.Listen("tcp4", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	defer decoy.Close()
	payload := append([]byte("CONNECT "+decoy.Addr().String()+" HTTP/1.1\r\n\r\n"), bytes.Repeat([]byte("opaque-ciphertext-canary\x00\xff"), 12000)...)
	decoyDone := make(chan error, 1)
	go func() {
		decoy.(*net.TCPListener).SetDeadline(time.Now().Add(3 * time.Second))
		c, e := decoy.Accept()
		if c != nil {
			c.Close()
		}
		decoyDone <- e
	}()
	serverDone := make(chan error, 1)
	go func() {
		c, e := target.Accept()
		if e != nil {
			serverDone <- e
			return
		}
		defer c.Close()
		c.SetDeadline(time.Now().Add(20 * time.Second))
		got, e := io.ReadAll(c)
		if e == nil && !bytes.Equal(got, payload) {
			e = io.ErrUnexpectedEOF
		}
		if e == nil {
			_, e = c.Write(payload)
		}
		serverDone <- e
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	Serve(t, ctx, target.Addr().String(), func(int) {}, func(port int) {
		c, e := net.Dial("tcp4", net.JoinHostPort("127.0.0.1", fmtPort(port)))
		if e != nil {
			t.Error(e)
			return
		}
		defer c.Close()
		c.SetDeadline(time.Now().Add(20 * time.Second))
		if _, e = c.Write(payload); e != nil {
			t.Error(e)
			return
		}
		if e = c.(*net.TCPConn).CloseWrite(); e != nil {
			t.Error(e)
			return
		}
		got, e := io.ReadAll(c)
		if e != nil {
			t.Error(e)
		}
		if !bytes.Equal(got, payload) {
			t.Errorf("half-close response length: got %d want %d", len(got), len(payload))
		}
	})
	if e = <-serverDone; e != nil {
		t.Error(e)
	}
	decoy.Close()
	if e := <-decoyDone; e == nil {
		t.Error("bridge dialed payload-selected destination")
	}
}
func CheckCancellation(t *testing.T) {
	url := Control(t, true)
	dir := filepath.Join(t.TempDir(), "login")
	os.Mkdir(dir, 0700)
	n, e := NewNode(dir, url)
	if e != nil {
		t.Fatal(e)
	}
	defer n.Close()
	done := make(chan error, 1)
	go func() { done <- n.Up(10000) }()
	// Status is in-memory; synthetic authorization URL is never printed.
	var status string
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		status, _ = n.Status()
		if strings.Contains(status, "/auth/") {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if !strings.Contains(status, "/auth/") {
		t.Errorf("synthetic AuthURL not observed")
	}
	start := time.Now()
	n.Cancel()
	select {
	case e := <-done:
		if e == nil {
			t.Error("blocked login unexpectedly succeeded")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("cancel failed to join login")
	}
	if time.Since(start) > 2*time.Second {
		t.Error("login exceeded cancellation bound")
	}
}
func CheckLogSuppression(t *testing.T) {
	var capture bytes.Buffer
	old := log.Writer()
	log.SetOutput(&capture)
	defer log.SetOutput(old)
	CheckCancellation(t)
	if strings.Contains(capture.String(), "/auth/") {
		t.Fatal("authorization URL entered local log")
	}
}

func CheckBlockedDial(t *testing.T) {
	_, phone := Nodes(t)
	done := make(chan error, 1)
	start := time.Now()
	go func() {
		c, e := phone.Dial("100.64.0.254:49443", 10000)
		if c != nil {
			c.Close()
		}
		done <- e
	}()
	time.Sleep(100 * time.Millisecond)
	phone.Cancel()
	select {
	case e := <-done:
		if e == nil {
			t.Fatal("unreachable destination dial succeeded")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("blocked dial did not terminate")
	}
	if time.Since(start) > 3*time.Second {
		t.Fatal("dial cancellation bound exceeded")
	}
}
func CheckActiveCleanup(t *testing.T) {
	target, e := net.Listen("tcp4", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	defer target.Close()
	done := make(chan struct{})
	go func() {
		defer close(done)
		c, e := target.Accept()
		if e == nil {
			defer c.Close()
			c.SetDeadline(time.Now().Add(3 * time.Second))
			var request [6]byte
			if _, e = io.ReadFull(c, request[:]); e != nil || string(request[:]) != "opaque" {
				t.Errorf("active cleanup positive premise: %q: %v", request, e)
				return
			}
			if n, e := c.Write([]byte("ok")); e != nil || n != 2 {
				t.Errorf("active cleanup acknowledgement: %d bytes: %v", n, e)
				return
			}
			io.Copy(io.Discard, c)
		}
	}()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	Serve(t, ctx, target.Addr().String(), func(int) {}, func(port int) {
		c, e := net.Dial("tcp4", net.JoinHostPort("127.0.0.1", fmtPort(port)))
		if e != nil {
			t.Error(e)
			return
		}
		defer c.Close()
		c.SetDeadline(time.Now().Add(5 * time.Second))
		if n, e := c.Write([]byte("opaque")); e != nil || n != 6 {
			t.Errorf("active cleanup request: %d bytes: %v", n, e)
			return
		}
		var reply [2]byte
		if _, e = io.ReadFull(c, reply[:]); e != nil || string(reply[:]) != "ok" {
			t.Errorf("active cleanup healthy round trip: %q: %v", reply, e)
			return
		}
		cancel()
		c.SetReadDeadline(time.Now().Add(2 * time.Second))
		var b [1]byte
		_, e = c.Read(b[:])
		if ne, ok := e.(net.Error); ok && ne.Timeout() {
			t.Error("active descriptor stayed open after cancel")
		}
	})
	target.Close()
	<-done
}

// A rejected native TLS exchange can leave a half-closed stream while its
// peer drains an alert. It must not block another client from reaching TLS.
func CheckStalledThenEcho(t *testing.T) {
	target, e := net.Listen("tcp4", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	defer target.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	firstArrived := make(chan struct{})
	serverDone := make(chan error, 1)
	go func() {
		first, e := target.Accept()
		if e != nil {
			serverDone <- e
			return
		}
		defer first.Close()
		close(firstArrived)
		target.(*net.TCPListener).SetDeadline(time.Now().Add(5 * time.Second))
		next, e := target.Accept()
		if e != nil {
			serverDone <- e
			return
		}
		defer next.Close()
		next.SetDeadline(time.Now().Add(3 * time.Second))
		var b [4]byte
		_, e = io.ReadFull(next, b[:])
		if e == nil {
			_, e = next.Write(b[:])
		}
		serverDone <- e
		<-ctx.Done()
	}()
	Serve(t, ctx, target.Addr().String(), func(int) {}, func(port int) {
		addr := net.JoinHostPort("127.0.0.1", fmtPort(port))
		first, e := net.DialTimeout("tcp4", addr, time.Second)
		if e != nil {
			t.Error(e)
			return
		}
		defer first.Close()
		first.(*net.TCPConn).CloseWrite()
		select {
		case <-firstArrived:
		case <-time.After(3 * time.Second):
			t.Error("first connection never reached target")
			return
		}
		next, e := net.DialTimeout("tcp4", addr, time.Second)
		if e != nil {
			t.Error(e)
			return
		}
		defer next.Close()
		next.SetDeadline(time.Now().Add(2 * time.Second))
		if _, e = next.Write([]byte("echo")); e != nil {
			t.Error(e)
			return
		}
		var got [4]byte
		if _, e = io.ReadFull(next, got[:]); e != nil {
			t.Errorf("stalled prior connection blocked next roundtrip: %v", e)
			return
		}
		if string(got[:]) != "echo" {
			t.Error("echo mismatch")
		}
	})
	cancel()
	if e := <-serverDone; e != nil {
		t.Error(e)
	}
}

// Reuse descriptor numbers aggressively on one pair of nodes, alternating
// abrupt client abandonment and complete half-close request/response sessions.
func CheckRepeatedConnections(t *testing.T) {
	const attempts = 24
	target, e := net.Listen("tcp4", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	defer target.Close()
	target.(*net.TCPListener).SetDeadline(time.Now().Add(30 * time.Second))
	serverDone := make(chan error, 1)
	go func() {
		for i := 0; i < attempts; i++ {
			c, e := target.Accept()
			if e != nil {
				serverDone <- e
				return
			}
			c.SetDeadline(time.Now().Add(3 * time.Second))
			b, e := io.ReadAll(c)
			if e == nil {
				_, e = c.Write(b)
			}
			c.Close()
			if e != nil && i%3 != 0 {
				serverDone <- e
				return
			}
		}
		serverDone <- nil
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	Serve(t, ctx, target.Addr().String(), func(int) {}, func(port int) {
		for i := 0; i < attempts; i++ {
			c, e := net.DialTimeout("tcp4", net.JoinHostPort("127.0.0.1", fmtPort(port)), time.Second)
			if e != nil {
				t.Error(e)
				return
			}
			c.SetDeadline(time.Now().Add(3 * time.Second))
			payload := bytes.Repeat([]byte{byte(i)}, 8192)
			if _, e = c.Write(payload); e != nil {
				c.Close()
				t.Error(e)
				return
			}
			if i%3 == 0 {
				c.Close()
				continue
			}
			c.(*net.TCPConn).CloseWrite()
			got, e := io.ReadAll(c)
			c.Close()
			if e != nil || !bytes.Equal(got, payload) {
				t.Errorf("connection %d: got %d bytes, want %d: %v", i, len(got), len(payload), e)
				return
			}
		}
	})
	target.Close()
	if e := <-serverDone; e != nil {
		t.Error(e)
	}
}
