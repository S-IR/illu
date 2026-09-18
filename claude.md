this is an exokernel that is meant to run as fast as possible, run windows apps natively (literally copy and paste the executables and their files in). it is a libos design where we put as much stuff in userland libraries that each "process" runs.
kernel gives the tool blocks to manage memory between programs (sharing , multiplexing etc.) any other abstractions are built ontop on memory and permissions to it
single address space as default. speecial programs can access and do logical addresses.
every program / lib is code. position independent, dumb. no distinction between static and dynamic libraries. . executables are just libraries that you specify an enter fn.
DO NOT WRITE ANY CODE IN ANY FILES YOURSELF. PRINT HERE IN THIS CHAT STEP BY STEP CHANGES OF THE CODEBASE + CODE
