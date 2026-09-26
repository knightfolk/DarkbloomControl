// TEST-ONLY extension. Call Start before bounded Up; cancel and join operations
// before Close. At most one operation per node. This is not a promoted ABI.
package main

/*
#include <errno.h>
*/
import "C"
import (
	"context"
	"sync"
	"time"
)

var spikeOps = struct {
	sync.Mutex
	m map[C.int]context.CancelFunc
}{m: make(map[C.int]context.CancelFunc)}

func spikeBegin(sd C.int, ms C.int) (context.Context, func(), bool) {
	if ms < 1 || ms > 10000 {
		return nil, nil, false
	}
	spikeOps.Lock()
	defer spikeOps.Unlock()
	if spikeOps.m[sd] != nil {
		return nil, nil, false
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(ms)*time.Millisecond)
	spikeOps.m[sd] = cancel
	return ctx, func() { cancel(); spikeOps.Lock(); delete(spikeOps.m, sd); spikeOps.Unlock() }, true
}

//export SpikeCancelPending
func SpikeCancelPending(sd C.int) {
	spikeOps.Lock()
	defer spikeOps.Unlock()
	if cancel := spikeOps.m[sd]; cancel != nil {
		cancel()
	}
}

//export SpikeUpBounded
func SpikeUpBounded(sd, ms C.int) C.int {
	s := getServer(sd)
	if s == nil {
		return C.EBADF
	}
	ctx, done, ok := spikeBegin(sd, ms)
	if !ok {
		return C.EBUSY
	}
	defer done()
	_, err := s.s.Up(ctx)
	return s.recErr(err)
}

//export SpikeDialBounded
func SpikeDialBounded(sd C.int, network, addr *C.char, ms C.int, out *C.int) C.int {
	s := getServer(sd)
	if s == nil {
		return C.EBADF
	}
	ctx, done, ok := spikeBegin(sd, ms)
	if !ok {
		return C.EBUSY
	}
	defer done()
	c, err := s.s.Dial(ctx, C.GoString(network), C.GoString(addr))
	if err != nil {
		return s.recErr(err)
	}
	if err = newConn(s, c, out); err != nil {
		c.Close()
		return s.recErr(err)
	}
	return 0
}
