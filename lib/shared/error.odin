package shared

Error :: enum u64 {
	None = 0,
	InvalidAPICall,
	OutOfMemory,
	Timeout,
	Corrupt,
	NotFound,
	//NVME
	NvmeQueueFull = 0x100,
	NvmeFailed,
	NvmeBarNotMemory,
	NvmeBarTooSmall,
	NvmeCapTimeoutZero,
	NvmePageSizeUnsupported,
	NvmeCommandSetUnsupported,
	NvmeDisableTimeout,
	NvmeEnableTimeout,
	NvmeControllerFatal,
	NvmeEntrySizeUnsupported,
	NvmeNoNamespace,
	NvmeLbaFormatInvalid,
	NvmeBlockSizeUnsupported,
	NvmeNamespaceEmpty,
	NvmeNoIoQueues,
	NvmeIoQueuesExhausted,
	//GENERAL FS
	GptNotGpt = 0x200,
	FsDiskFull = 0x300,
}
