package spikefixture

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http/httptest"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"tailscale.com/net/netns"
	"tailscale.com/tstest/integration"
	"tailscale.com/tstest/integration/testcontrol"
	"tailscale.com/types/logger"
	"testing"
	"time"
)

var ReadyOutput io.Writer = os.Stdout

const operationMillis = 10000

func Control(t *testing.T, auth bool) string {
	t.Helper()
	netns.SetEnabled(false)
	t.Cleanup(func() { netns.SetEnabled(true) })
	control := &testcontrol.Server{DERPMap: integration.RunDERPAndSTUN(t, logger.Discard, "127.0.0.1"), RequireAuth: auth}
	control.HTTPTestServer = httptest.NewServer(control)
	t.Cleanup(control.HTTPTestServer.Close)
	return control.HTTPTestServer.URL
}
func Nodes(t *testing.T) (Node, Node) {
	t.Helper()
	url := Control(t, false)
	tmp := t.TempDir()
	makeNode := func(name string) Node {
		dir := filepath.Join(tmp, name)
		if e := os.Mkdir(dir, 0700); e != nil {
			t.Fatal(e)
		}
		n, e := NewNode(dir, url)
		if e != nil {
			t.Fatal(e)
		}
		t.Cleanup(func() {
			if e := n.Close(); e != nil {
				t.Error(e)
			}
		})
		if e = n.Up(operationMillis); e != nil {
			t.Fatal(e)
		}
		return n
	}
	return makeNode("host"), makeNode("phone")
}

// relay has two 32 KiB application buffers; deadline bounds stalled peers.
// EOF is a half-close. Cancellation closes both descriptors and joins both copies.
func relay(ctx context.Context, a, b net.Conn, tag string) {
	defer a.Close()
	defer b.Close()
	deadline := time.Now().Add(30 * time.Second)
	a.SetDeadline(deadline)
	b.SetDeadline(deadline)
	done := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			a.Close()
			b.Close()
		case <-done:
		}
	}()
	defer close(done)
	var wg sync.WaitGroup
	wg.Add(2)
	copyOne := func(dst, src net.Conn, direction string) {
		defer wg.Done()
		n, e := io.CopyBuffer(struct{ io.Writer }{dst}, struct{ io.Reader }{src}, make([]byte, 32<<10))
		if os.Getenv("SPIKE_TRACE") == "1" {
			result := "eof"
			if e != nil {
				result = "io-error"
			}
			fmt.Fprintf(os.Stderr, "spike relay=%s direction=%s bytes=%d result=%s\n", tag, direction, n, result)
		}
		if e != nil {
			a.Close()
			b.Close()
			return
		}
		if c, ok := dst.(interface{ CloseWrite() error }); ok {
			c.CloseWrite()
		}
	}
	go copyOne(a, b, "b-to-a")
	go copyOne(b, a, "a-to-b")
	wg.Wait()
}

// Serve admits at most eight active sessions. C dial/accept setup remains
// serialized; relay legs are independent so a half-closed prior TLS rejection
// cannot starve the next attempt. Client bytes never choose a destination.
func Serve(t *testing.T, ctx context.Context, target string, ready func(int), exercise func(int)) {
	t.Helper()
	host, phone := Nodes(t)
	ip, e := host.IP()
	if e != nil {
		t.Fatal(e)
	}
	fd, e := host.Listen()
	if e != nil {
		t.Fatal(e)
	}
	defer syscall.Close(fd)
	ln, e := net.Listen("tcp4", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	defer ln.Close()
	port := ln.Addr().(*net.TCPAddr).Port
	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	done := make(chan struct{})
	go func() {
		select {
		case <-runCtx.Done():
			ln.Close()
		case <-done:
		}
	}()
	defer close(done)
	var exerciseDone chan struct{}
	if exercise != nil {
		exerciseDone = make(chan struct{})
		go func() { defer close(exerciseDone); exercise(port); cancel() }()
	}
	ready(port)
	slots := make(chan struct{}, 8)
	var sessions sync.WaitGroup
	sessionID := 0
	for {
		local, e := ln.Accept()
		if e != nil {
			break
		}
		select {
		case slots <- struct{}{}:
		default:
			local.Close()
			continue
		}
		sessionID++
		dial, e := phone.Dial(net.JoinHostPort(ip, "49443"), operationMillis)
		if e != nil {
			local.Close()
			<-slots
			t.Error(e)
			break
		}
		accepted, e := Accept(fd)
		if e != nil {
			local.Close()
			dial.Close()
			<-slots
			t.Error(e)
			break
		}
		dest, e := net.DialTimeout("tcp4", target, 2*time.Second)
		if e != nil {
			local.Close()
			dial.Close()
			accepted.Close()
			<-slots
			continue
		}
		sessions.Add(1)
		go func(id int, local, dial, accepted, dest net.Conn) {
			defer sessions.Done()
			defer func() { <-slots }()
			if os.Getenv("SPIKE_TRACE") == "1" {
				fmt.Fprintf(os.Stderr, "spike session=%d opened\n", id)
			}
			var wg sync.WaitGroup
			wg.Add(2)
			go func() { defer wg.Done(); relay(runCtx, local, dial, fmt.Sprintf("%d-phone", id)) }()
			go func() { defer wg.Done(); relay(runCtx, accepted, dest, fmt.Sprintf("%d-host", id)) }()
			wg.Wait()
			if os.Getenv("SPIKE_TRACE") == "1" {
				fmt.Fprintf(os.Stderr, "spike session=%d closed\n", id)
			}
		}(sessionID, local, dial, accepted, dest)
	}
	cancel()
	sessions.Wait()
	if exerciseDone != nil {
		<-exerciseDone
	}
}
func RunProcess(t *testing.T) {
	target, e := Target(os.Getenv("SPIKE_TARGET_PORT"))
	if e != nil {
		t.Fatal(e)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 180*time.Second)
	defer cancel()
	ctx, stop := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() { io.Copy(io.Discard, os.Stdin); cancel() }()
	Serve(t, ctx, target, func(port int) {
		if e := json.NewEncoder(ReadyOutput).Encode(map[string]int{"port": port}); e != nil {
			panic(fmt.Sprintf("ready: %v", e))
		}
	}, nil)
}
