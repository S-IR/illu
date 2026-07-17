package kernel
import ah "../asm_helpers"
import "base:intrinsics"
import "base:runtime"
import "print"

when !ODIN_TEST {
	@(default_calling_convention = "c")
	foreign _ {
		gs_read_cpustate :: proc() -> ^CpuState ---
		thread_save_and_switch_to :: proc(old, new: ^Thread) ---
		thread_load_and_switch_to :: proc(new: ^Thread) ---
		thread_start_idle_loop :: proc() ---

	}
}


runq_enqueue :: proc(q: ^RunQueue, t: ^Thread) {
	t.next = nil
	if q.tail != nil {
		q.tail.next = t
	} else {
		q.head = t
	}
	q.tail = t

}
runq_dequeue :: proc(q: ^RunQueue) -> (t: ^Thread) {
	t = q.head
	if t == nil do return nil
	q.head = t.next
	if q.head == nil do q.tail = nil
	t.next = nil
	return t

}
thread_switch_away :: proc() {
	cpu := gs_read_cpustate()
	oldThread := cpu.current

	if oldThread != nil && oldThread.state == .Running {
		oldThread.state = .Ready
		runq_enqueue(&cpu.runQueue, oldThread)
	}

	newThread := runq_dequeue(&cpu.runQueue)

	if newThread == nil {
		cpu.current = nil
		cpu.idleHint = DEFAULT_IDLE_HINT
		thread_start_idle_loop()
		return
	}

	// CR3: only switch if the address space changed
	if oldThread == nil || oldThread.process != newThread.process {
		ah.write_cr3(newThread.process.activePml4)
	}

	// Update TSS RSP0 for this thread's kernel stack
	cpu.tssRSP0^ = newThread.stackTop
	newThread.state = .Running
	cpu.current = newThread

	if oldThread != nil {
		thread_save_and_switch_to(oldThread, newThread)
	} else {
		thread_load_and_switch_to(newThread)
	}
}
