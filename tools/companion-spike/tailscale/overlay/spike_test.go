package main

import (
	"bytes"
	"github.com/tailscale/libtailscale/spikefixture"
	"log"
	"os"
	"testing"
	"time"
)

func TestSpikeProcess(t *testing.T) {
	if os.Getenv("SPIKE_TARGET_PORT") == "" {
		t.Skip("process fixture requires SPIKE_TARGET_PORT")
	}
	spikefixture.RunProcess(t)
}
func TestSpikeFullDuplexHalfClose(t *testing.T) {
	t.Run("run", spikefixture.CheckFullDuplex)
	assertSpikeClean(t)
}
func TestSpikeBlockedLoginActuallyTerminates(t *testing.T) {
	t.Run("run", spikefixture.CheckCancellation)
	assertSpikeClean(t)
}
func TestSpikeAuthURLNeverEntersLocalLogs(t *testing.T) {
	t.Run("run", spikefixture.CheckLogSuppression)
	assertSpikeClean(t)
}
func TestSpikeFixedDestination(t *testing.T) {
	for _, p := range []string{"evil.example:80", "127.0.0.2:80", "-1", "0", "65536", "80/path", "80\n"} {
		if _, e := spikefixture.Target(p); e == nil {
			t.Errorf("accepted %q", p)
		}
	}
	if a, e := spikefixture.Target("49443"); e != nil || a != "127.0.0.1:49443" {
		t.Fatalf("target %q %v", a, e)
	}
}
func assertSpikeClean(t *testing.T) {
	t.Helper()
	for i := 0; i < 100; i++ {
		servers.mu.Lock()
		s := len(servers.m)
		servers.mu.Unlock()
		listeners.mu.Lock()
		l := len(listeners.m)
		listeners.mu.Unlock()
		conns.mu.Lock()
		c := len(conns.m)
		conns.mu.Unlock()
		spikeOps.Lock()
		o := len(spikeOps.m)
		spikeOps.Unlock()
		if s+l+c+o == 0 {
			return
		}
		if i == 99 {
			t.Fatalf("owned objects remain: servers=%d listeners=%d conns=%d ops=%d", s, l, c, o)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestSpikeBlockedDialActuallyTerminates(t *testing.T) {
	t.Run("run", spikefixture.CheckBlockedDial)
	assertSpikeClean(t)
}
func TestSpikeStopClosesOwnedDescriptorsAndNode(t *testing.T) {
	t.Run("run", spikefixture.CheckActiveCleanup)
	assertSpikeClean(t)
}
func TestSpikeLogfdSuppressesBothPaths(t *testing.T) {
	var capture bytes.Buffer
	old := log.Writer()
	log.SetOutput(&capture)
	defer log.SetOutput(old)
	sd := TsnetNewServer()
	defer TsnetClose(sd)
	if TsnetSetLogFD(sd, -1) != 0 {
		t.Fatal("logfd failed")
	}
	s := getServer(sd)
	if s.s.Logf == nil || s.s.UserLogf == nil {
		t.Fatal("both log paths must be explicitly set")
	}
	s.s.Logf("https://synthetic.invalid/auth/AUTH_URL_CANARY")
	s.s.UserLogf("https://synthetic.invalid/auth/AUTH_URL_CANARY")
	if capture.Len() != 0 {
		t.Fatal("synthetic auth canary leaked")
	}
}

// Keep the process protocol stdout to exactly one readiness JSON line.
func TestMain(m *testing.M) {
	if os.Getenv("SPIKE_TARGET_PORT") != "" {
		spikefixture.ReadyOutput = os.Stdout
		os.Stdout = os.Stderr
	}
	os.Exit(m.Run())
}
func TestSpikeStalledHandshakeDoesNotBlockNextConnection(t *testing.T) {
	t.Run("run", spikefixture.CheckStalledThenEcho)
	assertSpikeClean(t)
}
func TestSpikeRepeatedConnectionsPreserveDescriptorOwnership(t *testing.T) {
	t.Run("run", spikefixture.CheckRepeatedConnections)
	assertSpikeClean(t)
}
