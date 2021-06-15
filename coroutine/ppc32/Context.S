#define TOKEN_PASTE(x,y) x##y
#define PREFIXED_SYMBOL(prefix,name) TOKEN_PASTE(prefix,name)

.text
.align 2

.globl PREFIXED_SYMBOL(SYMBOL_PREFIX,coroutine_transfer)
.type   PREFIXED_SYMBOL(SYMBOL_PREFIX,coroutine_transfer), @function
PREFIXED_SYMBOL(SYMBOL_PREFIX,coroutine_transfer):
	# Make space on the stack for caller registers
	stwu %r1, -240(%r1)

	# Save caller registers
	stw %r14, 24(%r1)
	stw %r15, 28(%r1)
	stw %r16, 32(%r1)
	stw %r17, 36(%r1)
	stw %r18, 40(%r1)
	stw %r19, 44(%r1)
	stw %r20, 48(%r1)
	stw %r21, 52(%r1)
	stw %r22, 56(%r1)
	stw %r23, 60(%r1)
	stw %r24, 64(%r1)
	stw %r25, 68(%r1)
	stw %r26, 72(%r1)
	stw %r27, 76(%r1)
	stw %r28, 80(%r1)
	stw %r29, 84(%r1)
	stw %r30, 88(%r1)
	stw %r31, 92(%r1)

	stfd %f14, 96(%r1)
	stfd %f15, 104(%r1)
	stfd %f16, 112(%r1)
	stfd %f17, 120(%r1)
	stfd %f18, 128(%r1)
	stfd %f19, 136(%r1)
	stfd %f20, 144(%r1)
	stfd %f21, 152(%r1)
	stfd %f22, 160(%r1)
	stfd %f23, 168(%r1)
	stfd %f24, 176(%r1)
	stfd %f25, 184(%r1)
	stfd %f26, 192(%r1)
	stfd %f27, 200(%r1)
	stfd %f28, 208(%r1)
	stfd %f29, 216(%r1)
	stfd %f30, 224(%r1)
	stfd %f31, 232(%r1)

	# Save return address
	mflr %r0
	stw %r0, 244(%r1)
	stw %r0, 16(%r1)

	# Save condition registers
	mffs %f0
	stfd %f0, 8(%r1)

	mfcr %r8
	stw %r8, 20(%r1)

	# Save registers R14 to R31.
	# Don't change R2, the thread-local storage pointer.
	# Don't change R13, the small data pointer.


	# Save registers F14 to F31 in slots with 8-byte alignment.
	# 4-byte alignment may stall the pipeline of some processors.
	# Less than 4 may cause alignment traps.


	# store RSP (pointing to context-data) in R7/R6
	# restore RSP (pointing to context-data) from R4/R3
	#ifdef __linux__
	mr   %r7, %r1
	mr   %r1, %r4
	lwz  %r3, 4(%r1)   # hidden pointer
	#else
	mr   %r6, %r1
	mr   %r1, %r3
	#endif

	lfd  %f0, 8(%r1)   # FPSCR
	lwz  %r0, 16(%r1)  # PC
	lwz  %r8, 20(%r1)  # CR

	mtfsf  0xff, %f0   # restore FPSCR
	mtctr  %r0         # load CTR with PC
	mtcr   %r8         # restore CR

	# restore R14 to R31
	lwz  %r14, 24(%r1)
	lwz  %r15, 28(%r1)
	lwz  %r16, 32(%r1)
	lwz  %r17, 36(%r1)
	lwz  %r18, 40(%r1)
	lwz  %r19, 44(%r1)
	lwz  %r20, 48(%r1)
	lwz  %r21, 52(%r1)
	lwz  %r22, 56(%r1)
	lwz  %r23, 60(%r1)
	lwz  %r24, 64(%r1)
	lwz  %r25, 68(%r1)
	lwz  %r26, 72(%r1)
	lwz  %r27, 76(%r1)
	lwz  %r28, 80(%r1)
	lwz  %r29, 84(%r1)
	lwz  %r30, 88(%r1)
	lwz  %r31, 92(%r1)

	# restore F14 to F31
	lfd  %f14, 96(%r1)
	lfd  %f15, 104(%r1)
	lfd  %f16, 112(%r1)
	lfd  %f17, 120(%r1)
	lfd  %f18, 128(%r1)
	lfd  %f19, 136(%r1)
	lfd  %f20, 144(%r1)
	lfd  %f21, 152(%r1)
	lfd  %f22, 160(%r1)
	lfd  %f23, 168(%r1)
	lfd  %f24, 176(%r1)
	lfd  %f25, 184(%r1)
	lfd  %f26, 192(%r1)
	lfd  %f27, 200(%r1)
	lfd  %f28, 208(%r1)
	lfd  %f29, 216(%r1)
	lfd  %f30, 224(%r1)
	lfd  %f31, 232(%r1)

	# restore LR from caller's frame
	lwz   %r0, 244(%r1)
	mtlr  %r0

	# adjust stack
	addi  %r1, %r1, 240

	# return transfer_t
	#ifdef __linux__
	stw  %r7, 0(%r3)
	stw  %r5, 4(%r3)
	#else
	mr   %r3, %r6
	#    %r4, %r4
	#endif

	# jump to context
	bctr

#if defined(__linux__) && defined(__ELF__)
.section .note.GNU-stack,"",%progbits
#endif
