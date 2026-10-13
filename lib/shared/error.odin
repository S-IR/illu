package shared

Error :: enum u64 {
	None                      = 0,
	InvalidAPICall,
	OutOfMemory,
	Timeout,
	Corrupt,

	NvmeQueueFull             = 0x100,
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

	GptNotGpt                 = 0x200,
}
