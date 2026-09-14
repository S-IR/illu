package pe


PeLoadError :: enum {
	None,
	MMapFailed,
	ProtDomainFailed,
	ExecutionFailed,
}
run :: proc(image: ^Image) -> PeLoadError {

}
