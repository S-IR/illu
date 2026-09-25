this is an exokernel that is meant to be as simple as possible, run as fast as possible, run windows apps natively (literally copy and paste the executables and their files in). it is a libos design where we put as much stuff in userland libraries that each "process" runs.
this is single address space operating system
kernel gives the tool blocks to manage memory between programs (sharing , multiplexing etc.) any other abstractions are built ontop on memory and permissions to it
single address space as default. speecial programs can access and do logical addresses.
every program / lib is code. position independent, dumb. no distinction between static and dynamic libraries. . executables are just libraries that you specify an enter fn.
authority and security are boiled down to memory permissions. any higher level security concept like file writes, process permissions etc. boils down to "do you have read or write permissions on some memory range"
we avoid daemons and we instead go for many decentralized apps that do not trust each other having memory contracts around devices ("we share this block of memory, i can lock this memory for x ms to do my business then i let you" bla bla). each program loads a userlib to work with the hardware as close as possible while respecting the contract.
DO NOT WRITE ANY CODE IN ANY FILES YOURSELF UNLESS I LITERALLY ASK YOU TO MODIFY FILES. PRINT HERE IN THIS CHAT STEP BY STEP CHANGES OF THE CODEBASE + CODE
BE WAY WAY WAY LESS VERBOSE

# CODE STANDARDS

- simple code
- remove dead code
- always write code while thinking "what could go wrong?". what values can the states be. what assumptions do I have that are not explicit?
- assert and ensure any invalid program state that's not an error to be returned. as many asserts as you can
- use odin lang's syntax features. use odin lang's core packages
- no comments unless it is a must, even in asserts. code should read like comments. it should be abvious what you do based on the code
- be very careful with assembly. write #assert where you are assuming an odin lang struct layout. when having kernel issues first check the alignment problems then the argument order passings
