this is an exokernel that is meant to be as simple as possible, run as fast as possible, run windows apps natively (literally copy and paste the executables and their files in). it is a libos design where we put as much stuff in userland libraries that each "process" runs.
kernel gives the tool blocks to manage memory between programs (sharing , multiplexing etc.) any other abstractions are built ontop on memory and permissions to it
single address space as default. speecial programs can access and do logical addresses.
every program / lib is code. position independent, dumb. no distinction between static and dynamic libraries. . executables are just libraries that you specify an enter fn.
we avoid daemons and we instead go for many decentralized apps that do not trust each other having memory contracts around devices ("we share this block of memory, i can lock this memory for x ms to do my business then i let you" bla bla). each program loads a userlib to work with the hardware as close as possible while respecting the contract.
DO NOT WRITE ANY CODE IN ANY FILES YOURSELF UNLESS I LITERALLY ASK YOU TO MODIFY FILES. PRINT HERE IN THIS CHAT STEP BY STEP CHANGES OF THE CODEBASE + CODE
BE WAY WAY WAY LESS VERBOSE
