package modelcheck

import "core:fmt"

Transition :: struct($State: typeid) {
	state: State,
	label: string,
}

Result :: struct($State: typeid) {
	ok:      bool,
	message: string,
	trace:   []string,
	visited: int,
}

run :: proc(
	inits: []$State,
	next: proc(State) -> []Transition(State),
	inv: proc(State) -> (bool, string),
	max_states := 200000,
) -> Result(State) {
	Frame :: struct {
		state: State,
		path:  []string,
	}

	visited := make(map[State]bool)
	defer delete(visited)

	queue: [dynamic]Frame
	defer {
		for f in queue do delete(f.path)
		delete(queue)
	}

	for s in inits {
		ok, msg := inv(s)
		if !ok {
			trace := make([]string, 1)
			trace[0] = "<init>"
			return Result(State){ok = false, message = msg, trace = trace}
		}
		if s in visited do continue
		visited[s] = true
		initPath := make([]string, 1)
		initPath[0] = "<init>"
		append(&queue, Frame{s, initPath})
	}

	count := 0
	head := 0
	for head < len(queue) {
		frame := queue[head]
		head += 1
		count += 1
		if count > max_states {
			return Result(State) {
				ok      = false,
				message = fmt.tprintf("exceeded %d states without terminating", max_states),
				trace   = frame.path,
				visited = count,
			}
		}

		transitions := next(frame.state)
		defer delete(transitions)
		for t in transitions {
			path := make([]string, len(frame.path) + 1)
			copy(path, frame.path)
			path[len(frame.path)] = t.label

			ok, msg := inv(t.state)
			if !ok {
				return Result(State){ok = false, message = msg, trace = path, visited = count}
			}

			if t.state in visited {
				delete(path)
				continue
			}
			visited[t.state] = true
			append(&queue, Frame{t.state, path})
		}
	}

	return Result(State){ok = true, visited = count}
}
