	.build_version macos, 15, 7, 9
	.file	1 "/opt/homebrew/Cellar/zig/0.16.0_1/lib/zig/std" "builtin.zig"
	.file	2 "/Users/bytedance/.cache/zig/b/166b679232c6aeda55a1453d1705e2c3" "builtin.zig"
	.section	__TEXT,__text,regular,pure_instructions
	.p2align	2
_tbl.useMaskSwar:
Lfunc_begin0:
	.file	3 "/Users/bytedance/r/my-scanner-oxc-neon/.exp" "tbl.zig"
	.loc	3 52 0
	.cfi_startproc
	stp	x29, x30, [sp, #-16]!
	.cfi_def_cfa_offset 16
	mov	x29, sp
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
Ltmp0:
	.loc	3 42 21 prologue_end
	mov.d	x8, v0[1]
Ltmp1:
	.loc	3 41 21
	fmov	x9, d0
Ltmp2:
	.loc	3 44 5
	and	x9, x9, #0x101010101010101
Ltmp3:
	.loc	3 0 5 is_stmt 0
	mov	x10, #16512
	movk	x10, #4128, lsl #16
	movk	x10, #1032, lsl #32
	movk	x10, #258, lsl #48
	.loc	3 44 5
	mul	x9, x9, x10
	.loc	3 44 55
	lsr	x9, x9, #56
Ltmp4:
	.loc	3 45 5 is_stmt 1
	and	x8, x8, #0x101010101010101
Ltmp5:
	mul	x8, x8, x10
Ltmp6:
	.loc	3 46 59
	lsr	x8, x8, #48
Ltmp7:
	and	w8, w8, #0xff00
	orr	w0, w8, w9
Ltmp8:
	.cfi_def_cfa wsp, 16
	.loc	3 52 37 epilogue_begin
	ldp	x29, x30, [sp], #16
	.cfi_def_cfa_offset 0
	.cfi_restore w30
	.cfi_restore w29
	ret
Ltmp9:
Lfunc_end0:
	.cfi_endproc

	.section	__TEXT,__literal16,16byte_literals
	.p2align	4, 0x0
lCPI1_0:
	.byte	1
	.byte	0
	.byte	2
	.byte	0
	.byte	4
	.byte	0
	.byte	8
	.byte	0
	.byte	1
	.byte	0
	.byte	2
	.byte	0
	.byte	4
	.byte	0
	.byte	8
	.byte	0
	.section	__TEXT,__text,regular,pure_instructions
	.p2align	2
_tbl.useMaskReduce:
Lfunc_begin1:
	.loc	3 51 0
	.cfi_startproc
	stp	x29, x30, [sp, #-16]!
	.cfi_def_cfa_offset 16
	mov	x29, sp
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
Lloh0:
	adrp	x8, lCPI1_0@PAGE
Ltmp10:
	.loc	3 30 5 prologue_end
Lloh1:
	ldr	q1, [x8, lCPI1_0@PAGEOFF]
Ltmp11:
	and.16b	v0, v0, v1
Ltmp12:
	.loc	3 32 5
	ext.16b	v1, v0, v0, #8
Ltmp13:
	.loc	3 33 5
	addv.8b	b0, v0
Ltmp14:
	fmov	w8, s0
Ltmp15:
	.loc	3 34 5
	addv.8b	b0, v1
	fmov	w9, s0
Ltmp16:
	.loc	3 35 39
	bfi	w8, w9, #8, #24
Ltmp17:
	.loc	3 51 39
	and	w0, w8, #0xffff
	.cfi_def_cfa wsp, 16
	.loc	3 51 39 epilogue_begin is_stmt 0
	ldp	x29, x30, [sp], #16
	.cfi_def_cfa_offset 0
	.cfi_restore w30
	.cfi_restore w29
	ret
Ltmp18:
	.loh AdrpLdr	Lloh0, Lloh1
Lfunc_end1:
	.cfi_endproc

	.section	__TEXT,__literal16,16byte_literals
	.p2align	4, 0x0
lCPI2_0:
	.byte	2
	.byte	3
	.byte	2
	.byte	3
	.byte	10
	.byte	11
	.byte	10
	.byte	11
	.byte	2
	.byte	3
	.byte	2
	.byte	3
	.byte	10
	.byte	11
	.byte	10
	.byte	11
lCPI2_1:
	.byte	0
	.byte	1
	.byte	0
	.byte	1
	.byte	8
	.byte	9
	.byte	8
	.byte	9
	.byte	0
	.byte	1
	.byte	0
	.byte	1
	.byte	8
	.byte	9
	.byte	8
	.byte	9
lCPI2_2:
	.byte	1
	.byte	1
	.byte	9
	.byte	9
	.byte	1
	.byte	1
	.byte	9
	.byte	9
	.byte	1
	.byte	1
	.byte	9
	.byte	9
	.byte	1
	.byte	1
	.byte	9
	.byte	9
lCPI2_3:
	.byte	0
	.byte	0
	.byte	8
	.byte	8
	.byte	0
	.byte	0
	.byte	8
	.byte	8
	.byte	0
	.byte	0
	.byte	8
	.byte	8
	.byte	0
	.byte	0
	.byte	8
	.byte	8
	.section	__TEXT,__text,regular,pure_instructions
	.p2align	2
_tbl.useTblSelect:
Lfunc_begin2:
	.loc	3 50 0 is_stmt 1
	.cfi_startproc
	stp	x29, x30, [sp, #-16]!
	.cfi_def_cfa_offset 16
	mov	x29, sp
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
Ltmp19:
	.loc	3 18 5 prologue_end
	movi.16b	v2, #16
	cmhi.16b	v2, v2, v1
Ltmp20:
	.loc	3 20 5
	movi.16b	v3, #8
	and.16b	v3, v1, v3
	dup.2d	v4, v0[1]
	dup.2d	v0, v0[0]
Ltmp21:
	cmeq.16b	v3, v3, #0
	bif.16b	v0, v4, v3
Ltmp22:
	.loc	3 21 5
	movi.16b	v3, #4
	and.16b	v3, v1, v3
	cmeq.16b	v3, v3, #0
	trn2.4s	v4, v0, v0
	trn1.4s	v0, v0, v0
	bif.16b	v0, v4, v3
Ltmp23:
	.loc	3 22 5
	movi.16b	v3, #2
	and.16b	v3, v1, v3
	cmeq.16b	v3, v3, #0
Lloh2:
	adrp	x8, lCPI2_0@PAGE
Lloh3:
	ldr	q4, [x8, lCPI2_0@PAGEOFF]
	tbl.16b	v4, { v0 }, v4
Lloh4:
	adrp	x8, lCPI2_1@PAGE
Lloh5:
	ldr	q5, [x8, lCPI2_1@PAGEOFF]
	tbl.16b	v0, { v0 }, v5
	bif.16b	v0, v4, v3
Ltmp24:
	.loc	3 23 5
	movi.16b	v3, #1
	and.16b	v1, v1, v3
Ltmp25:
	cmeq.16b	v1, v1, #0
Lloh6:
	adrp	x8, lCPI2_2@PAGE
Lloh7:
	ldr	q3, [x8, lCPI2_2@PAGEOFF]
	tbl.16b	v3, { v0 }, v3
Lloh8:
	adrp	x8, lCPI2_3@PAGE
Lloh9:
	ldr	q4, [x8, lCPI2_3@PAGEOFF]
	tbl.16b	v0, { v0 }, v4
	bif.16b	v0, v3, v1
Ltmp26:
	.loc	3 24 5
	and.16b	v0, v2, v0
Ltmp27:
	.cfi_def_cfa wsp, 16
	.loc	3 50 46 epilogue_begin
	ldp	x29, x30, [sp], #16
	.cfi_def_cfa_offset 0
	.cfi_restore w30
	.cfi_restore w29
	ret
Ltmp28:
	.loh AdrpLdr	Lloh8, Lloh9
	.loh AdrpAdrp	Lloh6, Lloh8
	.loh AdrpLdr	Lloh6, Lloh7
	.loh AdrpAdrp	Lloh4, Lloh6
	.loh AdrpLdr	Lloh4, Lloh5
	.loh AdrpAdrp	Lloh2, Lloh4
	.loh AdrpLdr	Lloh2, Lloh3
Lfunc_end2:
	.cfi_endproc

	.p2align	2
_tbl.useTblArray:
Lfunc_begin3:
	.loc	3 49 0
	.cfi_startproc
	sub	sp, sp, #32
	.cfi_def_cfa_offset 32
	stp	x29, x30, [sp, #16]
	add	x29, sp, #16
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
Ltmp29:
	.loc	3 9 5 prologue_end
	str	q0, [sp]
Ltmp30:
	.loc	3 11 41
	umov.b	w8, v1[0]
	cmp	w8, #16
	b.hs	LBB3_17
Ltmp31:
	.loc	3 11 0 is_stmt 0
	umov.b	w8, v1[0]
Ltmp32:
	.loc	3 11 53 discriminator 4
	and	x8, x8, #0xff
	mov	x9, sp
	ldrb	w8, [x9, x8]
Ltmp33:
	.loc	3 11 41 discriminator 2
	umov.b	w9, v1[1]
	cmp	w9, #16
	b.lo	LBB3_18
Ltmp34:
LBB3_2:
	.loc	3 0 41
	mov	w9, #0
Ltmp35:
	.loc	3 11 41 discriminator 6
	umov.b	w10, v1[2]
	cmp	w10, #16
	b.lo	LBB3_19
Ltmp36:
LBB3_3:
	.loc	3 0 41
	mov	w10, #0
Ltmp37:
	.loc	3 11 41 discriminator 10
	umov.b	w11, v1[3]
	cmp	w11, #16
	b.lo	LBB3_20
Ltmp38:
LBB3_4:
	.loc	3 0 41
	mov	w11, #0
Ltmp39:
	.loc	3 11 41 discriminator 14
	umov.b	w12, v1[4]
	cmp	w12, #16
	b.lo	LBB3_21
Ltmp40:
LBB3_5:
	.loc	3 0 41
	mov	w12, #0
Ltmp41:
	.loc	3 11 41 discriminator 18
	umov.b	w13, v1[5]
	cmp	w13, #16
	b.lo	LBB3_22
Ltmp42:
LBB3_6:
	.loc	3 0 41
	mov	w13, #0
Ltmp43:
	.loc	3 11 41 discriminator 22
	umov.b	w14, v1[6]
	cmp	w14, #16
	b.lo	LBB3_23
Ltmp44:
LBB3_7:
	.loc	3 0 41
	mov	w14, #0
Ltmp45:
	.loc	3 11 41 discriminator 26
	umov.b	w15, v1[7]
	cmp	w15, #16
	b.lo	LBB3_24
Ltmp46:
LBB3_8:
	.loc	3 0 41
	mov	w15, #0
Ltmp47:
	.loc	3 11 41 discriminator 30
	umov.b	w16, v1[8]
	cmp	w16, #16
	b.lo	LBB3_25
Ltmp48:
LBB3_9:
	.loc	3 0 41
	mov	w16, #0
Ltmp49:
	.loc	3 11 41 discriminator 34
	umov.b	w17, v1[9]
	cmp	w17, #16
	b.lo	LBB3_26
Ltmp50:
LBB3_10:
	.loc	3 0 41
	mov	w17, #0
Ltmp51:
	.loc	3 11 41 discriminator 38
	umov.b	w0, v1[10]
	cmp	w0, #16
	b.lo	LBB3_27
Ltmp52:
LBB3_11:
	.loc	3 0 41
	mov	w0, #0
Ltmp53:
	.loc	3 11 41 discriminator 42
	umov.b	w1, v1[11]
	cmp	w1, #16
	b.lo	LBB3_28
Ltmp54:
LBB3_12:
	.loc	3 0 41
	mov	w1, #0
Ltmp55:
	.loc	3 11 41 discriminator 46
	umov.b	w2, v1[12]
	cmp	w2, #16
	b.lo	LBB3_29
Ltmp56:
LBB3_13:
	.loc	3 0 41
	mov	w2, #0
Ltmp57:
	.loc	3 11 41 discriminator 50
	umov.b	w3, v1[13]
	cmp	w3, #16
	b.lo	LBB3_30
Ltmp58:
LBB3_14:
	.loc	3 0 41
	mov	w3, #0
Ltmp59:
	.loc	3 11 41 discriminator 54
	umov.b	w4, v1[14]
	cmp	w4, #16
	b.lo	LBB3_31
Ltmp60:
LBB3_15:
	.loc	3 0 41
	mov	w4, #0
Ltmp61:
	.loc	3 11 41 discriminator 58
	umov.b	w5, v1[15]
	cmp	w5, #16
	b.lo	LBB3_32
Ltmp62:
LBB3_16:
	.loc	3 0 41
	mov	w5, #0
	.loc	3 11 41 discriminator 58
	b	LBB3_33
Ltmp63:
LBB3_17:
	.loc	3 0 41
	mov	w8, #0
Ltmp64:
	.loc	3 11 41 discriminator 2
	umov.b	w9, v1[1]
	cmp	w9, #16
	b.hs	LBB3_2
Ltmp65:
LBB3_18:
	.loc	3 11 53 discriminator 8
	and	x9, x9, #0xff
	mov	x10, sp
	ldrb	w9, [x10, x9]
Ltmp66:
	.loc	3 11 41 discriminator 6
	umov.b	w10, v1[2]
	cmp	w10, #16
	b.hs	LBB3_3
Ltmp67:
LBB3_19:
	.loc	3 11 53 discriminator 12
	and	x10, x10, #0xff
	mov	x11, sp
	ldrb	w10, [x11, x10]
Ltmp68:
	.loc	3 11 41 discriminator 10
	umov.b	w11, v1[3]
	cmp	w11, #16
	b.hs	LBB3_4
Ltmp69:
LBB3_20:
	.loc	3 11 53 discriminator 16
	and	x11, x11, #0xff
	mov	x12, sp
	ldrb	w11, [x12, x11]
Ltmp70:
	.loc	3 11 41 discriminator 14
	umov.b	w12, v1[4]
	cmp	w12, #16
	b.hs	LBB3_5
Ltmp71:
LBB3_21:
	.loc	3 11 53 discriminator 20
	and	x12, x12, #0xff
	mov	x13, sp
	ldrb	w12, [x13, x12]
Ltmp72:
	.loc	3 11 41 discriminator 18
	umov.b	w13, v1[5]
	cmp	w13, #16
	b.hs	LBB3_6
Ltmp73:
LBB3_22:
	.loc	3 11 53 discriminator 24
	and	x13, x13, #0xff
	mov	x14, sp
	ldrb	w13, [x14, x13]
Ltmp74:
	.loc	3 11 41 discriminator 22
	umov.b	w14, v1[6]
	cmp	w14, #16
	b.hs	LBB3_7
Ltmp75:
LBB3_23:
	.loc	3 11 53 discriminator 28
	and	x14, x14, #0xff
	mov	x15, sp
	ldrb	w14, [x15, x14]
Ltmp76:
	.loc	3 11 41 discriminator 26
	umov.b	w15, v1[7]
	cmp	w15, #16
	b.hs	LBB3_8
Ltmp77:
LBB3_24:
	.loc	3 11 53 discriminator 32
	and	x15, x15, #0xff
	mov	x16, sp
	ldrb	w15, [x16, x15]
Ltmp78:
	.loc	3 11 41 discriminator 30
	umov.b	w16, v1[8]
	cmp	w16, #16
	b.hs	LBB3_9
Ltmp79:
LBB3_25:
	.loc	3 11 53 discriminator 36
	and	x16, x16, #0xff
	mov	x17, sp
	ldrb	w16, [x17, x16]
Ltmp80:
	.loc	3 11 41 discriminator 34
	umov.b	w17, v1[9]
	cmp	w17, #16
	b.hs	LBB3_10
Ltmp81:
LBB3_26:
	.loc	3 11 53 discriminator 40
	and	x17, x17, #0xff
	mov	x0, sp
	ldrb	w17, [x0, x17]
Ltmp82:
	.loc	3 11 41 discriminator 38
	umov.b	w0, v1[10]
	cmp	w0, #16
	b.hs	LBB3_11
Ltmp83:
LBB3_27:
	.loc	3 11 53 discriminator 44
	and	x0, x0, #0xff
	mov	x1, sp
	ldrb	w0, [x1, x0]
Ltmp84:
	.loc	3 11 41 discriminator 42
	umov.b	w1, v1[11]
	cmp	w1, #16
	b.hs	LBB3_12
Ltmp85:
LBB3_28:
	.loc	3 11 53 discriminator 48
	and	x1, x1, #0xff
	mov	x2, sp
	ldrb	w1, [x2, x1]
Ltmp86:
	.loc	3 11 41 discriminator 46
	umov.b	w2, v1[12]
	cmp	w2, #16
	b.hs	LBB3_13
Ltmp87:
LBB3_29:
	.loc	3 11 53 discriminator 52
	and	x2, x2, #0xff
	mov	x3, sp
	ldrb	w2, [x3, x2]
Ltmp88:
	.loc	3 11 41 discriminator 50
	umov.b	w3, v1[13]
	cmp	w3, #16
	b.hs	LBB3_14
Ltmp89:
LBB3_30:
	.loc	3 11 53 discriminator 56
	and	x3, x3, #0xff
	mov	x4, sp
	ldrb	w3, [x4, x3]
Ltmp90:
	.loc	3 11 41 discriminator 54
	umov.b	w4, v1[14]
	cmp	w4, #16
	b.hs	LBB3_15
Ltmp91:
LBB3_31:
	.loc	3 11 53 discriminator 60
	and	x4, x4, #0xff
	mov	x5, sp
	ldrb	w4, [x5, x4]
Ltmp92:
	.loc	3 11 41 discriminator 58
	umov.b	w5, v1[15]
	cmp	w5, #16
	b.hs	LBB3_16
Ltmp93:
LBB3_32:
	.loc	3 11 53 discriminator 62
	and	x5, x5, #0xff
	mov	x6, sp
	ldrb	w5, [x6, x5]
Ltmp94:
LBB3_33:
	.loc	3 12 5 is_stmt 1
	fmov	s0, w8
Ltmp95:
	mov.b	v0[1], w9
	mov.b	v0[2], w10
	mov.b	v0[3], w11
	mov.b	v0[4], w12
	mov.b	v0[5], w13
	mov.b	v0[6], w14
	mov.b	v0[7], w15
	mov.b	v0[8], w16
	mov.b	v0[9], w17
	mov.b	v0[10], w0
	mov.b	v0[11], w1
	mov.b	v0[12], w2
	mov.b	v0[13], w3
	mov.b	v0[14], w4
	mov.b	v0[15], w5
Ltmp96:
	.cfi_def_cfa wsp, 32
	.loc	3 49 45 epilogue_begin
	ldp	x29, x30, [sp, #16]
	add	sp, sp, #32
	.cfi_def_cfa_offset 0
	.cfi_restore w30
	.cfi_restore w29
	ret
Ltmp97:
Lfunc_end3:
	.cfi_endproc

	.globl	_useMaskSwar
_useMaskSwar = _tbl.useMaskSwar
	.globl	_useMaskReduce
_useMaskReduce = _tbl.useMaskReduce
	.globl	_useTblSelect
_useTblSelect = _tbl.useTblSelect
	.globl	_useTblArray
_useTblArray = _tbl.useTblArray
	.section	__DWARF,__debug_loc,regular,debug
Lsection_debug_loc:
Ldebug_loc0:
Lset0 = Ltmp1-Lfunc_begin0
	.quad	Lset0
Lset1 = Ltmp5-Lfunc_begin0
	.quad	Lset1
	.short	1
	.byte	88
	.quad	0
	.quad	0
Ldebug_loc1:
Lset2 = Ltmp1-Lfunc_begin0
	.quad	Lset2
Lset3 = Lfunc_end0-Lfunc_begin0
	.quad	Lset3
	.short	11
	.byte	16
	.byte	128
	.byte	129
	.byte	129
	.byte	129
	.byte	129
	.byte	129
	.byte	129
	.byte	129
	.byte	1
	.byte	159
	.quad	0
	.quad	0
Ldebug_loc2:
Lset4 = Ltmp2-Lfunc_begin0
	.quad	Lset4
Lset5 = Ltmp3-Lfunc_begin0
	.quad	Lset5
	.short	1
	.byte	89
	.quad	0
	.quad	0
Ldebug_loc3:
Lset6 = Ltmp4-Lfunc_begin0
	.quad	Lset6
Lset7 = Lfunc_end0-Lfunc_begin0
	.quad	Lset7
	.short	1
	.byte	89
	.quad	0
	.quad	0
Ldebug_loc4:
Lset8 = Ltmp6-Lfunc_begin0
	.quad	Lset8
Lset9 = Ltmp7-Lfunc_begin0
	.quad	Lset9
	.short	6
	.byte	120
	.byte	0
	.byte	16
	.byte	56
	.byte	37
	.byte	159
	.quad	0
	.quad	0
Ldebug_loc5:
Lset10 = Lfunc_begin1-Lfunc_begin0
	.quad	Lset10
Lset11 = Ltmp12-Lfunc_begin0
	.quad	Lset11
	.short	2
	.byte	144
	.byte	64
Lset12 = Ltmp12-Lfunc_begin0
	.quad	Lset12
Lset13 = Lfunc_end1-Lfunc_begin0
	.quad	Lset13
	.short	5
	.byte	163
	.byte	2
	.byte	144
	.byte	64
	.byte	159
	.quad	0
	.quad	0
Ldebug_loc6:
Lset14 = Lfunc_begin1-Lfunc_begin0
	.quad	Lset14
Lset15 = Ltmp12-Lfunc_begin0
	.quad	Lset15
	.short	2
	.byte	144
	.byte	64
	.quad	0
	.quad	0
Ldebug_loc7:
Lset16 = Ltmp11-Lfunc_begin0
	.quad	Lset16
Lset17 = Ltmp13-Lfunc_begin0
	.quad	Lset17
	.short	2
	.byte	144
	.byte	65
	.quad	0
	.quad	0
Ldebug_loc8:
Lset18 = Ltmp12-Lfunc_begin0
	.quad	Lset18
Lset19 = Ltmp14-Lfunc_begin0
	.quad	Lset19
	.short	2
	.byte	144
	.byte	64
	.quad	0
	.quad	0
Ldebug_loc9:
Lset20 = Ltmp12-Lfunc_begin0
	.quad	Lset20
Lset21 = Ltmp14-Lfunc_begin0
	.quad	Lset21
	.short	2
	.byte	144
	.byte	64
	.quad	0
	.quad	0
Ldebug_loc10:
Lset22 = Ltmp13-Lfunc_begin0
	.quad	Lset22
Lset23 = Lfunc_end1-Lfunc_begin0
	.quad	Lset23
	.short	2
	.byte	144
	.byte	65
	.quad	0
	.quad	0
Ldebug_loc11:
Lset24 = Lfunc_begin2-Lfunc_begin0
	.quad	Lset24
Lset25 = Ltmp21-Lfunc_begin0
	.quad	Lset25
	.short	2
	.byte	144
	.byte	64
Lset26 = Ltmp21-Lfunc_begin0
	.quad	Lset26
Lset27 = Lfunc_end2-Lfunc_begin0
	.quad	Lset27
	.short	5
	.byte	163
	.byte	2
	.byte	144
	.byte	64
	.byte	159
	.quad	0
	.quad	0
Ldebug_loc12:
Lset28 = Lfunc_begin2-Lfunc_begin0
	.quad	Lset28
Lset29 = Ltmp25-Lfunc_begin0
	.quad	Lset29
	.short	2
	.byte	144
	.byte	65
Lset30 = Ltmp25-Lfunc_begin0
	.quad	Lset30
Lset31 = Lfunc_end2-Lfunc_begin0
	.quad	Lset31
	.short	5
	.byte	163
	.byte	2
	.byte	144
	.byte	65
	.byte	159
	.quad	0
	.quad	0
Ldebug_loc13:
Lset32 = Lfunc_begin2-Lfunc_begin0
	.quad	Lset32
Lset33 = Ltmp21-Lfunc_begin0
	.quad	Lset33
	.short	2
	.byte	144
	.byte	64
	.quad	0
	.quad	0
Ldebug_loc14:
Lset34 = Lfunc_begin2-Lfunc_begin0
	.quad	Lset34
Lset35 = Ltmp25-Lfunc_begin0
	.quad	Lset35
	.short	2
	.byte	144
	.byte	65
	.quad	0
	.quad	0
Ldebug_loc15:
Lset36 = Lfunc_begin3-Lfunc_begin0
	.quad	Lset36
Lset37 = Ltmp95-Lfunc_begin0
	.quad	Lset37
	.short	2
	.byte	144
	.byte	64
Lset38 = Ltmp95-Lfunc_begin0
	.quad	Lset38
Lset39 = Lfunc_end3-Lfunc_begin0
	.quad	Lset39
	.short	5
	.byte	163
	.byte	2
	.byte	144
	.byte	64
	.byte	159
	.quad	0
	.quad	0
Ldebug_loc16:
Lset40 = Lfunc_begin3-Lfunc_begin0
	.quad	Lset40
Lset41 = Ltmp95-Lfunc_begin0
	.quad	Lset41
	.short	2
	.byte	144
	.byte	64
	.quad	0
	.quad	0
Ldebug_loc17:
Lset42 = Ltmp33-Lfunc_begin0
	.quad	Lset42
Lset43 = Ltmp35-Lfunc_begin0
	.quad	Lset43
	.short	3
	.byte	88
	.byte	147
	.byte	1
Lset44 = Ltmp35-Lfunc_begin0
	.quad	Lset44
Lset45 = Ltmp37-Lfunc_begin0
	.quad	Lset45
	.short	6
	.byte	88
	.byte	147
	.byte	1
	.byte	89
	.byte	147
	.byte	1
Lset46 = Ltmp37-Lfunc_begin0
	.quad	Lset46
Lset47 = Ltmp39-Lfunc_begin0
	.quad	Lset47
	.short	9
	.byte	88
	.byte	147
	.byte	1
	.byte	89
	.byte	147
	.byte	1
	.byte	90
	.byte	147
	.byte	1
Lset48 = Ltmp39-Lfunc_begin0
	.quad	Lset48
Lset49 = Ltmp41-Lfunc_begin0
	.quad	Lset49
	.short	12
	.byte	88
	.byte	147
	.byte	1
	.byte	89
	.byte	147
	.byte	1
	.byte	90
	.byte	147
	.byte	1
	.byte	91
	.byte	147
	.byte	1
Lset50 = Ltmp41-Lfunc_begin0
	.quad	Lset50
Lset51 = Ltmp43-Lfunc_begin0
	.quad	Lset51
	.short	15
	.byte	88
	.byte	147
	.byte	1
	.byte	89
	.byte	147
	.byte	1
	.byte	90
	.byte	147
	.byte	1
	.byte	91
	.byte	147
	.byte	1
	.byte	92
	.byte	147
	.byte	1
Lset52 = Ltmp43-Lfunc_begin0
	.quad	Lset52
Lset53 = Ltmp45-Lfunc_begin0
	.quad	Lset53
	.short	18
	.byte	88
	.byte	147
	.byte	1
	.byte	89
	.byte	147
	.byte	1
	.byte	90
	.byte	147
	.byte	1
	.byte	91
	.byte	147
	.byte	1
	.byte	92
	.byte	147
	.byte	1
	.byte	93
	.byte	147
	.byte	1
Lset54 = Ltmp45-Lfunc_begin0
	.quad	Lset54
Lset55 = Ltmp47-Lfunc_begin0
	.quad	Lset55
	.short	21
	.byte	88
	.byte	147
	.byte	1
	.byte	89
	.byte	147
	.byte	1
	.byte	90
	.byte	147
	.byte	1
	.byte	91
	.byte	147
	.byte	1
	.byte	92
	.byte	147
	.byte	1
	.byte	93
	.byte	147
	.byte	1
	.byte	94
	.byte	147
	.byte	1
Lset56 = Ltmp47-Lfunc_begin0
	.quad	Lset56
Lset57 = Ltmp49-Lfunc_begin0
	.quad	Lset57
	.short	24
	.byte	88
	.byte	147
	.byte	1
	.byte	89
	.byte	147
	.byte	1
	.byte	90
	.byte	147
	.byte	1
	.byte	91
	.byte	147
	.byte	1
	.byte	92
	.byte	147
	.byte	1
	.byte	93
	.byte	147
	.byte	1
	.byte	94
	.byte	147
	.byte	1
	.byte	95
	.byte	147
	.byte	1
Lset58 = Ltmp49-Lfunc_begin0
	.quad	Lset58
Lset59 = Ltmp51-Lfunc_begin0
	.quad	Lset59
	.short	27
	.byte	88
	.byte	147
	.byte	1
	.byte	89
	.byte	147
	.byte	1
	.byte	90
	.byte	147
	.byte	1
	.byte	91
	.byte	147
	.byte	1
	.byte	92
	.byte	147
	.byte	1
	.byte	93
	.byte	147
	.byte	1
	.byte	94
	.byte	147
	.byte	1
	.byte	95
	.byte	147
	.byte	1
	.byte	96
	.byte	147
	.byte	1
Lset60 = Ltmp51-Lfunc_begin0
	.quad	Lset60
Lset61 = Ltmp53-Lfunc_begin0
	.quad	Lset61
	.short	30
	.byte	88
	.byte	147
	.byte	1
	.byte	89
	.byte	147
	.byte	1
	.byte	90
	.byte	147
	.byte	1
	.byte	91
	.byte	147
	.byte	1
	.byte	92
	.byte	147
	.byte	1
	.byte	93
	.byte	147
	.byte	1
	.byte	94
	.byte	147
	.byte	1
	.byte	95
	.byte	147
	.byte	1
	.byte	96
	.byte	147
	.byte	1
	.byte	97
	.byte	147
	.byte	1
Lset62 = Ltmp53-Lfunc_begin0
	.quad	Lset62
Lset63 = Ltmp55-Lfunc_begin0
	.quad	Lset63
	.short	33
	.byte	88
	.byte	147
	.byte	1
	.byte	89
	.byte	147
	.byte	1
	.byte	90
	.byte	147
	.byte	1
	.byte	91
	.byte	147
	.byte	1
	.byte	92
	.byte	147
	.byte	1
	.byte	93
	.byte	147
	.byte	1
	.byte	94
	.byte	147
	.byte	1
	.byte	95
	.byte	147
	.byte	1
	.byte	96
	.byte	147
	.byte	1
	.byte	97
	.byte	147
	.byte	1
	.byte	80
	.byte	147
	.byte	1
Lset64 = Ltmp55-Lfunc_begin0
	.quad	Lset64
Lset65 = Ltmp57-Lfunc_begin0
	.quad	Lset65
	.short	36
	.byte	88
	.byte	147
	.byte	1
	.byte	89
	.byte	147
	.byte	1
	.byte	90
	.byte	147
	.byte	1
	.byte	91
	.byte	147
	.byte	1
	.byte	92
	.byte	147
	.byte	1
	.byte	93
	.byte	147
	.byte	1
	.byte	94
	.byte	147
	.byte	1
	.byte	95
	.byte	147
	.byte	1
	.byte	96
	.byte	147
	.byte	1
	.byte	97
	.byte	147
	.byte	1
	.byte	80
	.byte	147
	.byte	1
	.byte	81
	.byte	147
	.byte	1
Lset66 = Ltmp57-Lfunc_begin0
	.quad	Lset66
Lset67 = Ltmp59-Lfunc_begin0
	.quad	Lset67
	.short	39
	.byte	88
	.byte	147
	.byte	1
	.byte	89
	.byte	147
	.byte	1
	.byte	90
	.byte	147
	.byte	1
	.byte	91
	.byte	147
	.byte	1
	.byte	92
	.byte	147
	.byte	1
	.byte	93
	.byte	147
	.byte	1
	.byte	94
	.byte	147
	.byte	1
	.byte	95
	.byte	147
	.byte	1
	.byte	96
	.byte	147
	.byte	1
	.byte	97
	.byte	147
	.byte	1
	.byte	80
	.byte	147
	.byte	1
	.byte	81
	.byte	147
	.byte	1
	.byte	82
	.byte	147
	.byte	1
Lset68 = Ltmp59-Lfunc_begin0
	.quad	Lset68
Lset69 = Ltmp61-Lfunc_begin0
	.quad	Lset69
	.short	42
	.byte	88
	.byte	147
	.byte	1
	.byte	89
	.byte	147
	.byte	1
	.byte	90
	.byte	147
	.byte	1
	.byte	91
	.byte	147
	.byte	1
	.byte	92
	.byte	147
	.byte	1
	.byte	93
	.byte	147
	.byte	1
	.byte	94
	.byte	147
	.byte	1
	.byte	95
	.byte	147
	.byte	1
	.byte	96
	.byte	147
	.byte	1
	.byte	97
	.byte	147
	.byte	1
	.byte	80
	.byte	147
	.byte	1
	.byte	81
	.byte	147
	.byte	1
	.byte	82
	.byte	147
	.byte	1
	.byte	83
	.byte	147
	.byte	1
Lset70 = Ltmp61-Lfunc_begin0
	.quad	Lset70
Lset71 = Ltmp63-Lfunc_begin0
	.quad	Lset71
	.short	45
	.byte	88
	.byte	147
	.byte	1
	.byte	89
	.byte	147
	.byte	1
	.byte	90
	.byte	147
	.byte	1
	.byte	91
	.byte	147
	.byte	1
	.byte	92
	.byte	147
	.byte	1
	.byte	93
	.byte	147
	.byte	1
	.byte	94
	.byte	147
	.byte	1
	.byte	95
	.byte	147
	.byte	1
	.byte	96
	.byte	147
	.byte	1
	.byte	97
	.byte	147
	.byte	1
	.byte	80
	.byte	147
	.byte	1
	.byte	81
	.byte	147
	.byte	1
	.byte	82
	.byte	147
	.byte	1
	.byte	83
	.byte	147
	.byte	1
	.byte	84
	.byte	147
	.byte	1
Lset72 = Ltmp64-Lfunc_begin0
	.quad	Lset72
Lset73 = Ltmp66-Lfunc_begin0
	.quad	Lset73
	.short	3
	.byte	88
	.byte	147
	.byte	1
Lset74 = Ltmp66-Lfunc_begin0
	.quad	Lset74
Lset75 = Ltmp68-Lfunc_begin0
	.quad	Lset75
	.short	6
	.byte	88
	.byte	147
	.byte	1
	.byte	89
	.byte	147
	.byte	1
Lset76 = Ltmp68-Lfunc_begin0
	.quad	Lset76
Lset77 = Ltmp70-Lfunc_begin0
	.quad	Lset77
	.short	9
	.byte	88
	.byte	147
	.byte	1
	.byte	89
	.byte	147
	.byte	1
	.byte	90
	.byte	147
	.byte	1
Lset78 = Ltmp70-Lfunc_begin0
	.quad	Lset78
Lset79 = Ltmp72-Lfunc_begin0
	.quad	Lset79
	.short	12
	.byte	88
	.byte	147
	.byte	1
	.byte	89
	.byte	147
	.byte	1
	.byte	90
	.byte	147
	.byte	1
	.byte	91
	.byte	147
	.byte	1
Lset80 = Ltmp72-Lfunc_begin0
	.quad	Lset80
Lset81 = Ltmp74-Lfunc_begin0
	.quad	Lset81
	.short	15
	.byte	88
	.byte	147
	.byte	1
	.byte	89
	.byte	147
	.byte	1
	.byte	90
	.byte	147
	.byte	1
	.byte	91
	.byte	147
	.byte	1
	.byte	92
	.byte	147
	.byte	1
Lset82 = Ltmp74-Lfunc_begin0
	.quad	Lset82
Lset83 = Ltmp76-Lfunc_begin0
	.quad	Lset83
	.short	18
	.byte	88
	.byte	147
	.byte	1
	.byte	89
	.byte	147
	.byte	1
	.byte	90
	.byte	147
	.byte	1
	.byte	91
	.byte	147
	.byte	1
	.byte	92
	.byte	147
	.byte	1
	.byte	93
	.byte	147
	.byte	1
Lset84 = Ltmp76-Lfunc_begin0
	.quad	Lset84
Lset85 = Ltmp78-Lfunc_begin0
	.quad	Lset85
	.short	21
	.byte	88
	.byte	147
	.byte	1
	.byte	89
	.byte	147
	.byte	1
	.byte	90
	.byte	147
	.byte	1
	.byte	91
	.byte	147
	.byte	1
	.byte	92
	.byte	147
	.byte	1
	.byte	93
	.byte	147
	.byte	1
	.byte	94
	.byte	147
	.byte	1
Lset86 = Ltmp78-Lfunc_begin0
	.quad	Lset86
Lset87 = Ltmp80-Lfunc_begin0
	.quad	Lset87
	.short	24
	.byte	88
	.byte	147
	.byte	1
	.byte	89
	.byte	147
	.byte	1
	.byte	90
	.byte	147
	.byte	1
	.byte	91
	.byte	147
	.byte	1
	.byte	92
	.byte	147
	.byte	1
	.byte	93
	.byte	147
	.byte	1
	.byte	94
	.byte	147
	.byte	1
	.byte	95
	.byte	147
	.byte	1
Lset88 = Ltmp80-Lfunc_begin0
	.quad	Lset88
Lset89 = Ltmp82-Lfunc_begin0
	.quad	Lset89
	.short	27
	.byte	88
	.byte	147
	.byte	1
	.byte	89
	.byte	147
	.byte	1
	.byte	90
	.byte	147
	.byte	1
	.byte	91
	.byte	147
	.byte	1
	.byte	92
	.byte	147
	.byte	1
	.byte	93
	.byte	147
	.byte	1
	.byte	94
	.byte	147
	.byte	1
	.byte	95
	.byte	147
	.byte	1
	.byte	96
	.byte	147
	.byte	1
Lset90 = Ltmp82-Lfunc_begin0
	.quad	Lset90
Lset91 = Ltmp84-Lfunc_begin0
	.quad	Lset91
	.short	30
	.byte	88
	.byte	147
	.byte	1
	.byte	89
	.byte	147
	.byte	1
	.byte	90
	.byte	147
	.byte	1
	.byte	91
	.byte	147
	.byte	1
	.byte	92
	.byte	147
	.byte	1
	.byte	93
	.byte	147
	.byte	1
	.byte	94
	.byte	147
	.byte	1
	.byte	95
	.byte	147
	.byte	1
	.byte	96
	.byte	147
	.byte	1
	.byte	97
	.byte	147
	.byte	1
Lset92 = Ltmp84-Lfunc_begin0
	.quad	Lset92
Lset93 = Ltmp86-Lfunc_begin0
	.quad	Lset93
	.short	33
	.byte	88
	.byte	147
	.byte	1
	.byte	89
	.byte	147
	.byte	1
	.byte	90
	.byte	147
	.byte	1
	.byte	91
	.byte	147
	.byte	1
	.byte	92
	.byte	147
	.byte	1
	.byte	93
	.byte	147
	.byte	1
	.byte	94
	.byte	147
	.byte	1
	.byte	95
	.byte	147
	.byte	1
	.byte	96
	.byte	147
	.byte	1
	.byte	97
	.byte	147
	.byte	1
	.byte	80
	.byte	147
	.byte	1
Lset94 = Ltmp86-Lfunc_begin0
	.quad	Lset94
Lset95 = Ltmp88-Lfunc_begin0
	.quad	Lset95
	.short	36
	.byte	88
	.byte	147
	.byte	1
	.byte	89
	.byte	147
	.byte	1
	.byte	90
	.byte	147
	.byte	1
	.byte	91
	.byte	147
	.byte	1
	.byte	92
	.byte	147
	.byte	1
	.byte	93
	.byte	147
	.byte	1
	.byte	94
	.byte	147
	.byte	1
	.byte	95
	.byte	147
	.byte	1
	.byte	96
	.byte	147
	.byte	1
	.byte	97
	.byte	147
	.byte	1
	.byte	80
	.byte	147
	.byte	1
	.byte	81
	.byte	147
	.byte	1
Lset96 = Ltmp88-Lfunc_begin0
	.quad	Lset96
Lset97 = Ltmp90-Lfunc_begin0
	.quad	Lset97
	.short	39
	.byte	88
	.byte	147
	.byte	1
	.byte	89
	.byte	147
	.byte	1
	.byte	90
	.byte	147
	.byte	1
	.byte	91
	.byte	147
	.byte	1
	.byte	92
	.byte	147
	.byte	1
	.byte	93
	.byte	147
	.byte	1
	.byte	94
	.byte	147
	.byte	1
	.byte	95
	.byte	147
	.byte	1
	.byte	96
	.byte	147
	.byte	1
	.byte	97
	.byte	147
	.byte	1
	.byte	80
	.byte	147
	.byte	1
	.byte	81
	.byte	147
	.byte	1
	.byte	82
	.byte	147
	.byte	1
Lset98 = Ltmp90-Lfunc_begin0
	.quad	Lset98
Lset99 = Ltmp92-Lfunc_begin0
	.quad	Lset99
	.short	42
	.byte	88
	.byte	147
	.byte	1
	.byte	89
	.byte	147
	.byte	1
	.byte	90
	.byte	147
	.byte	1
	.byte	91
	.byte	147
	.byte	1
	.byte	92
	.byte	147
	.byte	1
	.byte	93
	.byte	147
	.byte	1
	.byte	94
	.byte	147
	.byte	1
	.byte	95
	.byte	147
	.byte	1
	.byte	96
	.byte	147
	.byte	1
	.byte	97
	.byte	147
	.byte	1
	.byte	80
	.byte	147
	.byte	1
	.byte	81
	.byte	147
	.byte	1
	.byte	82
	.byte	147
	.byte	1
	.byte	83
	.byte	147
	.byte	1
Lset100 = Ltmp92-Lfunc_begin0
	.quad	Lset100
Lset101 = Ltmp94-Lfunc_begin0
	.quad	Lset101
	.short	45
	.byte	88
	.byte	147
	.byte	1
	.byte	89
	.byte	147
	.byte	1
	.byte	90
	.byte	147
	.byte	1
	.byte	91
	.byte	147
	.byte	1
	.byte	92
	.byte	147
	.byte	1
	.byte	93
	.byte	147
	.byte	1
	.byte	94
	.byte	147
	.byte	1
	.byte	95
	.byte	147
	.byte	1
	.byte	96
	.byte	147
	.byte	1
	.byte	97
	.byte	147
	.byte	1
	.byte	80
	.byte	147
	.byte	1
	.byte	81
	.byte	147
	.byte	1
	.byte	82
	.byte	147
	.byte	1
	.byte	83
	.byte	147
	.byte	1
	.byte	84
	.byte	147
	.byte	1
Lset102 = Ltmp94-Lfunc_begin0
	.quad	Lset102
Lset103 = Lfunc_end3-Lfunc_begin0
	.quad	Lset103
	.short	48
	.byte	88
	.byte	147
	.byte	1
	.byte	89
	.byte	147
	.byte	1
	.byte	90
	.byte	147
	.byte	1
	.byte	91
	.byte	147
	.byte	1
	.byte	92
	.byte	147
	.byte	1
	.byte	93
	.byte	147
	.byte	1
	.byte	94
	.byte	147
	.byte	1
	.byte	95
	.byte	147
	.byte	1
	.byte	96
	.byte	147
	.byte	1
	.byte	97
	.byte	147
	.byte	1
	.byte	80
	.byte	147
	.byte	1
	.byte	81
	.byte	147
	.byte	1
	.byte	82
	.byte	147
	.byte	1
	.byte	83
	.byte	147
	.byte	1
	.byte	84
	.byte	147
	.byte	1
	.byte	85
	.byte	147
	.byte	1
	.quad	0
	.quad	0
Ldebug_loc18:
Lset104 = Ltmp29-Lfunc_begin0
	.quad	Lset104
Lset105 = Ltmp95-Lfunc_begin0
	.quad	Lset105
	.short	2
	.byte	144
	.byte	64
	.quad	0
	.quad	0
Ldebug_loc19:
Lset106 = Ltmp30-Lfunc_begin0
	.quad	Lset106
Lset107 = Lfunc_end3-Lfunc_begin0
	.quad	Lset107
	.short	2
	.byte	144
	.byte	65
	.quad	0
	.quad	0
Ldebug_loc20:
Lset108 = Ltmp33-Lfunc_begin0
	.quad	Lset108
Lset109 = Ltmp35-Lfunc_begin0
	.quad	Lset109
	.short	2
	.byte	49
	.byte	159
Lset110 = Ltmp35-Lfunc_begin0
	.quad	Lset110
Lset111 = Ltmp37-Lfunc_begin0
	.quad	Lset111
	.short	2
	.byte	50
	.byte	159
Lset112 = Ltmp37-Lfunc_begin0
	.quad	Lset112
Lset113 = Ltmp39-Lfunc_begin0
	.quad	Lset113
	.short	2
	.byte	51
	.byte	159
Lset114 = Ltmp39-Lfunc_begin0
	.quad	Lset114
Lset115 = Ltmp41-Lfunc_begin0
	.quad	Lset115
	.short	2
	.byte	52
	.byte	159
Lset116 = Ltmp41-Lfunc_begin0
	.quad	Lset116
Lset117 = Ltmp43-Lfunc_begin0
	.quad	Lset117
	.short	2
	.byte	53
	.byte	159
Lset118 = Ltmp43-Lfunc_begin0
	.quad	Lset118
Lset119 = Ltmp45-Lfunc_begin0
	.quad	Lset119
	.short	2
	.byte	54
	.byte	159
Lset120 = Ltmp45-Lfunc_begin0
	.quad	Lset120
Lset121 = Ltmp47-Lfunc_begin0
	.quad	Lset121
	.short	2
	.byte	55
	.byte	159
Lset122 = Ltmp47-Lfunc_begin0
	.quad	Lset122
Lset123 = Ltmp49-Lfunc_begin0
	.quad	Lset123
	.short	2
	.byte	56
	.byte	159
Lset124 = Ltmp49-Lfunc_begin0
	.quad	Lset124
Lset125 = Ltmp51-Lfunc_begin0
	.quad	Lset125
	.short	2
	.byte	57
	.byte	159
Lset126 = Ltmp51-Lfunc_begin0
	.quad	Lset126
Lset127 = Ltmp53-Lfunc_begin0
	.quad	Lset127
	.short	2
	.byte	58
	.byte	159
Lset128 = Ltmp53-Lfunc_begin0
	.quad	Lset128
Lset129 = Ltmp55-Lfunc_begin0
	.quad	Lset129
	.short	2
	.byte	59
	.byte	159
Lset130 = Ltmp55-Lfunc_begin0
	.quad	Lset130
Lset131 = Ltmp57-Lfunc_begin0
	.quad	Lset131
	.short	2
	.byte	60
	.byte	159
Lset132 = Ltmp57-Lfunc_begin0
	.quad	Lset132
Lset133 = Ltmp59-Lfunc_begin0
	.quad	Lset133
	.short	2
	.byte	61
	.byte	159
Lset134 = Ltmp59-Lfunc_begin0
	.quad	Lset134
Lset135 = Ltmp61-Lfunc_begin0
	.quad	Lset135
	.short	2
	.byte	62
	.byte	159
Lset136 = Ltmp61-Lfunc_begin0
	.quad	Lset136
Lset137 = Ltmp63-Lfunc_begin0
	.quad	Lset137
	.short	2
	.byte	63
	.byte	159
Lset138 = Ltmp64-Lfunc_begin0
	.quad	Lset138
Lset139 = Ltmp66-Lfunc_begin0
	.quad	Lset139
	.short	2
	.byte	49
	.byte	159
Lset140 = Ltmp66-Lfunc_begin0
	.quad	Lset140
Lset141 = Ltmp68-Lfunc_begin0
	.quad	Lset141
	.short	2
	.byte	50
	.byte	159
Lset142 = Ltmp68-Lfunc_begin0
	.quad	Lset142
Lset143 = Ltmp70-Lfunc_begin0
	.quad	Lset143
	.short	2
	.byte	51
	.byte	159
Lset144 = Ltmp70-Lfunc_begin0
	.quad	Lset144
Lset145 = Ltmp72-Lfunc_begin0
	.quad	Lset145
	.short	2
	.byte	52
	.byte	159
Lset146 = Ltmp72-Lfunc_begin0
	.quad	Lset146
Lset147 = Ltmp74-Lfunc_begin0
	.quad	Lset147
	.short	2
	.byte	53
	.byte	159
Lset148 = Ltmp74-Lfunc_begin0
	.quad	Lset148
Lset149 = Ltmp76-Lfunc_begin0
	.quad	Lset149
	.short	2
	.byte	54
	.byte	159
Lset150 = Ltmp76-Lfunc_begin0
	.quad	Lset150
Lset151 = Ltmp78-Lfunc_begin0
	.quad	Lset151
	.short	2
	.byte	55
	.byte	159
Lset152 = Ltmp78-Lfunc_begin0
	.quad	Lset152
Lset153 = Ltmp80-Lfunc_begin0
	.quad	Lset153
	.short	2
	.byte	56
	.byte	159
Lset154 = Ltmp80-Lfunc_begin0
	.quad	Lset154
Lset155 = Ltmp82-Lfunc_begin0
	.quad	Lset155
	.short	2
	.byte	57
	.byte	159
Lset156 = Ltmp82-Lfunc_begin0
	.quad	Lset156
Lset157 = Ltmp84-Lfunc_begin0
	.quad	Lset157
	.short	2
	.byte	58
	.byte	159
Lset158 = Ltmp84-Lfunc_begin0
	.quad	Lset158
Lset159 = Ltmp86-Lfunc_begin0
	.quad	Lset159
	.short	2
	.byte	59
	.byte	159
Lset160 = Ltmp86-Lfunc_begin0
	.quad	Lset160
Lset161 = Ltmp88-Lfunc_begin0
	.quad	Lset161
	.short	2
	.byte	60
	.byte	159
Lset162 = Ltmp88-Lfunc_begin0
	.quad	Lset162
Lset163 = Ltmp90-Lfunc_begin0
	.quad	Lset163
	.short	2
	.byte	61
	.byte	159
Lset164 = Ltmp90-Lfunc_begin0
	.quad	Lset164
Lset165 = Ltmp92-Lfunc_begin0
	.quad	Lset165
	.short	2
	.byte	62
	.byte	159
Lset166 = Ltmp92-Lfunc_begin0
	.quad	Lset166
Lset167 = Ltmp94-Lfunc_begin0
	.quad	Lset167
	.short	2
	.byte	63
	.byte	159
	.quad	0
	.quad	0
	.section	__DWARF,__debug_abbrev,regular,debug
Lsection_abbrev:
	.byte	1
	.byte	17
	.byte	1
	.byte	37
	.byte	14
	.byte	19
	.byte	5
	.byte	3
	.byte	14
	.byte	16
	.byte	23
	.byte	27
	.byte	14
	.ascii	"\341\177"
	.byte	25
	.byte	17
	.byte	1
	.byte	18
	.byte	6
	.byte	0
	.byte	0
	.byte	2
	.byte	52
	.byte	0
	.byte	3
	.byte	14
	.byte	73
	.byte	19
	.byte	58
	.byte	11
	.byte	59
	.byte	11
	.byte	110
	.byte	14
	.byte	0
	.byte	0
	.byte	3
	.byte	4
	.byte	1
	.byte	73
	.byte	19
	.byte	3
	.byte	14
	.byte	11
	.byte	11
	.byte	58
	.byte	11
	.byte	59
	.byte	5
	.ascii	"\210\001"
	.byte	15
	.byte	0
	.byte	0
	.byte	4
	.byte	40
	.byte	0
	.byte	3
	.byte	14
	.byte	28
	.byte	15
	.byte	0
	.byte	0
	.byte	5
	.byte	36
	.byte	0
	.byte	3
	.byte	14
	.byte	62
	.byte	11
	.byte	11
	.byte	11
	.byte	0
	.byte	0
	.byte	6
	.byte	46
	.byte	1
	.byte	110
	.byte	14
	.byte	3
	.byte	14
	.byte	58
	.byte	11
	.byte	59
	.byte	11
	.byte	73
	.byte	19
	.ascii	"\341\177"
	.byte	25
	.byte	32
	.byte	11
	.byte	0
	.byte	0
	.byte	7
	.byte	5
	.byte	0
	.byte	3
	.byte	14
	.byte	58
	.byte	11
	.byte	59
	.byte	11
	.byte	73
	.byte	19
	.byte	0
	.byte	0
	.byte	8
	.byte	52
	.byte	0
	.byte	3
	.byte	14
	.byte	58
	.byte	11
	.byte	59
	.byte	11
	.byte	73
	.byte	19
	.byte	0
	.byte	0
	.byte	9
	.byte	1
	.byte	1
	.ascii	"\207B"
	.byte	25
	.byte	73
	.byte	19
	.byte	3
	.byte	14
	.byte	0
	.byte	0
	.byte	10
	.byte	33
	.byte	0
	.byte	73
	.byte	19
	.byte	55
	.byte	11
	.byte	0
	.byte	0
	.byte	11
	.byte	36
	.byte	0
	.byte	3
	.byte	14
	.byte	11
	.byte	11
	.byte	62
	.byte	11
	.byte	0
	.byte	0
	.byte	12
	.byte	46
	.byte	1
	.byte	17
	.byte	1
	.byte	18
	.byte	6
	.byte	64
	.byte	24
	.byte	110
	.byte	14
	.byte	3
	.byte	14
	.byte	58
	.byte	11
	.byte	59
	.byte	11
	.byte	73
	.byte	19
	.ascii	"\341\177"
	.byte	25
	.byte	0
	.byte	0
	.byte	13
	.byte	5
	.byte	0
	.byte	2
	.byte	24
	.byte	3
	.byte	14
	.byte	58
	.byte	11
	.byte	59
	.byte	11
	.byte	73
	.byte	19
	.byte	0
	.byte	0
	.byte	14
	.byte	29
	.byte	1
	.byte	49
	.byte	19
	.byte	17
	.byte	1
	.byte	18
	.byte	6
	.byte	88
	.byte	11
	.byte	89
	.byte	11
	.byte	87
	.byte	11
	.byte	0
	.byte	0
	.byte	15
	.byte	5
	.byte	0
	.byte	2
	.byte	24
	.byte	49
	.byte	19
	.byte	0
	.byte	0
	.byte	16
	.byte	52
	.byte	0
	.byte	2
	.byte	24
	.byte	49
	.byte	19
	.byte	0
	.byte	0
	.byte	17
	.byte	52
	.byte	0
	.byte	2
	.byte	23
	.byte	49
	.byte	19
	.byte	0
	.byte	0
	.byte	18
	.byte	5
	.byte	0
	.byte	2
	.byte	23
	.byte	3
	.byte	14
	.byte	58
	.byte	11
	.byte	59
	.byte	11
	.byte	73
	.byte	19
	.byte	0
	.byte	0
	.byte	19
	.byte	5
	.byte	0
	.byte	2
	.byte	23
	.byte	49
	.byte	19
	.byte	0
	.byte	0
	.byte	20
	.byte	11
	.byte	1
	.byte	0
	.byte	0
	.byte	21
	.byte	1
	.byte	1
	.byte	73
	.byte	19
	.byte	3
	.byte	14
	.byte	0
	.byte	0
	.byte	22
	.byte	11
	.byte	1
	.byte	17
	.byte	1
	.byte	18
	.byte	6
	.byte	49
	.byte	19
	.byte	0
	.byte	0
	.byte	23
	.byte	52
	.byte	0
	.byte	28
	.byte	15
	.byte	49
	.byte	19
	.byte	0
	.byte	0
	.byte	0
	.section	__DWARF,__debug_info,regular,debug
Lsection_info:
Lcu_begin0:
Lset168 = Ldebug_info_end0-Ldebug_info_start0
	.long	Lset168
Ldebug_info_start0:
	.short	4
Lset169 = Lsection_abbrev-Lsection_abbrev
	.long	Lset169
	.byte	8
	.byte	1
	.long	0
	.short	12
	.long	11
Lset170 = Lline_table_start0-Lsection_line
	.long	Lset170
	.long	15

	.quad	Lfunc_begin0
Lset171 = Lfunc_end3-Lfunc_begin0
	.long	Lset171
	.byte	2
	.long	59
	.long	57
	.byte	2
	.byte	8
	.long	105
	.byte	3
	.long	90
	.long	71
	.byte	1
	.byte	1
	.short	862
	.byte	1
	.byte	4
	.long	93
	.byte	0
	.byte	4
	.long	97
	.byte	1
	.byte	4
	.long	101
	.byte	2
	.byte	0
	.byte	5
	.long	90
	.byte	7
	.byte	1
	.byte	6
	.long	125
	.long	142
	.byte	3
	.byte	39
	.long	191

	.byte	1
	.byte	7
	.long	159
	.byte	3
	.byte	39
	.long	198
	.byte	8
	.long	197
	.byte	3
	.byte	40
	.long	228
	.byte	8
	.long	204
	.byte	3
	.byte	42
	.long	235
	.byte	8
	.long	211
	.byte	3
	.byte	43
	.long	235
	.byte	8
	.long	217
	.byte	3
	.byte	41
	.long	235
	.byte	8
	.long	220
	.byte	3
	.byte	44
	.long	235
	.byte	8
	.long	222
	.byte	3
	.byte	45
	.long	235
	.byte	0
	.byte	5
	.long	155
	.byte	7
	.byte	2
	.byte	9

	.long	214
	.long	161
	.byte	10
	.long	221
	.byte	16
	.byte	0
	.byte	5
	.long	161
	.byte	7
	.byte	1
	.byte	11
	.long	177
	.byte	8
	.byte	7
	.byte	5
	.long	199
	.byte	7
	.byte	16
	.byte	5
	.long	207
	.byte	7
	.byte	8
	.byte	12
	.quad	Lfunc_begin0
Lset172 = Lfunc_end0-Lfunc_begin0
	.long	Lset172
	.byte	1
	.byte	109
	.long	236
	.long	224
	.byte	3
	.byte	52
	.long	191

	.byte	13
	.byte	2
	.byte	144
	.byte	64
	.long	159
	.byte	3
	.byte	52
	.long	198
	.byte	14
	.long	97
	.quad	Ltmp0
Lset173 = Ltmp8-Ltmp0
	.long	Lset173
	.byte	3
	.byte	52
	.byte	56
	.byte	15
	.byte	2
	.byte	144
	.byte	64
	.long	113
	.byte	16
	.byte	2
	.byte	144
	.byte	64
	.long	124
	.byte	17
Lset174 = Ldebug_loc0-Lsection_debug_loc
	.long	Lset174
	.long	135
	.byte	17
Lset175 = Ldebug_loc1-Lsection_debug_loc
	.long	Lset175
	.long	146
	.byte	17
Lset176 = Ldebug_loc2-Lsection_debug_loc
	.long	Lset176
	.long	157
	.byte	17
Lset177 = Ldebug_loc3-Lsection_debug_loc
	.long	Lset177
	.long	168
	.byte	17
Lset178 = Ldebug_loc4-Lsection_debug_loc
	.long	Lset178
	.long	179
	.byte	0
	.byte	0
	.byte	6
	.long	252
	.long	271
	.byte	3
	.byte	28
	.long	191

	.byte	1
	.byte	7
	.long	159
	.byte	3
	.byte	28
	.long	198
	.byte	8
	.long	286
	.byte	3
	.byte	29
	.long	198
	.byte	8
	.long	288
	.byte	3
	.byte	30
	.long	198
	.byte	8
	.long	217
	.byte	3
	.byte	31
	.long	440
	.byte	8
	.long	204
	.byte	3
	.byte	32
	.long	440
	.byte	0
	.byte	9

	.long	456
	.long	290
	.byte	10
	.long	221
	.byte	8
	.byte	0
	.byte	5
	.long	290
	.byte	7
	.byte	1
	.byte	12
	.quad	Lfunc_begin1
Lset179 = Lfunc_end1-Lfunc_begin1
	.long	Lset179
	.byte	1
	.byte	109
	.long	319
	.long	305
	.byte	3
	.byte	51
	.long	191

	.byte	18
Lset180 = Ldebug_loc5-Lsection_debug_loc
	.long	Lset180
	.long	159
	.byte	3
	.byte	51
	.long	198
	.byte	14
	.long	368
	.quad	Ltmp10
Lset181 = Ltmp17-Ltmp10
	.long	Lset181
	.byte	3
	.byte	51
	.byte	60
	.byte	19
Lset182 = Ldebug_loc6-Lsection_debug_loc
	.long	Lset182
	.long	384
	.byte	17
Lset183 = Ldebug_loc7-Lsection_debug_loc
	.long	Lset183
	.long	395
	.byte	17
Lset184 = Ldebug_loc8-Lsection_debug_loc
	.long	Lset184
	.long	406
	.byte	17
Lset185 = Ldebug_loc9-Lsection_debug_loc
	.long	Lset185
	.long	417
	.byte	17
Lset186 = Ldebug_loc10-Lsection_debug_loc
	.long	Lset186
	.long	428
	.byte	0
	.byte	0
	.byte	6
	.long	337
	.long	351
	.byte	3
	.byte	16
	.long	198

	.byte	1
	.byte	7
	.long	361
	.byte	3
	.byte	16
	.long	198
	.byte	7
	.long	363
	.byte	3
	.byte	16
	.long	198
	.byte	0
	.byte	12
	.quad	Lfunc_begin2
Lset187 = Lfunc_end2-Lfunc_begin2
	.long	Lset187
	.byte	1
	.byte	109
	.long	380
	.long	367
	.byte	3
	.byte	50
	.long	198

	.byte	18
Lset188 = Ldebug_loc11-Lsection_debug_loc
	.long	Lset188
	.long	361
	.byte	3
	.byte	50
	.long	198
	.byte	18
Lset189 = Ldebug_loc12-Lsection_debug_loc
	.long	Lset189
	.long	437
	.byte	3
	.byte	50
	.long	198
	.byte	14
	.long	574
	.quad	Ltmp19
Lset190 = Ltmp27-Ltmp19
	.long	Lset190
	.byte	3
	.byte	50
	.byte	62
	.byte	19
Lset191 = Ldebug_loc13-Lsection_debug_loc
	.long	Lset191
	.long	590
	.byte	19
Lset192 = Ldebug_loc14-Lsection_debug_loc
	.long	Lset192
	.long	601
	.byte	0
	.byte	0
	.byte	6
	.long	397
	.long	410
	.byte	3
	.byte	7
	.long	198

	.byte	1
	.byte	7
	.long	361
	.byte	3
	.byte	7
	.long	198
	.byte	7
	.long	363
	.byte	3
	.byte	7
	.long	198
	.byte	8
	.long	419
	.byte	3
	.byte	8
	.long	810
	.byte	8
	.long	431
	.byte	3
	.byte	9
	.long	810
	.byte	8
	.long	434
	.byte	3
	.byte	10
	.long	810
	.byte	20
	.byte	8
	.long	437
	.byte	3
	.byte	11
	.long	833
	.byte	0
	.byte	20
	.byte	8
	.long	437
	.byte	3
	.byte	11
	.long	833
	.byte	0
	.byte	0
	.byte	21
	.long	826
	.long	421
	.byte	10
	.long	221
	.byte	16
	.byte	0
	.byte	5
	.long	428
	.byte	7
	.byte	1
	.byte	5
	.long	439
	.byte	7
	.byte	8
	.byte	12
	.quad	Lfunc_begin3
Lset193 = Lfunc_end3-Lfunc_begin3
	.long	Lset193
	.byte	1
	.byte	109
	.long	457
	.long	445
	.byte	3
	.byte	49
	.long	198

	.byte	18
Lset194 = Ldebug_loc15-Lsection_debug_loc
	.long	Lset194
	.long	361
	.byte	3
	.byte	49
	.long	198
	.byte	13
	.byte	2
	.byte	144
	.byte	65
	.long	437
	.byte	3
	.byte	49
	.long	198
	.byte	14
	.long	712
	.quad	Ltmp29
Lset195 = Ltmp96-Ltmp29
	.long	Lset195
	.byte	3
	.byte	49
	.byte	60
	.byte	19
Lset196 = Ldebug_loc16-Lsection_debug_loc
	.long	Lset196
	.long	728
	.byte	15
	.byte	2
	.byte	144
	.byte	65
	.long	739
	.byte	17
Lset197 = Ldebug_loc17-Lsection_debug_loc
	.long	Lset197
	.long	750
	.byte	17
Lset198 = Ldebug_loc18-Lsection_debug_loc
	.long	Lset198
	.long	761
	.byte	17
Lset199 = Ldebug_loc19-Lsection_debug_loc
	.long	Lset199
	.long	772
	.byte	22
	.quad	Ltmp30
Lset200 = Ltmp33-Ltmp30
	.long	Lset200
	.long	783
	.byte	23
	.byte	0
	.long	784
	.byte	0
	.byte	22
	.quad	Ltmp33
Lset201 = Ltmp94-Ltmp33
	.long	Lset201
	.long	796
	.byte	17
Lset202 = Ldebug_loc20-Lsection_debug_loc
	.long	Lset202
	.long	797
	.byte	0
	.byte	0
	.byte	0
	.byte	0
Ldebug_info_end0:
	.section	__DWARF,__debug_str,regular,debug
Linfo_string:
	.asciz	"zig 0.16.0"
	.asciz	"tbl"
	.asciz	"/Users/bytedance/r/my-scanner-oxc-neon/.exp"
	.asciz	"output_mode"
	.asciz	"builtin.OutputMode"
	.asciz	"u2"
	.asciz	"Exe"
	.asciz	"Lib"
	.asciz	"Obj"
	.asciz	"builtin.output_mode"
	.asciz	"tbl.movemaskSwar"
	.asciz	"movemaskSwar"
	.asciz	"u16"
	.asciz	"v"
	.asciz	"@Vector(16, u8)"
	.asciz	"__ARRAY_SIZE_TYPE__"
	.asciz	"x"
	.asciz	"u128"
	.asciz	"hi"
	.asciz	"u64"
	.asciz	"magic"
	.asciz	"lo"
	.asciz	"l"
	.asciz	"h"
	.asciz	"useMaskSwar"
	.asciz	"tbl.useMaskSwar"
	.asciz	"tbl.movemaskReduce"
	.asciz	"movemaskReduce"
	.asciz	"w"
	.asciz	"m"
	.asciz	"@Vector(8, u8)"
	.asciz	"useMaskReduce"
	.asciz	"tbl.useMaskReduce"
	.asciz	"tbl.tblSelect"
	.asciz	"tblSelect"
	.asciz	"t"
	.asciz	"idx"
	.asciz	"useTblSelect"
	.asciz	"tbl.useTblSelect"
	.asciz	"tbl.tblArray"
	.asciz	"tblArray"
	.asciz	"r"
	.asciz	"[16]u8"
	.asciz	"u8"
	.asciz	"ti"
	.asciz	"ii"
	.asciz	"i"
	.asciz	"usize"
	.asciz	"useTblArray"
	.asciz	"tbl.useTblArray"
	.section	__DWARF,__apple_names,regular,debug
Lnames_begin:
	.long	1212240712
	.short	1
	.short	0
	.long	16
	.long	16
	.long	12
	.long	0
	.long	1
	.short	1
	.short	6
	.long	0
	.long	-1
	.long	-1
	.long	2
	.long	4
	.long	6
	.long	8
	.long	12
	.long	-1
	.long	-1
	.long	-1
	.long	14
	.long	-1
	.long	-1
	.long	-1
	.long	-1
	.long	-1206165904
	.long	-819440384
	.long	1129140931
	.long	-1563733165
	.long	625221332
	.long	-704246716
	.long	1560754133
	.long	-1404745115
	.long	35181478
	.long	-2039300346
	.long	-1116527722
	.long	-1113749226
	.long	1849796999
	.long	-1705177865
	.long	-1816036629
	.long	-213943429
Lset203 = LNames7-Lnames_begin
	.long	Lset203
Lset204 = LNames6-Lnames_begin
	.long	Lset204
Lset205 = LNames13-Lnames_begin
	.long	Lset205
Lset206 = LNames12-Lnames_begin
	.long	Lset206
Lset207 = LNames8-Lnames_begin
	.long	Lset207
Lset208 = LNames9-Lnames_begin
	.long	Lset208
Lset209 = LNames3-Lnames_begin
	.long	Lset209
Lset210 = LNames2-Lnames_begin
	.long	Lset210
Lset211 = LNames14-Lnames_begin
	.long	Lset211
Lset212 = LNames5-Lnames_begin
	.long	Lset212
Lset213 = LNames4-Lnames_begin
	.long	Lset213
Lset214 = LNames15-Lnames_begin
	.long	Lset214
Lset215 = LNames10-Lnames_begin
	.long	Lset215
Lset216 = LNames11-Lnames_begin
	.long	Lset216
Lset217 = LNames1-Lnames_begin
	.long	Lset217
Lset218 = LNames0-Lnames_begin
	.long	Lset218
LNames7:
	.long	252
	.long	1
	.long	507
	.long	0
LNames6:
	.long	271
	.long	1
	.long	507
	.long	0
LNames13:
	.long	457
	.long	1
	.long	840
	.long	0
LNames12:
	.long	445
	.long	1
	.long	840
	.long	0
LNames8:
	.long	367
	.long	1
	.long	613
	.long	0
LNames9:
	.long	380
	.long	1
	.long	613
	.long	0
LNames3:
	.long	125
	.long	1
	.long	285
	.long	0
LNames2:
	.long	142
	.long	1
	.long	285
	.long	0
LNames14:
	.long	410
	.long	1
	.long	898
	.long	0
LNames5:
	.long	319
	.long	1
	.long	463
	.long	0
LNames4:
	.long	305
	.long	1
	.long	463
	.long	0
LNames15:
	.long	397
	.long	1
	.long	898
	.long	0
LNames10:
	.long	351
	.long	1
	.long	672
	.long	0
LNames11:
	.long	337
	.long	1
	.long	672
	.long	0
LNames1:
	.long	236
	.long	1
	.long	242
	.long	0
LNames0:
	.long	224
	.long	1
	.long	242
	.long	0
	.section	__DWARF,__apple_objc,regular,debug
Lobjc_begin:
	.long	1212240712
	.short	1
	.short	0
	.long	1
	.long	0
	.long	12
	.long	0
	.long	1
	.short	1
	.short	6
	.long	-1
	.section	__DWARF,__apple_namespac,regular,debug
Lnamespac_begin:
	.long	1212240712
	.short	1
	.short	0
	.long	1
	.long	0
	.long	12
	.long	0
	.long	1
	.short	1
	.short	6
	.long	-1
	.section	__DWARF,__apple_types,regular,debug
Ltypes_begin:
	.long	1212240712
	.short	1
	.short	0
	.long	11
	.long	11
	.long	20
	.long	0
	.long	3
	.short	1
	.short	6
	.short	3
	.short	5
	.short	4
	.short	11
	.long	-1
	.long	0
	.long	1
	.long	-1
	.long	2
	.long	-1
	.long	4
	.long	5
	.long	7
	.long	-1
	.long	10
	.long	5863826
	.long	-594775205
	.long	277156213
	.long	1001356800
	.long	5863820
	.long	-2110181862
	.long	-964268599
	.long	193506244
	.long	2090733301
	.long	-541434351
	.long	193506081
Lset219 = Ltypes9-Ltypes_begin
	.long	Lset219
Lset220 = Ltypes4-Ltypes_begin
	.long	Lset220
Lset221 = Ltypes10-Ltypes_begin
	.long	Lset221
Lset222 = Ltypes0-Ltypes_begin
	.long	Lset222
Lset223 = Ltypes1-Ltypes_begin
	.long	Lset223
Lset224 = Ltypes7-Ltypes_begin
	.long	Lset224
Lset225 = Ltypes3-Ltypes_begin
	.long	Lset225
Lset226 = Ltypes6-Ltypes_begin
	.long	Lset226
Lset227 = Ltypes5-Ltypes_begin
	.long	Lset227
Lset228 = Ltypes8-Ltypes_begin
	.long	Lset228
Lset229 = Ltypes2-Ltypes_begin
	.long	Lset229
Ltypes9:
	.long	428
	.long	1
	.long	826
	.short	36
	.byte	0
	.long	0
Ltypes4:
	.long	177
	.long	1
	.long	221
	.short	36
	.byte	0
	.long	0
Ltypes10:
	.long	439
	.long	1
	.long	833
	.short	36
	.byte	0
	.long	0
Ltypes0:
	.long	71
	.long	1
	.long	57
	.short	4
	.byte	0
	.long	0
Ltypes1:
	.long	90
	.long	1
	.long	90
	.short	36
	.byte	0
	.long	0
Ltypes7:
	.long	290
	.long	2
	.long	440
	.short	1
	.byte	0
	.long	456
	.short	36
	.byte	0
	.long	0
Ltypes3:
	.long	161
	.long	2
	.long	198
	.short	1
	.byte	0
	.long	214
	.short	36
	.byte	0
	.long	0
Ltypes6:
	.long	207
	.long	1
	.long	235
	.short	36
	.byte	0
	.long	0
Ltypes5:
	.long	199
	.long	1
	.long	228
	.short	36
	.byte	0
	.long	0
Ltypes8:
	.long	421
	.long	1
	.long	810
	.short	1
	.byte	0
	.long	0
Ltypes2:
	.long	155
	.long	1
	.long	191
	.short	36
	.byte	0
	.long	0
.subsections_via_symbols
	.section	__DWARF,__debug_line,regular,debug
Lsection_line:
Lline_table_start0:
