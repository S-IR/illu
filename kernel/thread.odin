package kernel
import ah "../asm_helpers"
import "base:intrinsics"
import "base:runtime"
import "print"
IDLE_STACK_SIZE :: 4096

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
	q.buf[q.tail % RUN_QUEUE_CAP] = t
	q.tail += 1
}

runq_dequeue :: proc(q: ^RunQueue) -> (t: ^Thread) {
	if q.head == q.tail do return nil
	t = q.buf[q.head % RUN_QUEUE_CAP]
	q.head += 1
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
