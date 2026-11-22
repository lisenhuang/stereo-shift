package main

// #include <stdint.h>
// #include <stdlib.h>
import "C"
import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
)

type session struct {
	cancel context.CancelFunc
	mu     sync.Mutex
	state  string
}

var sessions sync.Map
var sequence atomic.Uint64

//export SSQuickTunnelStart
func SSQuickTunnelStart(port C.uint16_t, secret *C.char) C.uint64_t {
	key := C.GoString(secret)
	id := sequence.Add(1)
	ctx, cancel := context.WithCancel(context.Background())
	s := &session{cancel: cancel}
	sessions.Store(id, s)
	go func() {
		defer cancel()
		err := serve(ctx, int(port), key, func(link string) {
			s.mu.Lock()
			defer s.mu.Unlock()
			if ctx.Err() == nil && s.state == "" {
				s.state = link
			}
		})
		s.mu.Lock()
		switch {
		case errors.Is(err, errProvision):
			s.state = "provision"
		case errors.Is(err, errEdge):
			s.state = "edge"
		case errors.Is(err, errPublicDNS):
			s.state = "dns"
		default:
			s.state = "disconnected"
		}
		s.mu.Unlock()
	}()
	return C.uint64_t(id)
}

//export SSQuickTunnelStatus
func SSQuickTunnelStatus(id C.uint64_t) *C.char {
	value, ok := sessions.Load(uint64(id))
	if !ok {
		return C.CString("unavailable")
	}
	s := value.(*session)
	s.mu.Lock()
	defer s.mu.Unlock()
	return C.CString(s.state)
}

//export SSQuickTunnelStop
func SSQuickTunnelStop(id C.uint64_t) {
	if value, ok := sessions.LoadAndDelete(uint64(id)); ok {
		value.(*session).cancel()
	}
}
func main() {}
