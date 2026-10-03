package gs
import "../../lib/spinlock"
nextMadeUpAddr: struct {
	v:    u64,
	lock: spinlock.Spinlock,
} = {
	v = (1 << 52),
}
