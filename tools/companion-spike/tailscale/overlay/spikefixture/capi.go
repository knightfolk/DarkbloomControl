// TEST ONLY: C API descriptor ownership is transferred once into net.FileConn.
package spikefixture

/*
#include <stdlib.h>
#include "../tailscale.h"
extern int SpikeUpBounded(int,int);
extern int SpikeDialBounded(int,char*,char*,int,int*);
extern void SpikeCancelPending(int);
*/
import "C"
import (
	"fmt"
	"golang.org/x/sys/unix"
	"net"
	"os"
	"strconv"
	"strings"
	"unsafe"
)

type Node int

func NewNode(dir, url string) (Node, error) {
	n := C.tailscale_new()
	d, u := C.CString(dir), C.CString(url)
	defer C.free(unsafe.Pointer(d))
	defer C.free(unsafe.Pointer(u))
	// Do not start at all if any configuration setter fails: falling through
	// could otherwise use the default external coordination service.
	steps := []func() C.int{
		func() C.int { return C.tailscale_set_dir(n, d) },
		func() C.int { return C.tailscale_set_control_url(n, u) },
		func() C.int { return C.tailscale_set_logfd(n, -1) },
		func() C.int { return C.tailscale_start(n) },
	}
	for _, step := range steps {
		if r := step(); r != 0 {
			C.tailscale_close(n)
			return 0, fmt.Errorf("node configuration/start failed: %d", r)
		}
	}
	return Node(n), nil
}
func (n Node) Up(ms int) error {
	if r := C.SpikeUpBounded(C.int(n), C.int(ms)); r != 0 {
		return fmt.Errorf("bounded up failed: %d", r)
	}
	return nil
}
func (n Node) Cancel() { C.SpikeCancelPending(C.int(n)) }
func (n Node) Close() error {
	if r := C.tailscale_close(C.int(n)); r != 0 {
		return fmt.Errorf("close: %d", r)
	}
	return nil
}
func (n Node) IP() (string, error) {
	var b [128]C.char
	if C.tailscale_getips(C.int(n), &b[0], 128) != 0 {
		return "", fmt.Errorf("getips failed")
	}
	return strings.Split(C.GoString(&b[0]), ",")[0], nil
}
func (n Node) Status() (string, error) {
	var p *C.char
	if C.tailscale_status_json(C.int(n), &p) != 0 {
		return "", fmt.Errorf("status failed")
	}
	defer C.free(unsafe.Pointer(p))
	return C.GoString(p), nil
}
func (n Node) Listen() (int, error) {
	network, addr := C.CString("tcp"), C.CString(":49443")
	defer C.free(unsafe.Pointer(network))
	defer C.free(unsafe.Pointer(addr))
	var fd C.int
	if C.tailscale_listen(C.int(n), network, addr, &fd) != 0 {
		return -1, fmt.Errorf("listen failed")
	}
	return int(fd), nil
}
func (n Node) Dial(addr string, ms int) (net.Conn, error) {
	network, target := C.CString("tcp"), C.CString(addr)
	defer C.free(unsafe.Pointer(network))
	defer C.free(unsafe.Pointer(target))
	var fd C.int
	if C.SpikeDialBounded(C.int(n), network, target, C.int(ms), &fd) != 0 {
		return nil, fmt.Errorf("bounded dial failed")
	}
	return ownFD(int(fd))
}
func Accept(fd int) (net.Conn, error) {
	poll := []unix.PollFd{{Fd: int32(fd), Events: unix.POLLIN}}
	n, e := unix.Poll(poll, operationMillis)
	if e != nil || n != 1 || poll[0].Revents&unix.POLLIN == 0 {
		return nil, fmt.Errorf("bounded accept readiness failed")
	}
	var conn C.int
	if C.tailscale_accept(C.int(fd), &conn) != 0 {
		return nil, fmt.Errorf("accept failed")
	}
	return ownFD(int(conn))
}
func ownFD(fd int) (net.Conn, error) {
	f := os.NewFile(uintptr(fd), "spike-owned-fd")
	defer f.Close()
	return net.FileConn(f)
}
func Target(port string) (string, error) {
	p, e := strconv.Atoi(port)
	if e != nil || p < 1 || p > 65535 {
		return "", fmt.Errorf("SPIKE_TARGET_PORT must be a numeric port")
	}
	return net.JoinHostPort("127.0.0.1", strconv.Itoa(p)), nil
}
func fmtPort(p int) string { return strconv.Itoa(p) }
